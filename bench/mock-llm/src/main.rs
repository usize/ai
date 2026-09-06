//! Deterministic mock LLM upstream for AI-gateway benchmarking.
//!
//! Speaks the OpenAI Chat Completions shape (`POST /v1/chat/completions`) in
//! both unary and SSE-streaming modes, and emits a real `usage` block computed
//! from the actual tokens it produces so token-count parity can be verified.
//!
//! The point of a *mock* upstream is reproducibility: it removes provider
//! latency variance so the numbers reflect gateway overhead. Every gateway
//! under test proxies to a byte-identical instance of this server.
//!
//! Determinism & tuning knobs (so the harness can sweep without restarting):
//!   * completion length: request `max_tokens` (clamped), else `DEFAULT_COMPLETION_TOKENS`
//!   * think latency (before first byte): env `MOCK_THINK_MS`, or header `x-mock-think-ms`
//!   * inter-chunk delay (streaming): env `MOCK_CHUNK_MS`, or header `x-mock-chunk-ms`
//! Per-request headers override env so a single running server serves a whole
//! latency matrix.

use std::time::Duration;

use axum::{
    Router,
    body::Body,
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use futures_util::stream::{self, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};

const DEFAULT_COMPLETION_TOKENS: u64 = 256;
const MAX_COMPLETION_TOKENS: u64 = 8192;
// One filler "token" word emitted per completion token. Fixed content keeps
// byte sizes deterministic across runs and engines.
const FILLER_TOKEN: &str = "lorem";
const MODEL_ID: &str = "mock-gpt";

#[tokio::main]
async fn main() {
    let addr = std::env::var("MOCK_ADDR").unwrap_or_else(|_| "0.0.0.0:9000".to_string());
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/chat/completions", post(chat_completions));

    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("mock-llm: bind {addr}: {e}"));
    eprintln!("mock-llm listening on {addr}");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("mock-llm: serve");
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

/// Minimal view of the request body — we only read what affects the response
/// shape. Unknown fields are ignored (a real client sends many more).
#[derive(Deserialize, Default)]
struct ChatRequest {
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    stream: bool,
    #[serde(default)]
    max_tokens: Option<u64>,
    #[serde(default)]
    max_completion_tokens: Option<u64>,
    #[serde(default)]
    messages: Vec<Value>,
    #[serde(default)]
    stream_options: Option<StreamOptions>,
}

#[derive(Deserialize, Default)]
struct StreamOptions {
    #[serde(default)]
    include_usage: bool,
}

async fn chat_completions(headers: HeaderMap, body: axum::body::Bytes) -> Response {
    // Parse leniently: a malformed body still gets a deterministic default
    // response so the harness never sees mock-side errors it must special-case.
    let req: ChatRequest = serde_json::from_slice(&body).unwrap_or_default();

    let prompt_tokens = estimate_prompt_tokens(&req.messages);
    let completion_tokens = req
        .max_completion_tokens
        .or(req.max_tokens)
        .unwrap_or(DEFAULT_COMPLETION_TOKENS)
        .clamp(1, MAX_COMPLETION_TOKENS);

    let think_ms = header_or_env_u64(&headers, "x-mock-think-ms", "MOCK_THINK_MS", 0);
    let chunk_ms = header_or_env_u64(&headers, "x-mock-chunk-ms", "MOCK_CHUNK_MS", 0);
    let model = req.model.clone().unwrap_or_else(|| MODEL_ID.to_string());

    if think_ms > 0 {
        tokio::time::sleep(Duration::from_millis(think_ms)).await;
    }

    if req.stream {
        let include_usage = req
            .stream_options
            .as_ref()
            .map(|o| o.include_usage)
            .unwrap_or(false);
        streaming_response(model, prompt_tokens, completion_tokens, chunk_ms, include_usage)
    } else {
        unary_response(model, prompt_tokens, completion_tokens)
    }
}

/// Whole completion text as a single deterministic string.
fn completion_text(completion_tokens: u64) -> String {
    let mut s = String::with_capacity((completion_tokens as usize) * (FILLER_TOKEN.len() + 1));
    for i in 0..completion_tokens {
        if i > 0 {
            s.push(' ');
        }
        s.push_str(FILLER_TOKEN);
    }
    s
}

fn unary_response(model: String, prompt_tokens: u64, completion_tokens: u64) -> Response {
    let text = completion_text(completion_tokens);
    let payload = json!({
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "created": 0,
        "model": model,
        "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": text },
            "finish_reason": "stop"
        }],
        "usage": usage_block(prompt_tokens, completion_tokens)
    });
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/json")],
        serde_json::to_vec(&payload).expect("serialize unary"),
    )
        .into_response()
}

