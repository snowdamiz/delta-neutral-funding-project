from Solana.Read import LatestBlockhash, Mint, StakePoolState, get_account_info_request, get_latest_blockhash_request, hash_string, jitosol_mint, jitosol_nav, jitosol_stake_pool, latest_blockhash_from_response, pubkey_string, rpc_request_json, rpc_response

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

fn latest_blockhash_fixture() -> LatestBlockhash ! String do
  let response = ("{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{\"context\":{\"slot\":123},\"value\":{\"blockhash\":\"11111111111111111111111111111111\",\"lastValidBlockHeight\":456}}}"
    |> rpc_response()) ?
  latest_blockhash_from_response(response)
end

describe("Mesh-native Solana read capability") do
  test("validates JitoSOL identities and exact NAV arithmetic") do
    assert(native_jitosol_nav_matches())
  end

  test("builds a canonical bounded account request") do
    assert(canonical_account_request_matches())
  end

  test("builds and parses a recent blockhash request") do
    case get_latest_blockhash_request(10, "confirmed") do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(request) -> assert(
        rpc_request_json(request) ==
          "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"getLatestBlockhash\",\"params\":[{\"commitment\":\"confirmed\"}]}"
      )
    end
    case latest_blockhash_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(value) -> do
        assert(U64.to_string(value.context_slot) == "123")
        assert(hash_string(value.blockhash) == "11111111111111111111111111111111")
        assert(U64.to_string(value.last_valid_block_height) == "456")
      end
    end
  end
end
