from Solana.Read import hash_value, jitosol_mint, jitosol_stake_pool, pubkey
from Solana.Tx import AddressTableLookup, CompiledInstruction, LegacyMessage, MessageHeader, MessageV0, compute_unit_limit_instruction, instruction_report_json, legacy_message_report_json, message_v0_report_json, serialize_unsigned_legacy_transaction, simulate_transaction_request, transfer_checked_instruction

pub fn native_solana_transaction_report() -> String ! String do
  let payer = ("11111111111111111111111111111111"
    |> pubkey()) ?
  let compute = (1_000_000
    |> compute_unit_limit_instruction()) ?
  let blockhash = ("11111111111111111111111111111111"
    |> hash_value()) ?
  let legacy = LegacyMessage {
    header : MessageHeader {
      num_required_signatures : 1,
      num_readonly_signed_accounts : 0,
      num_readonly_unsigned_accounts : 1
    },
    account_keys : [payer, compute.program_id],
    recent_blockhash : blockhash,
    instructions : [
      CompiledInstruction {
        program_id_index : 1,
        account_indexes : [0],
        data : compute.data
      }
    ]
  }
  let v0 = MessageV0 {
    header : legacy.header,
    static_account_keys : legacy.account_keys,
    recent_blockhash : legacy.recent_blockhash,
    instructions : legacy.instructions,
    address_table_lookups : [
      AddressTableLookup {
        account_key : (jitosol_stake_pool()) ?,
        writable_indexes : [0],
        readonly_indexes : [1]
      }
    ]
  }
  let unsigned = (legacy
    |> serialize_unsigned_legacy_transaction()) ?
  let simulation = (unsigned |2> simulate_transaction_request(
    1,
    "confirmed",
    false,
    None
  )) ?
  let transfer = (payer
    |> transfer_checked_instruction(
      (jitosol_mint()) ?,
      (jitosol_stake_pool()) ?,
      payer,
      ("1"
        |> U64.parse()) ?,
      9
    )) ?
  let legacy_report = (legacy
    |> legacy_message_report_json()) ?
  let v0_report = (v0
    |> message_v0_report_json()) ?
  let compute_report = compute
    |> instruction_report_json()
  let transfer_report = transfer
    |> instruction_report_json()
  let simulation_report = json {
    method : simulation.method,
    commitment : "confirmed",
    encoding : "base64",
    sigVerify : false,
    replaceRecentBlockhash : false,
    transactionBytes : Bytes.length(unsigned)
  }
  Ok("{\"schemaVersion\":1,\"source\":\"mesh-native-solana-tx\",\"signerReachable\":false,\"submit\":false,\"legacy\":#{legacy_report},\"v0\":#{v0_report},\"computeBudget\":#{compute_report},\"transferChecked\":#{transfer_report},\"simulation\":#{simulation_report}}")
end
