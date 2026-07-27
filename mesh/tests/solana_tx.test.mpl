from Packages.SolanaTxCli import native_solana_transaction_report
from Solana.Read import Hash, Pubkey, RpcRequest, pubkey_string, rpc_request_json, rpc_response
from Solana.Tx import AddressTableLookup, CompiledInstruction, Instruction, LegacyMessage, MessageHeader, MessageV0, SimulationResult, compute_unit_limit_instruction, compute_unit_price_instruction, create_associated_token_idempotent_instruction, instruction_from_jupiter_json, instruction_report_json, jupiter_instruction_set_from_json, jupiter_instruction_set_report_json, legacy_message_report_json, message_v0_report_json, serialize_legacy_message, serialize_message_v0, serialize_unsigned_legacy_transaction, simulate_transaction_request, simulation_result, transfer_checked_instruction

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

fn message_v0_fixture() -> MessageV0 ! String do
  Ok(MessageV0 {
    header: MessageHeader {
      num_required_signatures: 1,
      num_readonly_signed_accounts: 0,
      num_readonly_unsigned_accounts: 1
    },
    static_account_keys: [
      Pubkey { bytes: ("0000000000000000000000000000000000000000000000000000000000000000" |> Bytes.from_hex())? },
      Pubkey { bytes: ("0101010101010101010101010101010101010101010101010101010101010101" |> Bytes.from_hex())? }
    ],
    recent_blockhash: Hash { bytes: ("0202020202020202020202020202020202020202020202020202020202020202" |> Bytes.from_hex())? },
    instructions: [
      CompiledInstruction {
        program_id_index: 1,
        account_indexes: [0, 2],
        data: ("aabb" |> Bytes.from_hex())?
      }
    ],
    address_table_lookups: [
      AddressTableLookup {
        account_key: Pubkey { bytes: ("0303030303030303030303030303030303030303030303030303030303030303" |> Bytes.from_hex())? },
        writable_indexes: [4],
        readonly_indexes: [5]
      }
    ]
  })
end

fn compute_budget_fixture() -> List < Instruction > ! String do
  Ok([
    compute_unit_limit_instruction(1_000_000) ?,
    compute_unit_price_instruction(("5000"
      |> U64.parse()) ?) ?
  ])
end

fn token_instruction_fixture() -> List < Instruction > ! String do
  let source = Pubkey { bytes: ("0000000000000000000000000000000000000000000000000000000000000000"
    |> Bytes.from_hex()) ? }
  let mint = Pubkey { bytes: ("0101010101010101010101010101010101010101010101010101010101010101"
    |> Bytes.from_hex()) ? }
  let destination = Pubkey { bytes: ("0202020202020202020202020202020202020202020202020202020202020202"
    |> Bytes.from_hex()) ? }
  let authority = Pubkey { bytes: ("0303030303030303030303030303030303030303030303030303030303030303"
    |> Bytes.from_hex()) ? }
  Ok([
    transfer_checked_instruction(
      source,
      mint,
      destination,
      authority,
      ("1000000000"
        |> U64.parse()) ?,
      9
    ) ?,
    create_associated_token_idempotent_instruction(
      source,
      destination,
      authority,
      mint
    ) ?
  ])
end

fn simulation_request_fixture() -> RpcRequest ! String do
  let message = legacy_message_fixture() ?
  let transaction = serialize_unsigned_legacy_transaction(message) ?
  simulate_transaction_request(
    7,
    transaction,
    "confirmed",
    true,
    Some(("123"
      |> U64.parse()) ?)
  )
end

