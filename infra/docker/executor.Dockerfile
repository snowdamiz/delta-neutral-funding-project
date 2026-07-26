# syntax=docker/dockerfile:1.7
FROM rust:1.92-slim AS checks
RUN rustup component add clippy rustfmt
WORKDIR /workspace/executor/signer-service
COPY executor/signer-service/Cargo.toml executor/signer-service/Cargo.lock ./
COPY executor/signer-service/src ./src
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    cargo fetch --locked
COPY executor/signer-service/tests ./tests
COPY tests/vectors /workspace/tests/vectors
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/workspace/executor/signer-service/target,sharing=locked \
    cargo fmt --check \
    && cargo test --locked \
    && cargo clippy --all-targets --all-features --locked -- -D warnings

FROM checks AS builder
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    cargo build --release --locked

FROM debian:bookworm-slim
ARG CODE_COMMIT=development
LABEL org.opencontainers.image.revision=$CODE_COMMIT
COPY --from=builder \
    /workspace/executor/signer-service/target/release/funding-collector-signer \
    /usr/local/bin/funding-executor
USER 65532:65532
ENTRYPOINT ["funding-executor"]
