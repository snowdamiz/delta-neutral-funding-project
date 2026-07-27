from Solana.Tx import instruction_from_jupiter_json, instruction_report_json

fn fixture() -> String do
  "{\"programId\":\"ComputeBudget111111111111111111111111111111\",\"accounts\":[{\"pubkey\":\"11111111111111111111111111111111\",\"isSigner\":false,\"isWritable\":true},{\"pubkey\":\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\",\"isSigner\":true,\"isWritable\":false}],\"data\":\"AQID\"}"
end

describe("Mesh-native Solana instruction inspection") do
  test("ingests a bounded Jupiter instruction into an allowlist report") do
    case fixture()
      |> instruction_from_jupiter_json() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(instruction) -> do
        let report = instruction
          |> instruction_report_json()
        assert(Json.get(report, "schemaVersion") == "1")
        assert(Json.get(report, "programId") == "ComputeBudget111111111111111111111111111111")
        assert(Json.get(report, "accountCount") == "2")
        assert(Json.get(report, "dataBase64") == "AQID")
        assert(Json.get(report, "dataBytes") == "3")
        assert(Json.get(report, "accountKeys") == "[\"11111111111111111111111111111111\",\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\"]")
        assert(Json.get(report, "signerKeys") == "[\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\"]")
        assert(Json.get(report, "writableKeys") == "[\"11111111111111111111111111111111\"]")
      end
    end

    let malformed = fixture()
      |> String.replace(
        "11111111111111111111111111111111",
        "not-a-pubkey"
      )
    case malformed
      |> instruction_from_jupiter_json() do
      Ok( _) -> assert(false)
      Err(error) -> assert(error == "SOLANA_PUBKEY: invalid base58")
    end
  end
end
