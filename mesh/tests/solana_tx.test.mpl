from Solana.Read import Hash, Pubkey
from Solana.Tx import CompiledInstruction, LegacyMessage, MessageHeader, instruction_from_jupiter_json, instruction_report_json, jupiter_instruction_set_from_json, jupiter_instruction_set_report_json, serialize_legacy_message

fn fixture() -> String do
  "{\"programId\":\"ComputeBudget111111111111111111111111111111\",\"accounts\":[{\"pubkey\":\"11111111111111111111111111111111\",\"isSigner\":false,\"isWritable\":true},{\"pubkey\":\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\",\"isSigner\":true,\"isWritable\":false}],\"data\":\"AQID\"}"
end

fn build_fixture() -> String do
  "{\"computeBudgetInstructions\":[{\"programId\":\"ComputeBudget111111111111111111111111111111\",\"accounts\":[],\"data\":\"AQID\"}],\"setupInstructions\":[{\"programId\":\"ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL\",\"accounts\":[{\"pubkey\":\"11111111111111111111111111111111\",\"isSigner\":true,\"isWritable\":true}],\"data\":\"\"}],\"swapInstruction\":{\"programId\":\"JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4\",\"accounts\":[{\"pubkey\":\"11111111111111111111111111111111\",\"isSigner\":true,\"isWritable\":true},{\"pubkey\":\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\",\"isSigner\":false,\"isWritable\":false}],\"data\":\"BAUG\"},\"cleanupInstruction\":null,\"otherInstructions\":[{\"programId\":\"11111111111111111111111111111111\",\"accounts\":[],\"data\":\"\"}],\"addressesByLookupTableAddress\":{}}"
end

fn legacy_message_fixture() -> LegacyMessage ! String do
  Ok(LegacyMessage {
    header: MessageHeader {
      num_required_signatures: 1,
      num_readonly_signed_accounts: 0,
      num_readonly_unsigned_accounts: 1
    },
    account_keys: [
      Pubkey { bytes: ("0000000000000000000000000000000000000000000000000000000000000000" |> Bytes.from_hex())? },
      Pubkey { bytes: ("0101010101010101010101010101010101010101010101010101010101010101" |> Bytes.from_hex())? }
    ],
    recent_blockhash: Hash { bytes: ("0202020202020202020202020202020202020202020202020202020202020202" |> Bytes.from_hex())? },
    instructions: [
      CompiledInstruction {
        program_id_index: 1,
        account_indexes: [0],
        data: ("0201010000" |> Bytes.from_hex())?
      }
    ]
  })
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

  test("aggregates the complete bounded Jupiter instruction set") do
    case build_fixture()
      |> jupiter_instruction_set_from_json() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(instructions) -> do
        let report = instructions
          |> jupiter_instruction_set_report_json()
        assert(Json.get(report, "schemaVersion") == "1")
        assert(Json.get(report, "source") == "jupiter-build")
        assert(Json.get(report, "instructionCount") == "4")
        assert(Json.get(report, "computeBudgetCount") == "1")
        assert(Json.get(report, "setupCount") == "1")
        assert(Json.get(report, "otherCount") == "1")
        assert(Json.get(report, "cleanupCount") == "0")
        assert(Json.get(report, "tipCount") == "0")
        assert(Json.get(report, "dataBytes") == "6")
        assert(Json.get(report, "programIds") == "[\"ComputeBudget111111111111111111111111111111\",\"ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL\",\"11111111111111111111111111111111\",\"JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4\"]")
        assert(Json.get(report, "accountKeys") == "[\"11111111111111111111111111111111\",\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\"]")
        assert(Json.get(report, "signerKeys") == "[\"11111111111111111111111111111111\"]")
        assert(Json.get(report, "writableKeys") == "[\"11111111111111111111111111111111\"]")
      end
    end

    case build_fixture()
      |> String.replace(
        "\"otherInstructions\":[{\"programId\":\"11111111111111111111111111111111\",\"accounts\":[],\"data\":\"\"}],",
        ""
      )
      |> jupiter_instruction_set_from_json() do
      Ok( _) -> assert(false)
      Err(error) -> assert(error == "SOLANA_TX: missing field otherInstructions")
    end
  end

  test("serializes a legacy message to the exact Solana wire format") do
    case legacy_message_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(message) -> case message
        |> serialize_legacy_message() do
        Err(error) -> do
          println(error)
          assert(false)
        end
        Ok(bytes) -> assert(
          Bytes.to_hex(bytes) ==
            "0100010200000000000000000000000000000000000000000000000000000000000000000101010101010101010101010101010101010101010101010101010101010101020202020202020202020202020202020202020202020202020202020202020201010100050201010000"
        )
      end
    end
  end
end
