from Solana.Read import AccountsAtSlot, EpochInfo, epoch_info_from_response, get_epoch_info_request, get_multiple_accounts_request, jitosol_mint, jitosol_nav, jitosol_stake_pool, mint, multiple_accounts_from_response, pubkey_string, rpc_send, stake_pool

pub fn jitosol_read_report(accounts :: AccountsAtSlot, epoch :: EpochInfo) -> String ! String do
  if List.length(accounts.accounts) != 2 do
    Err("SOLANA_READ: expected stake-pool and mint accounts")
  else
    let pool_account = accounts.accounts
      |> List.get(0)
    let mint_account = accounts.accounts
      |> List.get(1)
    if pool_account.executable || mint_account.executable do
      Err("SOLANA_READ: data accounts must not be executable")
    else
      let pool_address = (jitosol_stake_pool()) ?
      let mint_address = (jitosol_mint()) ?
      let pool_state = (pool_account
        |> stake_pool()) ?
      let mint_state = (mint_account
        |> mint()) ?
      let nav = (pool_address
        |> jitosol_nav(
          pool_state,
          mint_address,
          mint_state,
          epoch.epoch
        )) ?
      Ok(json {
        schemaVersion : 1,
        source : "mesh-native-solana",
        commitment : "confirmed",
        poolAddress : pool_address
          |> pubkey_string(),
        mintAddress : mint_address
          |> pubkey_string(),
        accountsSlot : accounts.slot
          |> U64.to_string(),
        epochAbsoluteSlot : epoch.absolute_slot
          |> U64.to_string(),
        epoch : epoch.epoch
          |> U64.to_string(),
        totalPoolLamports : pool_state.total_lamports
          |> U64.to_string(),
        supplyAtoms : pool_state.pool_token_supply
          |> U64.to_string(),
        navLamports : nav
          |> U128.to_string(),
        programStatus : "valid"
      })
    end
  end
end

fn fetch_jitosol(client :: Int, url :: String) -> String ! String do
  let accounts = (((1
    |> get_multiple_accounts_request(
      [(jitosol_stake_pool()) ?, (jitosol_mint()) ?],
      "confirmed"
    )) ? |3> rpc_send(client, url, 5000, 32768)) ?
    |> multiple_accounts_from_response()) ?
  let epoch = (((2
    |> get_epoch_info_request("confirmed")) ?
    |3> rpc_send(client, url, 5000, 32768)) ?
    |> epoch_info_from_response()) ?
  jitosol_read_report(accounts, epoch)
end

pub fn run_native_solana_read(url :: String) -> String ! String do
  if String.starts_with(url, "https://") == false do
    Err("SOLANA_READ: SOLANA_RPC_URL must use HTTPS")
  else
    let client = Http.client()
    let report = fetch_jitosol(client, url)
    Http.client_close(client)
    report
  end
end
