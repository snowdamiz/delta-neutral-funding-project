from Packages.SolanaReadCli import jitosol_read_report, slot_subscription_report
from Solana.Read import AccountInfo, AccountsAtSlot, EpochInfo, pubkey

fn fixture_account(data :: String, owner :: String) -> AccountInfo ! String do
  Ok(AccountInfo {
    data : (data
      |> Bytes.from_base64()) ?,
    executable : false,
    lamports : (U64.parse("1")) ?,
    owner : (owner
      |> pubkey()) ?,
    rent_epoch : (U64.parse("18446744073709551615")) ?
  })
end

fn fixture_report() -> String ! String do
  let pool = (fixture_account(
    "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANBzc3wIAAAAA5AtUAgAAAAkDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <>
      "AAAAAAAAAAAAAAA=",
    "SPoo1Ku8WFXoNDMHPsrGSTSG1Y47rzgn41SLUNakuHy"
  )) ?
  let mint = (fixture_account(
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOQLVAIAAAAJAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
    "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  )) ?
  jitosol_read_report(
    AccountsAtSlot {
      slot : (U64.parse("320000006")) ?,
      accounts : [pool, mint]
    },
    EpochInfo {
      epoch : (U64.parse("777")) ?,
      absolute_slot : (U64.parse("320000007")) ?
    }
  )
end

describe("native Solana read CLI") do
  test("reports independently validated JitoSOL state") do
    case fixture_report() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(report) -> do
        assert(Json.get(report, "schemaVersion") == "1")
        assert(Json.get(report, "poolAddress") == "Jito4APyf642JPZPx3hGc6WWJ8zPKtRbRs4P815Awbb")
        assert(Json.get(report, "mintAddress") == "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn")
        assert(Json.get(report, "accountsSlot") == "320000006")
        assert(Json.get(report, "epochAbsoluteSlot") == "320000007")
        assert(Json.get(report, "epoch") == "777")
        assert(Json.get(report, "totalPoolLamports") == "12345678900")
        assert(Json.get(report, "supplyAtoms") == "10000000000")
        assert(Json.get(report, "navLamports") == "1234567890")
        assert(Json.get(report, "programStatus") == "valid")
      end
    end
  end

  test("reports a validated native slot subscription") do
    case slot_subscription_report(
      "{\"jsonrpc\":\"2.0\",\"result\":42,\"id\":1}",
      "{\"jsonrpc\":\"2.0\",\"method\":\"slotNotification\",\"params\":{\"result\":{\"parent\":320000005,\"root\":319999974,\"slot\":320000006},\"subscription\":42}}"
    ) do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(report) -> do
        assert(Json.get(report, "schemaVersion") == "1")
        assert(Json.get(report, "source") == "mesh-native-solana-ws")
        assert(Json.get(report, "subscription") == "42")
        assert(Json.get(report, "slot") == "320000006")
        assert(Json.get(report, "parent") == "320000005")
        assert(Json.get(report, "root") == "319999974")
        assert(Json.get(report, "status") == "valid")
      end
    end
  end
end
