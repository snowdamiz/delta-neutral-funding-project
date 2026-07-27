from Solana.Read import Mint, StakePoolState, get_account_info_request, jitosol_mint, jitosol_nav, jitosol_stake_pool, pubkey_string, rpc_request_json

fn native_jitosol_nav() -> String ! String do
  let epoch = (U64.parse("777")) ?
  let supply = (U64.parse("10000000000")) ?
  let nav = (
    (jitosol_stake_pool()) ?
    |> jitosol_nav(
      StakePoolState {
        account_type : 1,
        total_lamports : (U64.parse("12345678900")) ?,
        pool_token_supply : supply,
        last_update_epoch : epoch
      },
      (jitosol_mint()) ?,
      Mint {
        mint_authority : None,
        supply : supply,
        decimals : 9,
        initialized : true,
        freeze_authority : None
      },
      epoch
    )
  ) ?
  Ok(nav |> U128.to_string())
end

fn native_jitosol_nav_matches() -> Bool do
  case native_jitosol_nav() do
    Ok(value) -> value == "1234567890"
    Err(_error) -> false
  end
end

fn canonical_account_request_matches() -> Bool do
  case jitosol_mint() do
    Err(_error) -> false
    Ok(mint_address) -> do
      if (mint_address
        |> pubkey_string()
        |> String.length()) != 44 do
        return false
      end
      case (9
        |> get_account_info_request(mint_address, "finalized")) do
        Err(_error) -> false
        Ok(request) -> (request
          |> rpc_request_json()) == "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"getAccountInfo\",\"params\":[\"J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn\",{\"commitment\":\"finalized\",\"encoding\":\"base64\"}]}"
      end
    end
  end
end

describe("Mesh-native Solana read capability") do
  test("validates JitoSOL identities and exact NAV arithmetic") do
    assert(native_jitosol_nav_matches())
  end

  test("builds a canonical bounded account request") do
    assert(canonical_account_request_matches())
  end
end