fn streaming_response(
    model: String,
    prompt_tokens: u64,
    completion_tokens: u64,
    chunk_ms: u64,
    include_usage: bool,
) -> Response {
    // Emit one SSE data frame per completion token, then (optionally) a
    // usage-only frame, then the OpenAI terminal `[DONE]` marker. This mirrors
    // real OpenAI streaming closely enough that gateway SSE parsers exercise
    // their real code paths.
    let delay = Duration::from_millis(chunk_ms);

    let content_frames = (0..completion_tokens).map(move |i| {
        let word = if i == 0 {
            FILLER_TOKEN.to_string()
        } else {
            format!(" {FILLER_TOKEN}")
        };
        let frame = json!({
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": model,
            "choices": [{
                "index": 0,
                "delta": { "content": word },
                "finish_reason": Value::Null
            }]
        });
        sse_frame(&frame)
    });

    let model_final = MODEL_ID; // stable id for the tail frames
    let stop_frame = sse_frame(&json!({
        "id": "chatcmpl-mock",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": model_final,
        "choices": [{ "index": 0, "delta": {}, "finish_reason": "stop" }]
    }));

    let usage_frame = if include_usage {
        // OpenAI sends a final frame with empty choices carrying usage.
        Some(sse_frame(&json!({
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": model_final,
            "choices": [],
            "usage": usage_block(prompt_tokens, completion_tokens)
        })))
    } else {
        None
    };

    let tail = std::iter::once(stop_frame)
        .chain(usage_frame.into_iter())
        .chain(std::iter::once("data: [DONE]\n\n".to_string()));

    let all = content_frames.chain(tail);

    // Apply the inter-chunk delay between frames. The first frame is released
    // immediately (after any think latency) so TTFB is measurable.
    let body_stream = stream::iter(all).enumerate().then(move |(idx, frame)| async move {
        if idx > 0 && !delay.is_zero() {
            tokio::time::sleep(delay).await;
        }
        Ok::<_, std::convert::Infallible>(frame.into_bytes())
    });

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header("x-accel-buffering", "no") // discourage intermediary buffering
        .body(Body::from_stream(body_stream))
        .expect("build streaming response")
}

fn sse_frame(value: &Value) -> String {
    format!("data: {}\n\n", serde_json::to_string(value).expect("serialize frame"))
}

fn usage_block(prompt_tokens: u64, completion_tokens: u64) -> Value {
    json!({
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens
    })
}

/// Deterministic prompt-token estimate: one token per whitespace-separated
/// word across all message `content` strings, minimum 1. This is not a real
/// tokenizer — it just needs to be stable and proportional so parity checks
/// and payload-size scaling are meaningful.
fn estimate_prompt_tokens(messages: &[Value]) -> u64 {
    let mut count: u64 = 0;
    for m in messages {
        if let Some(content) = m.get("content").and_then(|c| c.as_str()) {
            count += content.split_whitespace().count() as u64;
        }
    }
    count.max(1)
}

fn header_or_env_u64(headers: &HeaderMap, header_name: &str, env_name: &str, default: u64) -> u64 {
    if let Some(v) = headers.get(header_name).and_then(|v| v.to_str().ok()) {
        if let Ok(n) = v.parse::<u64>() {
            return n;
        }
    }
    std::env::var(env_name)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(default)
}
