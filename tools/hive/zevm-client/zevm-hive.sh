#!/usr/bin/env bash
set -euo pipefail

chain_id="${HIVE_CHAIN_ID:-31337}"
blob_base_fee="${ZEVM_HIVE_BLOB_BASE_FEE:-1}"
zevm_pid=""
config_path="$(mktemp)"

cleanup() {
  if [ -n "$zevm_pid" ]; then
    kill "$zevm_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$config_path"
}
trap cleanup EXIT INT TERM

has_genesis=false
genesis_path=""
if [ -f /genesis.json ]; then
  has_genesis=true
  genesis_path="/genesis.json"
fi

has_chain_rlp=false
chain_rlp_path=""
if [ -f /chain.rlp ]; then
  has_chain_rlp=true
  chain_rlp_path="/chain.rlp"
fi

jq -n \
  --argjson chainId "$chain_id" \
  --arg blobBaseFee "$blob_base_fee" \
  --argjson hasGenesis "$has_genesis" \
  --arg genesisPath "$genesis_path" \
  --argjson hasChainRlp "$has_chain_rlp" \
  --arg chainRlpPath "$chain_rlp_path" \
  --argjson homestead "${HIVE_FORK_HOMESTEAD:-0}" \
  --argjson tangerine "${HIVE_FORK_TANGERINE:-0}" \
  --argjson spurious "${HIVE_FORK_SPURIOUS:-0}" \
  --argjson byzantium "${HIVE_FORK_BYZANTIUM:-0}" \
  --argjson petersburg "${HIVE_FORK_PETERSBURG:-0}" \
  --argjson istanbul "${HIVE_FORK_ISTANBUL:-0}" \
  --argjson muir "${HIVE_FORK_MUIR_GLACIER:-0}" \
  --argjson berlin "${HIVE_FORK_BERLIN:-0}" \
  --argjson london "${HIVE_FORK_LONDON:-0}" \
  --argjson arrow "${HIVE_FORK_ARROW_GLACIER:-0}" \
  --argjson gray "${HIVE_FORK_GRAY_GLACIER:-0}" \
  --argjson merge "${HIVE_MERGE_BLOCK_ID:-0}" \
  --argjson shanghaiTs "${HIVE_SHANGHAI_TIMESTAMP:-0}" \
  --argjson cancunTs "${HIVE_CANCUN_TIMESTAMP:-0}" \
  --argjson pragueTs "${HIVE_PRAGUE_TIMESTAMP:-9223372036854775807}" \
  '{
    rpc: { host: "0.0.0.0", port: 8545 },
    engineRpc: { host: "0.0.0.0", port: 8551 },
    mode: {
      trusted: {
        chainId: $chainId,
        blobBaseFee: $blobBaseFee,
        mining: { type: "manual" },
        genesis: (if $hasGenesis then $genesisPath else null end),
        chainRlp: (if $hasChainRlp then $chainRlpPath else null end),
        hardfork: {
          homesteadBlock: $homestead,
          tangerineWhistleBlock: $tangerine,
          spuriousDragonBlock: $spurious,
          byzantiumBlock: $byzantium,
          petersburgBlock: $petersburg,
          istanbulBlock: $istanbul,
          muirGlacierBlock: $muir,
          berlinBlock: $berlin,
          londonBlock: $london,
          arrowGlacierBlock: $arrow,
          grayGlacierBlock: $gray,
          mergeBlock: $merge,
          shanghaiTimestamp: $shanghaiTs,
          cancunTimestamp: $cancunTs,
          pragueTimestamp: $pragueTs
        }
      }
    }
  }' > "$config_path"

/usr/local/bin/zevm --config "$config_path" &
zevm_pid="$!"
wait "$zevm_pid"
