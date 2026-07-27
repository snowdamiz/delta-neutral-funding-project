BEGIN;

CREATE OR REPLACE FUNCTION record_language_capability_results(
  p_build_manifest_id text
) RETURNS integer
LANGUAGE sql
AS $$
  WITH recorded AS (
    INSERT INTO language_capability_results (
      build_manifest_id, capability_id, status, evidence
    )
    SELECT p_build_manifest_id, capability_id, status, evidence
    FROM (VALUES
      ('MESH-FIN-001', 'implemented', 'checked wide-intermediate runtime probes and cross-language vectors'),
      ('MESH-FIN-002', 'project_local', 'nominal pure-Mesh finance package and tests'),
      ('MESH-TIME-001', 'implemented', 'monotonic clock and checked duration runtime probes'),
      ('MESH-TEST-001', 'project_local', 'explicit system, replay, and test clocks'),
      ('MESH-TEST-002', 'implemented', 'versioned deterministic xorshift64star runtime probe'),
      ('MESH-ACTOR-001', 'implemented', 'item/byte-bounded reject, drop-oldest, and latest-only channels with nonblocking producers'),
      ('MESH-PROC-001', 'implemented', 'signal hook, accepted-request drain, lease release, and exit probes'),
      ('MESH-OBS-001', 'project_local', 'structured JSON logger with secret-bearing fields excluded'),
      ('MESH-METRICS-001', 'implemented', 'bounded runtime telemetry and pure-Mesh Prometheus renderer'),
      ('MESH-PROTO-001', 'project_local', 'canonical versioned integer-string contracts and shared fixtures'),
      ('MESH-BYTES-001', 'implemented', 'binary-safe immutable bytes with bounded slicing and comparisons'),
      ('MESH-CODEC-001', 'implemented', 'strict base58, base64, hexadecimal, and little-endian codecs'),
      ('MESH-NUM-001', 'implemented', 'checked U64 and U128 parsing, arithmetic, and decimal conversion'),
      ('MESH-NATIVE-001', 'implemented', 'manifest-gated native archives are verified and linked'),
      ('MESH-WS-001', 'implemented', 'scheduler-aware bounded WebSocket client with cancellation'),
      ('MESH-HTTP-001', 'implemented', 'scheduler-aware bounded outbound HTTP client with cancellation'),
      ('MESH-BORSH-001', 'implemented', 'bounded Borsh reader rejects truncated and trailing data'),
      ('MESH-ANCHOR-001', 'implemented', 'Anchor discriminators and exact account layouts are validated'),
      ('MESH-SOL-READ-001', 'implemented', 'typed bounded Solana RPC and exact JitoSOL account decoding'),
      ('MESH-SOL-TX-001', 'partial', 'adapter validates simulation-only artifacts checked by Rust policy; exact transaction construction and RPC simulation remain gated'),
      ('MESH-SECRET-001', 'deferred', 'paper and shadow deployments contain no signing secret'),
      ('MESH-CRYPTO-001', 'deferred', 'signing remains outside Mesh'),
      ('MESH-SIGNER-001', 'deferred', 'isolated signer is gated until after soak and approval')
    ) AS capability(capability_id, status, evidence)
    ON CONFLICT (build_manifest_id, capability_id) DO UPDATE SET
      status = EXCLUDED.status,
      evidence = EXCLUDED.evidence,
      verified_at = now()
    RETURNING 1
  )
  SELECT count(*)::integer FROM recorded;
$$;

INSERT INTO schema_meta(version) VALUES (28);

COMMIT;
