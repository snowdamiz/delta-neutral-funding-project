BEGIN;

CREATE TABLE language_capability_results (
  build_manifest_id text NOT NULL REFERENCES build_manifests(id)
    ON DELETE CASCADE,
  capability_id text NOT NULL CHECK (
    capability_id ~ '^MESH-[A-Z-]+-[0-9]{3}$'
  ),
  status text NOT NULL CHECK (
    status IN ('implemented', 'project_local', 'partial', 'bridged', 'deferred')
  ),
  evidence text NOT NULL CHECK (length(btrim(evidence)) > 0),
  verified_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (build_manifest_id, capability_id)
);

CREATE FUNCTION record_language_capability_results(
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
      ('MESH-BYTES-001', 'bridged', 'adapter carries binary account data as validated base64'),
      ('MESH-CODEC-001', 'bridged', 'adapter owns base64, base58, and account decoding'),
      ('MESH-NUM-001', 'bridged', 'adapter bounds unsigned values into canonical decimal strings'),
      ('MESH-NATIVE-001', 'bridged', 'isolated adapter and executor remain the native boundary'),
      ('MESH-WS-001', 'bridged', 'read-only protocol adapter owns external transport'),
      ('MESH-HTTP-001', 'bridged', 'read-only protocol adapter owns outbound HTTP'),
      ('MESH-BORSH-001', 'bridged', 'adapter decodes stake-pool account bytes'),
      ('MESH-ANCHOR-001', 'bridged', 'venue adapter owns protocol-specific account decoding'),
      ('MESH-SOL-READ-001', 'bridged', 'adapter normalizes Solana RPC state for Mesh'),
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

INSERT INTO schema_meta(version) VALUES (27);

COMMIT;
