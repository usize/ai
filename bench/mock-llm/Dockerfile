# syntax=docker/dockerfile:1
#
# Deterministic mock LLM upstream for the AI-gateway benchmark.
# Build context is this directory (bench/mock-llm).

FROM rust:1.98-alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /src
# Cache dependency build against the manifests first.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && \
    cargo build --release && \
    rm -rf src
COPY src ./src
# Touch so cargo rebuilds with the real source.
RUN touch src/main.rs && cargo build --release

FROM alpine:3.20
RUN adduser -D -u 10001 mock
USER mock
COPY --from=builder /src/target/release/mock-llm /usr/local/bin/mock-llm
ENV MOCK_ADDR=0.0.0.0:9000
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/mock-llm"]