fn simulation_result_fixture() -> SimulationResult ! String do
  let response = ("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"context\":{\"slot\":123},\"value\":{\"err\":null,\"logs\":[\"Program log: ok\"],\"unitsConsumed\":42,\"replacementBlockhash\":{\"blockhash\":\"11111111111111111111111111111111\",\"lastValidBlockHeight\":999},\"accounts\":null,\"returnData\":null,\"innerInstructions\":[]}}}"
    |> rpc_response()) ?
  simulation_result(response)
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

  test("serializes a v0 message and address lookup to the exact Solana wire format") do
    case message_v0_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(message) -> case message
        |> serialize_message_v0() do
        Err(error) -> do
          println(error)
          assert(false)
        end
        Ok(bytes) -> assert(
          Bytes.to_hex(bytes) ==
            "8001000102000000000000000000000000000000000000000000000000000000000000000001010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202010102000202aabb01030303030303030303030303030303030303030303030303030303030303030301040105"
        )
      end
    end
  end

  test("reports legacy and v0 messages without exposing transaction bytes") do
    case legacy_message_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(message) -> case legacy_message_report_json(message) do
        Err(error) -> do
          println(error)
          assert(false)
        end
        Ok(report) -> do
          assert(Json.get(report, "version") == "legacy")
          assert(Json.get(report, "requiredSignatures") == "1")
          assert(Json.get(report, "instructionCount") == "1")
          assert(Json.get(report, "messageBytes") == "110")
          assert(Json.get(report, "programIds") == "[\"4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi\"]")
          assert(Json.get(report, "lookupTableKeys") == "[]")
          assert(!String.contains(report, "AQAAAAAAAA"))
        end
      end
    end

    case message_v0_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(message) -> case message_v0_report_json(message) do
        Err(error) -> do
          println(error)
          assert(false)
        end
        Ok(report) -> do
          assert(Json.get(report, "version") == "v0")
          assert(Json.get(report, "instructionCount") == "1")
          assert(Json.get(report, "lookupTableKeys") == "[\"CktRuQ2mttgRGkXJtyksdKHjUdc2C4TgDzyB98oEzy8\"]")
          assert(Json.get(report, "loadedWritableAccounts") == "1")
          assert(Json.get(report, "loadedReadonlyAccounts") == "1")
          assert(!String.contains(report, "aabb"))
        end
      end
    end
  end

  test("builds exact compute budget instructions") do
    case compute_budget_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(instructions) -> do
        let limit = List.get(instructions, 0)
        let price = List.get(instructions, 1)
        assert(pubkey_string(limit.program_id) == "ComputeBudget111111111111111111111111111111")
        assert(List.length(limit.accounts) == 0)
        assert(Bytes.to_hex(limit.data) == "0240420f00")
        assert(pubkey_string(price.program_id) == "ComputeBudget111111111111111111111111111111")
        assert(List.length(price.accounts) == 0)
        assert(Bytes.to_hex(price.data) == "038813000000000000")
      end
    end
  end

  test("builds exact SPL transfer and idempotent associated-token instructions") do
    case token_instruction_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(instructions) -> do
        let transfer = List.get(instructions, 0)
        let transfer_source = List.get(transfer.accounts, 0)
        let transfer_mint = List.get(transfer.accounts, 1)
        let transfer_destination = List.get(transfer.accounts, 2)
        let transfer_authority = List.get(transfer.accounts, 3)
        assert(pubkey_string(transfer.program_id) == "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
        assert(Bytes.to_hex(transfer.data) == "0c00ca9a3b0000000009")
        assert(List.length(transfer.accounts) == 4)
        assert(!transfer_source.signer && transfer_source.writable)
        assert(!transfer_mint.signer && !transfer_mint.writable)
        assert(!transfer_destination.signer && transfer_destination.writable)
        assert(transfer_authority.signer && !transfer_authority.writable)

        let associated = List.get(instructions, 1)
        let payer = List.get(associated.accounts, 0)
        let account = List.get(associated.accounts, 1)
        assert(pubkey_string(associated.program_id) == "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")
        assert(Bytes.to_hex(associated.data) == "01")
        assert(List.length(associated.accounts) == 6)
        assert(payer.signer && payer.writable)
        assert(!account.signer && account.writable)
        assert(pubkey_string(List.get(associated.accounts, 4).pubkey) == "11111111111111111111111111111111")
        assert(pubkey_string(List.get(associated.accounts, 5).pubkey) == "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
      end
    end
  end

  test("builds an unsigned transaction and bounded simulation request") do
    case simulation_request_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(request) -> do
        assert(request.method == "simulateTransaction")
        assert(request.params_json ==
          "[\"AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAECAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAQEBAAUCAQEAAA==\",{\"commitment\":\"confirmed\",\"encoding\":\"base64\",\"sigVerify\":false,\"replaceRecentBlockhash\":true,\"minContextSlot\":123}]"
        )
        assert(Json.get(rpc_request_json(request), "id") == "7")
      end
    end
  end

  test("parses an inspectable simulation result") do
    case simulation_result_fixture() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(result) -> do
        assert(U64.to_string(result.slot) == "123")
        assert(result.succeeded)
        assert(result.error_json == "")
        assert(result.logs_json == "[\"Program log: ok\"]")
        case result.units_consumed do
          None -> assert(false)
          Some(units) -> assert(U64.to_string(units) == "42")
        end
        assert(Json.get(result.replacement_blockhash_json, "lastValidBlockHeight") == "999")
      end
    end
  end

  test("exposes a networkless transaction construction proof") do
    case native_solana_transaction_report() do
      Err(error) -> do
        println(error)
        assert(false)
      end
      Ok(report) -> do
        assert(Json.get(report, "schemaVersion") == "1")
        assert(Json.get(report, "source") == "mesh-native-solana-tx")
        assert(Json.get(report, "signerReachable") == "false")
        assert(Json.get(report, "submit") == "false")
        assert(Json.get(Json.get(report, "legacy"), "version") == "legacy")
        assert(Json.get(Json.get(report, "v0"), "version") == "v0")
        assert(Json.get(Json.get(report, "simulation"), "method") == "simulateTransaction")
        assert(Json.get(Json.get(report, "simulation"), "sigVerify") == "false")
        assert(Json.get(Json.get(report, "simulation"), "transactionBytes") == "175")
        assert(!String.contains(report, "AQAAAAAAAA"))
      end
    end
  end
end
