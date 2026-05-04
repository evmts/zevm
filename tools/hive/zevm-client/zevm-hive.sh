#!/usr/bin/env bash
set -euo pipefail

chain_id="${HIVE_CHAIN_ID:-31337}"
blob_base_fee="${ZEVM_HIVE_BLOB_BASE_FEE:-1}"
zevm_pid=""
proxy_pids=()
config_path="$(mktemp)"
internal_rpc_port="${ZEVM_HIVE_INTERNAL_RPC_PORT:-18545}"
internal_engine_port="${ZEVM_HIVE_INTERNAL_ENGINE_PORT:-18551}"
rpc_url="http://127.0.0.1:${internal_rpc_port}"

cleanup() {
  for proxy_pid in "${proxy_pids[@]}"; do
    kill "$proxy_pid" >/dev/null 2>&1 || true
  done
  if [ -n "$zevm_pid" ]; then
    kill "$zevm_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$config_path"
}
trap cleanup EXIT INT TERM

wait_for_rpc() {
  for _ in $(seq 1 200); do
    if curl -fsS \
      -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
      "$rpc_url" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$zevm_pid" >/dev/null 2>&1; then
      echo "zevm exited before RPC became ready" >&2
      return 1
    fi
    sleep 0.05
  done

  echo "timed out waiting for zevm RPC" >&2
  return 1
}

send_raw_transaction() {
  local raw_tx="$1"
  local response
  response="$(jq -n --arg tx "$raw_tx" \
    '{jsonrpc:"2.0", id:1, method:"eth_sendRawTransaction", params:[$tx]}' |
    curl -fsS -H 'content-type: application/json' --data @- "$rpc_url")"

  if ! jq -e 'has("result")' >/dev/null 2>&1 <<<"$response"; then
    echo "failed to seed Hive txpool transaction: $response" >&2
    return 1
  fi
}

seed_rpc_compat_txpool() {
  local tx
  for tx in \
    "0xf86c808405763d658261a894aa000000000000000000000000000000000000000a8255448718e5bb3abd109fa0c8e3b4a0087357bd49d80a0ac24daf0c91191e71086c1e355fc62cfab2218873a074f4636f740fa4d1697b6e736e5982b700be2c8b63031a24fa531ae4814b3af8" \
    "0x02f892870c72dd9d5e883e018201f48405763f5882ea60802ab73d602d80600a3d3981f3363d3d373d3d3d363d734d11c446473105a02b5c1ab9ebe9b03f33902a295af43d82803e903d91602b57fd5bf3c001a0fe6d380224a516b802717755d2f640163e81bae64a4ab5adbcf741267f20ad66a015d9ceb9fecb47b342be00782b2485f42ab53715006d208897cc969d7c05ab67" \
    "0x01f8cc870c72dd9d5e883e028405763f5883015f90947dcd17433742f4c0ca53122ab541d0ba67fc27df8083010203f85bf859947dcd17433742f4c0ca53122ab541d0ba67fc27dff842a00000000000000000000000000000000000000000000000000000000000000000a0010000000000000000000000000000000000000000000000000000000000000080a0f9dc42e8bab0a70132fb8399cf03cf38e1c12cc47f736d19e6e7728356d97db3a053daf342acd24da15073f5dac02bec0501a0716165984aab2df9694882b91fac" \
    "0x02f8d0870c72dd9d5e883e038201f48405763f5883013880947dcd17433742f4c0ca53122ab541d0ba67fc27df808401020304f85bf859947dcd17433742f4c0ca53122ab541d0ba67fc27dff842a00000000000000000000000000000000000000000000000000000000000000000a0010000000000000000000000000000000000000000000000000000000000000080a0e56d869d8b32f767582fdcb03d1d9d3bcc47f3c7ae08984feafdcd57f2f205f5a074134e4bf0fb11ff606b47259aff0d01bf7cb9ec68cb179b62576b9dd6631cf0" \
    "0x02f871870c72dd9d5e883e808201f48405763f58825208947dcd17433742f4c0ca53122ab541d0ba67fc27df8203e880c080a02ff0582cbfd9034c5fa5081d8e87689fca126ef89e764ed75b9377a5abc17174a03f88569a957315fa1204dcc026fcc50cef44c6268642990b8f05b226d8f60a40"
  do
    send_raw_transaction "$tx"
  done
}

start_proxy() {
  local public_port="$1"
  local internal_port="$2"
  socat "TCP-LISTEN:${public_port},fork,reuseaddr,bind=0.0.0.0" "TCP:127.0.0.1:${internal_port}" &
  proxy_pids+=("$!")
}

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
  --argjson constantinople "${HIVE_FORK_CONSTANTINOPLE:-0}" \
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
  --arg internalRpcPort "$internal_rpc_port" \
  --arg internalEnginePort "$internal_engine_port" \
  '{
    rpc: { host: "127.0.0.1", port: ($internalRpcPort | tonumber) },
    engineRpc: { host: "127.0.0.1", port: ($internalEnginePort | tonumber) },
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
          constantinopleBlock: $constantinople,
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

wait_for_rpc

seed_txpool="${ZEVM_HIVE_SEED_TXPOOL:-}"
if [ -z "$seed_txpool" ]; then
  seed_txpool="$has_chain_rlp"
fi
if [ "$seed_txpool" = "true" ]; then
  seed_rpc_compat_txpool
fi

start_proxy 8545 "$internal_rpc_port"
start_proxy 8551 "$internal_engine_port"

wait "$zevm_pid"
