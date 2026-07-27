#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
instruction='{"programId":"ComputeBudget111111111111111111111111111111","accounts":[{"pubkey":"11111111111111111111111111111111","isSigner":false,"isWritable":true},{"pubkey":"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA","isSigner":true,"isWritable":false}],"data":"AQID"}'
report=$(SOLANA_INSTRUCTION_JSON=$instruction "$project_dir/bin/collector" solana-inspect-instruction)
build='{"computeBudgetInstructions":[{"programId":"ComputeBudget111111111111111111111111111111","accounts":[],"data":"AQID"}],"setupInstructions":[{"programId":"ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL","accounts":[{"pubkey":"11111111111111111111111111111111","isSigner":true,"isWritable":true}],"data":""}],"swapInstruction":{"programId":"JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4","accounts":[{"pubkey":"11111111111111111111111111111111","isSigner":true,"isWritable":true},{"pubkey":"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA","isSigner":false,"isWritable":false}],"data":"BAUG"},"cleanupInstruction":null,"otherInstructions":[{"programId":"11111111111111111111111111111111","accounts":[],"data":""}],"addressesByLookupTableAddress":{}}'
build_report=$(JUPITER_BUILD_JSON=$build "$project_dir/bin/collector" solana-inspect-jupiter-build)
transaction_report=$("$project_dir/bin/collector" solana-transaction-proof)
burst_report=$("$project_dir/bin/collector" solana-transaction-burst)

printf '%s' "$report" |
  jq -e '
    .schemaVersion == 1 and
    .programId == "ComputeBudget111111111111111111111111111111" and
    .accountCount == 2 and
    .accountKeys == [
      "11111111111111111111111111111111",
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    ] and
    .signerKeys == [
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    ] and
    .writableKeys == [
      "11111111111111111111111111111111"
    ] and
    .dataBase64 == "AQID" and
    .dataBytes == 3
  ' >/dev/null

printf '%s' "$build_report" |
  jq -e '
    .schemaVersion == 1 and
    .source == "jupiter-build" and
    .instructionCount == 4 and
    .computeBudgetCount == 1 and
    .setupCount == 1 and
    .otherCount == 1 and
    .cleanupCount == 0 and
    .tipCount == 0 and
    .dataBytes == 6 and
    .programIds == [
      "ComputeBudget111111111111111111111111111111",
      "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL",
      "11111111111111111111111111111111",
      "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"
    ] and
    .accountKeys == [
      "11111111111111111111111111111111",
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    ] and
    .signerKeys == ["11111111111111111111111111111111"] and
    .writableKeys == ["11111111111111111111111111111111"]
  ' >/dev/null

printf '%s' "$transaction_report" |
  jq -e '
    .schemaVersion == 1 and
    .source == "mesh-native-solana-tx" and
    .signerReachable == false and
    .submit == false and
    .legacy.version == "legacy" and
    .legacy.programIds == [
      "ComputeBudget111111111111111111111111111111"
    ] and
    .v0.version == "v0" and
    .v0.lookupTableKeys == [
      "Jito4APyf642JPZPx3hGc6WWJ8zPKtRbRs4P815Awbb"
    ] and
    .computeBudget.programId ==
      "ComputeBudget111111111111111111111111111111" and
    .transferChecked.programId ==
      "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" and
    .simulation.method == "simulateTransaction" and
    .simulation.sigVerify == false and
    .simulation.replaceRecentBlockhash == false and
    .simulation.transactionBytes == 175
  ' >/dev/null

printf '%s' "$burst_report" |
  jq -e '
    .schemaVersion == 1 and
    .source == "mesh-native-solana-tx-burst" and
    .status == "passed" and
    .iterations == 1000 and
    .elapsedNanoseconds > 0 and
    .nanosecondsPerIteration > 0 and
    .residentBeforeBytes > 0 and
    .residentAfterBytes <= 134217728
  ' >/dev/null

jq -n \
  --argjson report "$report" \
  --argjson build "$build_report" \
  --argjson transaction "$transaction_report" \
  --argjson burst "$burst_report" \
  '{status: "passed", report: $report, build: $build, transaction: $transaction, burst: $burst}'
