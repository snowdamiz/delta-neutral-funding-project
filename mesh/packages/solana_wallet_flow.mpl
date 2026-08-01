pub struct SolanaWalletFlowEvent do
  body :: String
  event_id :: String
  event_type :: String
  wallet :: String
  observed_at_ms :: Int
  source_slot :: Int
end

fn required_string(body :: String, key :: String) -> String ! String do
  if Json.is_string(body, key) == false do
    return Err("${key} must be a JSON string")
  end
  let value = Json.get(body, key)
  if String.length(value) == 0 do
    Err("${key} is required")
  else
    Ok(value)
  end
end

fn required_int(body :: String, key :: String) -> Int ! String do
  let raw = (body |> required_string(key)) ?
  if Regex.is_match(~r/^(0|[1-9][0-9]*)$/, raw) == false do
    return Err("${key} must be a canonical non-negative integer string")
  end
  case String.to_int(raw) do
    Some(value) -> Ok(value)
    None -> Err("${key} is outside the supported integer range")
  end
end

pub fn parse_solana_wallet_flow_event(
  body :: String
) -> SolanaWalletFlowEvent ! String do
  let _root = Json.parse(body) ?
  if Json.get(body, "schemaVersion") != "1" do
    return Err("unsupported schema version")
  end
  let event_type = (body |> required_string("eventType")) ?
  if (event_type != "SolanaWalletAcquisition"
    && event_type != "SolanaWalletCheckpoint"
    && event_type != "SolanaCandidateSnapshot") do
    return Err("unsupported Solana wallet event type")
  end
  let payload = Json.get(body, "payload")
  let wallet = (payload |> required_string("wallet")) ?
  if Regex.is_match(~r/^[1-9A-HJ-NP-Za-km-z]{32,44}$/, wallet) == false do
    return Err("invalid followed Solana wallet")
  end
  let raw_hash = (body |> required_string("rawPayloadHash")) ?
  if Regex.is_match(~r/^[0-9a-f]{64}$/, raw_hash) == false do
    return Err("invalid Solana wallet payload hash")
  end
  (body |> required_string("source")) ?
  (body |> required_string("sourceSequence")) ?
  (body |> required_string("idempotencyKey")) ?
  Ok(SolanaWalletFlowEvent {
    body : body,
    event_id : (body |> required_string("eventId")) ?,
    event_type : event_type,
    wallet : wallet,
    observed_at_ms : (body |> required_int("observedAtMs")) ?,
    source_slot : (body |> required_int("sourceSlot")) ?
  })
end

pub fn persist_solana_wallet_flow_event(
  pool :: PoolHandle,
  event :: SolanaWalletFlowEvent
) -> String ! String do
  let rows = if event.event_type == "SolanaCandidateSnapshot" do
    Pool.query(
      pool,
      "SELECT record_solana_candidate_snapshot($1::jsonb)::text AS body",
      [event.body]
    ) ?
  else
    Pool.query(
      pool,
      "SELECT record_solana_wallet_flow_event($1::jsonb)::text AS body",
      [event.body]
    ) ?
  end
  if List.length(rows) != 1 do
    Err("database returned invalid Solana wallet event result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn solana_wallet_flow_state(pool :: PoolHandle) -> String ! String do
  let rows = Pool.query(
    pool,
    "SELECT solana_wallet_flow_read_model()::text AS body",
    []
  ) ?
  if List.length(rows) != 1 do
    Err("database returned invalid Solana wallet-flow state")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end
