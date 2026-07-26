from Packages.Accounting import realized_funding_usd
from Packages.ExecutionIntents import ExecutionIntent, canonical_execution_intent, execution_intent_hash
from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros, position_delta
from Packages.StrategyCore import expected_funding_usd_micros, jitosol_nav_lamports

fn required_int(body :: String, key :: String) -> Int ! String do
  case (body
    |> Json.get(key)
    |> String.to_int) do
    Some(value) -> Ok(value)
    None -> Err("invalid conformance integer: ${key}")
  end
end

fn matches_fixed_vector(path :: String) -> Bool ! String do
  let body = File.read(path) ?
  Json.parse(body) ?
  let nav = (Lamports { atoms : (body |> required_int("totalPoolLamports")) ? }
    |> jitosol_nav_lamports(TokenAtoms {
      atoms : (body |> required_int("supplyAtoms")) ?
    })) ?
  let funding = (UsdMicros { atoms : (body |> required_int("notionalUsdMicros")) ? }
    |> expected_funding_usd_micros(RatePpm {
      atoms : (body |> required_int("expectedFundingRatePpm")) ?
    })) ?
  let delta = (TokenAtoms { atoms : (body |> required_int("spotQuantityAtoms")) ? }
    |> position_delta(
      Lamports { atoms : (body |> required_int("marketRateLamports")) ? },
      Lamports { atoms : (body |> required_int("perpShortLamports")) ? }
    )) ?
  let realized = (Lamports {
    atoms : (body |> required_int("realizedShortQuantityLamports")) ?
  } |> realized_funding_usd(
    UsdMicros { atoms : (body |> required_int("solPriceUsdMicros")) ? },
    RatePpm { atoms : (body |> required_int("realizedShortRatePpm")) ? }
  )) ?
  Ok(
    nav.atoms == (body |> required_int("expectedNavLamports")) ?
      && funding.atoms == (body |> required_int("expectedFundingUsdMicros")) ?
      && delta.spot_equivalent_lamports.atoms == (body |> required_int("expectedSpotEquivalentLamports")) ?
      && delta.delta_lamports.atoms == (body |> required_int("expectedDeltaLamports")) ?
      && delta.delta_bps == (body |> required_int("expectedDeltaBps")) ?
      && realized.atoms == (body |> required_int("expectedRealizedFundingUsdMicros")) ?
  )
end

fn matches_intent_vector(path :: String) -> Bool ! String do
  let body = File.read(path) ?
  let intent = ExecutionIntent {
    intent_id : Json.get(body, "intentId"),
    strategy_run_id : Json.get(body, "strategyRunId"),
    state_version : (body |> required_int("stateVersion")) ?,
    variant : Json.get(body, "variant"),
    operation : Json.get(body, "operation"),
    leg : Json.get(body, "leg"),
    instrument : Json.get(body, "instrument"),
    side : Json.get(body, "side"),
    max_quantity_atoms : (body |> required_int("maxQuantityAtoms")) ?,
    limit_price_atoms : (body |> required_int("limitPriceAtoms")) ?,
    max_slippage_bps : (body |> required_int("maxSlippageBps")) ?,
    reduce_only : Json.get(body, "reduceOnly") == "true",
    expires_at_ms : (body |> required_int("expiresAtMs")) ?,
    policy_profile : Json.get(body, "policyProfile"),
    snapshot_ids : [Json.get(body, "snapshotId")],
    config_hash : Json.get(body, "configHash")
  }
  let canonical = (intent
    |> canonical_execution_intent) ?
  let hash = (intent
    |> execution_intent_hash) ?
  Ok(canonical == Json.get(body, "expectedCanonical") && hash == Json.get(body, "expectedHash"))
end

describe("cross-language conformance vectors") do
  test("matches fixed-point and canonical intent values") do
    case matches_fixed_vector("tests/vectors/fixed-point-baseline-v1.json") do
      Ok(matches) -> assert(matches)
      Err(error) -> assert(false)
    end
    case matches_fixed_vector("tests/vectors/fixed-point-boundary-v1.json") do
      Ok(matches) -> assert(matches)
      Err(error) -> assert(false)
    end

    case matches_intent_vector("tests/vectors/execution-intent-v1.json") do
      Ok(matches) -> assert(matches)
      Err(error) -> assert(false)
    end
  end
end
