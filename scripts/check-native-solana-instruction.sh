#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
instruction='{"programId":"ComputeBudget111111111111111111111111111111","accounts":[{"pubkey":"11111111111111111111111111111111","isSigner":false,"isWritable":true},{"pubkey":"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA","isSigner":true,"isWritable":false}],"data":"AQID"}'
report=$(SOLANA_INSTRUCTION_JSON=$instruction "$project_dir/bin/collector" solana-inspect-instruction)

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

jq -n --argjson report "$report" '{status: "passed", report: $report}'
