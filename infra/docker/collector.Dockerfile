# syntax=docker/dockerfile:1.7
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git gnupg libffi-dev libssl-dev \
    libxml2-dev libzstd-dev pkg-config wget xz-utils \
    && wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-21 main" \
      > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends clang-21 libpolly-21-dev llvm-21-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain 1.92.0
ENV PATH="/root/.cargo/bin:${PATH}"
ENV LLVM_SYS_211_PREFIX=/usr/lib/llvm-21
ENV LLVM_LINK_LLVM_DYLIB=1
ENV CARGO_TARGET_DIR=/workspace/target

WORKDIR /workspace/mesh-lang
COPY --from=mesh_lang . .
COPY mesh /workspace/project/mesh
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,target=/workspace/target,sharing=locked \
    cargo build --locked -q -p mesh-rt -p meshc \
    && /workspace/target/debug/meshc build /workspace/project/mesh \
      --output /tmp/funding-collector --no-color \
    && test -x /tmp/funding-collector

FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libpq5 libssl3 libzstd1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 collector
COPY --from=builder /tmp/funding-collector /usr/local/bin/funding-collector
USER collector:collector
EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=2s --retries=12 \
  CMD curl --fail --silent http://127.0.0.1:8080/v1/health >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/funding-collector"]
