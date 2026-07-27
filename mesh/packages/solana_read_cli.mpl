from Solana.Read import AccountsAtSlot, EpochInfo, epoch_info_from_response, get_epoch_info_request, get_multiple_accounts_request, jitosol_mint, jitosol_nav, jitosol_stake_pool, mint, multiple_accounts_from_response, pubkey_string, rpc_response, rpc_send, send_slot_subscription, slot_notification, stake_pool

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

pub fn slot_subscription_report(ack_raw :: String, notification_raw :: String) -> String ! String do
  let ack = (ack_raw
    |> rpc_response()) ?
  if ack.id != 1 || ack.ok == false do
    Err("SOLANA_WS: invalid slot subscription acknowledgement")
  else
    let subscription = ((ack.result_json
      |> U64.parse()) ?
      |> U64.to_int()) ?
    let notification = (notification_raw
      |> slot_notification()) ?
    if notification.subscription != subscription do
      Err("SOLANA_WS: slot notification subscription mismatch")
    else
      if U64.compare(notification.slot, notification.parent) <= 0 || U64.compare(notification.parent, notification.root) < 0 do
        Err("SOLANA_WS: invalid slot lineage")
      else
        Ok(json {
          schemaVersion : 1,
          source : "mesh-native-solana-ws",
          subscription : subscription,
          slot : notification.slot
            |> U64.to_string(),
          parent : notification.parent
            |> U64.to_string(),
          root : notification.root
            |> U64.to_string(),
          status : "valid"
        })
      end
    end
  end
end

fn ws_text(message :: WsMessage) -> String ! String do
  if message.kind == "text" do
    message.data
      |> Bytes.to_utf8()
  else
    Err("SOLANA_WS: expected a text message")
  end
end

fn fetch_slot_subscription(connection :: Int) -> String ! String do
  (connection
    |> send_slot_subscription(1)) ?
  let ack = ((connection
    |> WsClient.recv(5000)) ?
    |> ws_text()) ?
  ((connection
    |> WsClient.recv(10000)) ?
    |> ws_text()) ?
    |2> slot_subscription_report(ack)
end

pub fn run_native_solana_subscription(url :: String) -> String ! String do
  if String.starts_with(url, "wss://") == false do
    Err("SOLANA_WS: SOLANA_WS_URL must use WSS")
  else
    let options = WsClient.options()
      |> WsClient.connect_timeout(5000)
      |> WsClient.heartbeat_timeout(10000)
      |> WsClient.max_message_bytes(32768)
      |> WsClient.queue_capacity(8)
    case url
      |> WsClient.connect(options) do
      Err(reason) -> Err(reason)
      Ok(connection) -> do
        let report = fetch_slot_subscription(connection)
        let closed = connection
          |> WsClient.close(1000, "proof_complete")
        case report do
          Err(reason) -> Err(reason)
          Ok(output) -> case closed do
            Err(reason) -> Err(reason)
            Ok( _) -> Ok(output)
          end
        end
      end
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
