# syntax=docker/dockerfile:1
#
# Bench-only build of praxis-ai.
#
# This mirrors the repo's top-level Containerfile but pins a DIFFERENT Rust
# builder base. The shipped Containerfile uses rust:1.98-alpine, whose bundled
# cargo mis-parses a deep transitive dependency (brotli-decompressor 2.5.1) and
# fails the container build with "can't find brotli-decompressor bin". The
# workspace MSRV is 1.96, so we pin rust:1.97-alpine: new enough to build the
# tree, and using a pre-1.98 cargo that does not hit the parse bug. The local
# (non-container) build works on 1.98, so this is purely a container-toolchain
# quirk, not a source issue.
#
# We use a bench-specific image deliberately: the benchmark records the exact
# image/version it runs, and we do not want a toolchain hiccup in the release
# image to block measurements. If the top-level Containerfile is later fixed to
# build cleanly, this file can be dropped in favor of `make container`.
#
# Build context is the REPO ROOT (not this directory):
#   podman build -t praxis-ai:0.3.0 -f bench/engines/praxis/Dockerfile .

FROM rust:1.97-alpine AS builder

ENV OPENSSL_STATIC=1
RUN apk add --no-cache musl-dev openssl-dev openssl-libs-static pkgconf cmake make g++

WORKDIR /src

# Workspace manifests (dependency-cache layer).
COPY Cargo.toml Cargo.lock ./
COPY apis/Cargo.toml ./apis/Cargo.toml
COPY filters/Cargo.toml ./filters/Cargo.toml
COPY server/Cargo.toml ./server/Cargo.toml
COPY server/build_support/Cargo.toml ./server/build_support/Cargo.toml

# server/build.rs needs the real build-support source (see top-level Containerfile).
COPY server/build.rs ./server/build.rs
COPY server/build_support/src ./server/build_support/src

COPY integrations/llmd/ext-proc/Cargo.toml ./integrations/llmd/ext-proc/Cargo.toml
COPY integrations/llmd/ext-proc/build.rs ./integrations/llmd/ext-proc/build.rs
COPY integrations/llmd/ext-proc/proto ./integrations/llmd/ext-proc/proto

RUN sed -i '/xtask/d; /tests\//d' Cargo.toml

RUN mkdir -p apis/src filters/src server/src integrations/llmd/ext-proc/src \
    && echo '//! stub' > apis/src/lib.rs \
    && echo '//! stub' > filters/src/lib.rs \
    && echo '//! stub' > server/src/lib.rs \
    && echo '//! stub' > integrations/llmd/ext-proc/src/lib.rs \
    && printf '//! stub\nfn main() {}\n' > server/src/main.rs

RUN cargo build --release -p praxis-ai-proxy

# Real source, then rebuild (only project crates recompile).
COPY apis/src ./apis/src
COPY filters/src ./filters/src
COPY server/src ./server/src
COPY integrations/llmd/ext-proc/src ./integrations/llmd/ext-proc/src
RUN find apis/src filters/src server/src integrations/llmd/ext-proc/src \
    -name '*.rs' -exec touch {} +
RUN cargo build --release -p praxis-ai-proxy \
    && cp target/release/praxis-ai /usr/local/bin/praxis-ai

FROM alpine:3.24
RUN apk add --no-cache ca-certificates \
    && addgroup -S praxis \
    && adduser -S -G praxis -h /nonexistent -s /sbin/nologin praxis
COPY --from=builder --chown=root:root --chmod=0555 \
    /usr/local/bin/praxis-ai /usr/local/bin/praxis-ai
USER praxis:praxis
EXPOSE 8080 9901
ENTRYPOINT ["praxis-ai"]
