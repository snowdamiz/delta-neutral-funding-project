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
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,target=/workspace/target,sharing=locked \
    cargo fmt --all -- --check \
    && cargo build --locked -q -p mesh-rt -p meshc \
    && cargo test --locked -q -p meshc --test e2e_stdlib e2e_list_contains \
    && cargo test --locked -q -p meshc --test e2e_stdlib e2e_cluster_telemetry_is_available_as_a_typed_map \
    && cargo test --locked -q -p meshc --test e2e_stdlib e2e_http_server_drains_accepted_requests_before_returning \
    && cargo test --locked -q -p mesh-rt channel::tests \
    && cargo test --locked -q -p mesh-rt http::server::tests::request_parser_rejects_unbounded_or_ambiguous_input \
    && cargo test --locked -q -p mesh-rt actor::mailbox::tests::test_mailbox_concurrent_push \
    && cargo test --locked -q -p meshc --test e2e e2e_bounded_channel \
    && cargo test --locked -q -p meshc --test tooling_e2e test_test_runs_mesh_solana_path_dependency \
    && cargo test --locked -q -p meshc --test e2e_actors gc_bounded_memory \
    && cargo test --locked -q -p meshc --test e2e_supervisors supervisor_restarts_crashed_permanent_child
COPY mesh /workspace/project/mesh
COPY replay /workspace/project/replay
COPY tests/vectors /workspace/project/tests/vectors
ARG CODE_COMMIT=development
ARG MESH_COMMIT=c5c75c405e4141eb2dc5a25e8ed638b75ccbd8c9
RUN sed -i \
      -e "s/__CODE_COMMIT__/$CODE_COMMIT/g" \
      -e "s/__MESH_COMMIT__/$MESH_COMMIT/g" \
      /workspace/project/mesh/packages/build_identity.mpl \
    && ! grep -q '__.*_COMMIT__' \
      /workspace/project/mesh/packages/build_identity.mpl
RUN --mount=type=cache,target=/workspace/target,sharing=locked \
    cd /workspace/project \
    && /workspace/target/debug/meshc test mesh \
    && /workspace/target/debug/meshc build mesh \
      --output /tmp/funding-collector --no-color \
    && test -x /tmp/funding-collector

FROM ubuntu:24.04 AS runtime
ARG CODE_COMMIT=development
ARG MESH_COMMIT=c5c75c405e4141eb2dc5a25e8ed638b75ccbd8c9
LABEL org.opencontainers.image.revision=$CODE_COMMIT
LABEL org.mesh-lang.revision=$MESH_COMMIT
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
