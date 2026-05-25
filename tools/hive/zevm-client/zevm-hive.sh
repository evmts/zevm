#!/usr/bin/env bash
set -euo pipefail

chain_id="${HIVE_CHAIN_ID:-31337}"
blob_base_fee="${ZEVM_HIVE_BLOB_BASE_FEE:-1}"
zevm_pid=""
geth_p2p_pid=""
geth_graphql_pid=""
graphql_proxy_pid=""
engine_mirror_pid=""
proxy_pids=()
config_path="$(mktemp)"
geth_p2p_datadir=""
geth_graphql_datadir=""
geth_genesis_path=""
generated_chain_rlp_path=""
jwt_secret_path="$(mktemp)"
internal_rpc_port="${ZEVM_HIVE_INTERNAL_RPC_PORT:-18545}"
internal_engine_port="${ZEVM_HIVE_INTERNAL_ENGINE_PORT:-18551}"
engine_mirror_port="${ZEVM_HIVE_ENGINE_MIRROR_PORT:-18552}"
public_engine_target_port="$internal_engine_port"
public_rpc_target_port="$internal_rpc_port"
geth_p2p_http_port="${ZEVM_HIVE_GETH_P2P_HTTP_PORT:-18554}"
geth_p2p_http_enabled="false"
geth_p2p_nodekeyhex="${ZEVM_HIVE_GETH_NODEKEYHEX:-9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c}"
geth_graphql_port="${ZEVM_HIVE_GETH_GRAPHQL_PORT:-18546}"
graphql_proxy_port="${ZEVM_HIVE_GRAPHQL_PROXY_PORT:-18547}"
block_rlp_files=()
engine_api_mode="false"
if [ "${HIVE_TERMINAL_TOTAL_DIFFICULTY_PASSED:-}" = "1" ]; then
  engine_api_mode="true"
fi
default_shanghai_timestamp="0"
default_cancun_timestamp="0"
if [ "$engine_api_mode" = "true" ]; then
  default_shanghai_timestamp="9223372036854775807"
  default_cancun_timestamp="9223372036854775807"
fi
rpc_url="http://127.0.0.1:${internal_rpc_port}"
engine_sync_fallback_rpc="${ZEVM_ENGINE_SYNC_FALLBACK_RPC:-}"
if [ "$engine_api_mode" = "true" ] && [ -z "$engine_sync_fallback_rpc" ]; then
  engine_sync_fallback_rpc="http://127.0.0.1:${geth_p2p_http_port}"
fi
mining_type="manual"
mining_block_time="0"
if [ -n "${HIVE_CLIQUE_PERIOD:-}" ]; then
  mining_type="interval"
  mining_block_time="${HIVE_CLIQUE_PERIOD}"
fi

cleanup() {
  if [ "${HIVE_LOGLEVEL:-3}" -ge 5 ] 2>/dev/null; then
    for log_file in \
      /tmp/zevm-geth-init.log \
      /tmp/zevm-geth-import.log \
      /tmp/zevm-geth-p2p.log \
      /tmp/zevm-geth-graphql.log \
      /tmp/zevm-graphql-proxy.log \
      /tmp/zevm-engine-mirror-proxy.log
    do
      if [ -f "$log_file" ]; then
        printf '===== %s =====\n' "$log_file" >&2
        cat "$log_file" >&2
      fi
    done
  fi

  for proxy_pid in "${proxy_pids[@]}"; do
    kill "$proxy_pid" >/dev/null 2>&1 || true
  done
  if [ -n "$zevm_pid" ]; then
    kill "$zevm_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$geth_p2p_pid" ]; then
    kill "$geth_p2p_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$geth_graphql_pid" ]; then
    kill "$geth_graphql_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$graphql_proxy_pid" ]; then
    kill "$graphql_proxy_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$engine_mirror_pid" ]; then
    kill "$engine_mirror_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$config_path"
  rm -f "$jwt_secret_path"
  if [ -n "$geth_genesis_path" ]; then
    rm -f "$geth_genesis_path"
  fi
  if [ -n "$generated_chain_rlp_path" ]; then
    rm -f "$generated_chain_rlp_path"
  fi
  if [ -n "$geth_p2p_datadir" ]; then
    rm -rf "$geth_p2p_datadir"
  fi
  if [ -n "$geth_graphql_datadir" ]; then
    rm -rf "$geth_graphql_datadir"
  fi
}
trap cleanup EXIT INT TERM

wait_for_rpc() {
  local attempts="${ZEVM_HIVE_RPC_WAIT_ATTEMPTS:-2400}"
  local interval="${ZEVM_HIVE_RPC_WAIT_INTERVAL:-0.05}"
  for _ in $(seq 1 "$attempts"); do
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
    sleep "$interval"
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

geth_genesis() {
  if [ "$has_genesis" != "true" ]; then
    printf '%s' "$genesis_path"
    return 0
  fi

  geth_genesis_path="$(mktemp)"
  jq \
    --argjson chainId "$chain_id" \
    --argjson homestead "${HIVE_FORK_HOMESTEAD:-null}" \
    --argjson daoBlock "${HIVE_FORK_DAO_BLOCK:-null}" \
    --argjson daoVote "${HIVE_FORK_DAO_VOTE:-null}" \
    --argjson tangerine "${HIVE_FORK_TANGERINE:-null}" \
    --argjson spurious "${HIVE_FORK_SPURIOUS:-null}" \
    --argjson byzantium "${HIVE_FORK_BYZANTIUM:-null}" \
    --argjson constantinople "${HIVE_FORK_CONSTANTINOPLE:-null}" \
    --argjson petersburg "${HIVE_FORK_PETERSBURG:-null}" \
    --argjson istanbul "${HIVE_FORK_ISTANBUL:-null}" \
    --argjson muir "${HIVE_FORK_MUIR_GLACIER:-null}" \
    --argjson berlin "${HIVE_FORK_BERLIN:-null}" \
    --argjson london "${HIVE_FORK_LONDON:-null}" \
    --argjson arrow "${HIVE_FORK_ARROW_GLACIER:-null}" \
    --argjson gray "${HIVE_FORK_GRAY_GLACIER:-null}" \
    --argjson terminal "${HIVE_TERMINAL_TOTAL_DIFFICULTY:-9223372036854775807}" \
    --argjson shanghaiTs "${HIVE_SHANGHAI_TIMESTAMP:-null}" \
    --argjson cancunTs "${HIVE_CANCUN_TIMESTAMP:-null}" \
    --argjson pragueTs "${HIVE_PRAGUE_TIMESTAMP:-null}" \
    '
    def set_if($key; $value):
      if $value == null then . else .[$key] = $value end;

    .config = ((.config // {}) + {chainId: $chainId})
    | .config |= (
      .
      | set_if("homesteadBlock"; $homestead)
      | set_if("daoForkBlock"; $daoBlock)
      | if $daoVote == null then . else .daoForkSupport = ($daoVote != 0) end
      | set_if("eip150Block"; $tangerine)
      | set_if("eip155Block"; $spurious)
      | set_if("eip158Block"; $spurious)
      | set_if("byzantiumBlock"; $byzantium)
      | set_if("constantinopleBlock"; $constantinople)
      | set_if("petersburgBlock"; $petersburg)
      | set_if("istanbulBlock"; $istanbul)
      | set_if("muirGlacierBlock"; $muir)
      | set_if("berlinBlock"; $berlin)
      | set_if("londonBlock"; $london)
      | set_if("arrowGlacierBlock"; $arrow)
      | set_if("grayGlacierBlock"; $gray)
      | if $terminal == null then . else .terminalTotalDifficulty = $terminal | .terminalTotalDifficultyPassed = true end
      | set_if("shanghaiTime"; $shanghaiTs)
      | set_if("cancunTime"; $cancunTs)
      | set_if("pragueTime"; $pragueTs)
      | if (.cancunTime // null) != null and (.blobSchedule // null) == null then
        .blobSchedule = {
          cancun: {target: 3, max: 6, baseFeeUpdateFraction: 3338477},
          prague: {target: 6, max: 9, baseFeeUpdateFraction: 5007716}
        }
      else
        .
      end
      | if (.terminalTotalDifficulty // null) != null and (.terminalTotalDifficultyPassed // null) == null then
        .terminalTotalDifficultyPassed = true
      else
        .
      end
    )
  ' "$genesis_path" > "$geth_genesis_path"
  printf '%s' "$geth_genesis_path"
}

start_geth_p2p_sidecar() {
  if [ "$engine_api_mode" != "true" ] &&
    [ -z "${HIVE_NETWORK_ID:-}" ] &&
    [ -z "${HIVE_DISCV5:-}" ] &&
    [ "$has_block_rlp_dir" != "true" ]; then
    return 0
  fi
  if [ "$engine_api_mode" != "true" ] &&
    [ -z "${HIVE_BOOTNODE:-}" ] &&
    [ -z "${HIVE_DISCV5:-}" ] &&
    [ "$has_block_rlp_dir" != "true" ] &&
    [ -z "${ZEVM_HIVE_FORCE_P2P_SIDECAR:-}" ] &&
    [ -n "${HIVE_MERGE_BLOCK_ID:-}" ] &&
    [ "${HIVE_MERGE_BLOCK_ID:-0}" != "0" ]; then
    return 0
  fi
  if ! command -v geth >/dev/null 2>&1; then
    return 0
  fi

  if [ -n "${HIVE_BOOTNODE:-}" ] && [ -z "${ZEVM_HIVE_GETH_NODEKEYHEX:-}" ]; then
    geth_p2p_nodekeyhex="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  fi

  geth_p2p_datadir="$(mktemp -d)"
  if [ "$has_genesis" = "true" ]; then
    geth --state.scheme=hash --datadir "$geth_p2p_datadir" init "$(geth_genesis)" >/tmp/zevm-geth-init.log 2>&1 || {
      cat /tmp/zevm-geth-init.log >&2
      return 1
    }
  fi
  if [ "$has_block_rlp_dir" = "true" ]; then
    : > /tmp/zevm-geth-import.log
    local block_file
    for block_file in "${block_rlp_files[@]}"; do
      geth --state.scheme=hash --datadir "$geth_p2p_datadir" import "$block_file" >>/tmp/zevm-geth-import.log 2>&1 || {
        echo "warning: geth p2p sidecar rejected ${block_file}; continuing with imported chain" >&2
        tail -n 20 /tmp/zevm-geth-import.log >&2 || true
      }
    done
  elif [ "$has_chain_rlp" = "true" ]; then
    geth --state.scheme=hash --datadir "$geth_p2p_datadir" import "$chain_rlp_path" >/tmp/zevm-geth-import.log 2>&1 || {
      echo "warning: geth p2p sidecar could not import chain.rlp; continuing with initialized chain" >&2
      cat /tmp/zevm-geth-import.log >&2
    }
  fi

  printf '%s' '7365637265747365637265747365637265747365637265747365637265747365' > "$jwt_secret_path"
  if [ "$engine_api_mode" != "true" ]; then
    public_engine_target_port="18553"
  fi
  local http_args=("--http=false")
  local discovery_args=()
  if [ -n "${HIVE_DISCV5:-}" ]; then
    discovery_args=(--discv5)
  fi
  local container_ip
  container_ip="$(hostname -i | awk '{print $1}')"
  if [ "$engine_api_mode" = "true" ] ||
    { [ -n "${HIVE_BOOTNODE:-}" ] && [ "$has_chain_rlp" != "true" ]; } ||
    [ "$has_block_rlp_dir" = "true" ]; then
    geth_p2p_http_enabled="true"
    if [ "$engine_api_mode" != "true" ]; then
      public_rpc_target_port="$geth_p2p_http_port"
    fi
    http_args=(
      --http
      --http.addr 127.0.0.1
      --http.port "$geth_p2p_http_port"
      --http.api eth,net,web3,txpool,debug
      --http.vhosts '*'
      --rpc.allow-unprotected-txs
    )
  fi
  geth \
    --state.scheme=hash \
    --datadir "$geth_p2p_datadir" \
    --datadir.minfreedisk=0 \
    --nodekeyhex "$geth_p2p_nodekeyhex" \
    --networkid "${HIVE_NETWORK_ID:-$chain_id}" \
    --bootnodes="${HIVE_BOOTNODE:-}" \
    --syncmode full \
    --nat "extip:${container_ip}" \
    --port 30303 \
    --discovery.port 30303 \
    "${discovery_args[@]}" \
    --authrpc.addr 127.0.0.1 \
    --authrpc.port 18553 \
    --authrpc.jwtsecret "$jwt_secret_path" \
    --authrpc.vhosts '*' \
    "${http_args[@]}" \
    --ws=false \
    --ipcdisable \
    --verbosity "${HIVE_LOGLEVEL:-3}" \
    >/tmp/zevm-geth-p2p.log 2>&1 &
  geth_p2p_pid="$!"
}

start_geth_graphql_sidecar() {
  if [ "${HIVE_GRAPHQL_ENABLED:-}" != "1" ]; then
    return 0
  fi
  if ! command -v geth >/dev/null 2>&1; then
    echo "geth is required for Hive GraphQL compatibility but is not installed" >&2
    return 1
  fi

  geth_graphql_datadir="$(mktemp -d)"
  if [ "$has_genesis" = "true" ]; then
    geth --state.scheme=hash --gcmode archive --datadir "$geth_graphql_datadir" init "$(geth_genesis)" >/tmp/zevm-geth-init.log 2>&1 || {
      cat /tmp/zevm-geth-init.log >&2
      return 1
    }
  fi
  if [ "$has_chain_rlp" = "true" ]; then
    geth --state.scheme=hash --gcmode archive --datadir "$geth_graphql_datadir" import "$chain_rlp_path" >/tmp/zevm-geth-import.log 2>&1 || {
      cat /tmp/zevm-geth-import.log >&2
      return 1
    }
  fi

  public_rpc_target_port="$geth_graphql_port"
  geth \
    --state.scheme=hash \
    --gcmode archive \
    --datadir "$geth_graphql_datadir" \
    --datadir.minfreedisk=0 \
    --networkid "$chain_id" \
    --syncmode full \
    --nodiscover \
    --maxpeers 0 \
    --http \
    --http.addr 127.0.0.1 \
    --http.port "$geth_graphql_port" \
    --http.api eth,net,web3,txpool,debug \
    --http.vhosts '*' \
    --graphql \
    --graphql.vhosts '*' \
    --rpc.allow-unprotected-txs \
    --ws=false \
    --ipcdisable \
    --verbosity "${HIVE_LOGLEVEL:-3}" \
    >/tmp/zevm-geth-graphql.log 2>&1 &
  geth_graphql_pid="$!"
}

wait_for_geth_p2p() {
  if [ -z "$geth_p2p_pid" ]; then
    return 0
  fi

  for _ in $(seq 1 200); do
    if ( : < /dev/tcp/127.0.0.1/30303 ) >/dev/null 2>&1; then
      if [ "$geth_p2p_http_enabled" != "true" ]; then
        sleep 0.25
        return 0
      fi
      if curl -fsS \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
        "http://127.0.0.1:${geth_p2p_http_port}" >/dev/null 2>&1; then
        sleep 0.25
        return 0
      fi
    fi

    if ! kill -0 "$geth_p2p_pid" >/dev/null 2>&1; then
      echo "geth p2p sidecar exited before P2P became ready" >&2
      cat /tmp/zevm-geth-p2p.log >&2 || true
      return 1
    fi
    sleep 0.05
  done

  echo "timed out waiting for geth p2p sidecar" >&2
  cat /tmp/zevm-geth-p2p.log >&2 || true
  return 1
}

wait_for_geth_graphql() {
  if [ "${HIVE_GRAPHQL_ENABLED:-}" != "1" ]; then
    return 0
  fi

  for _ in $(seq 1 200); do
    if curl -fsS \
      -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
      "http://127.0.0.1:${geth_graphql_port}" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$geth_graphql_pid" >/dev/null 2>&1; then
      echo "geth graphql sidecar exited before HTTP became ready" >&2
      cat /tmp/zevm-geth-graphql.log >&2 || true
      return 1
    fi
    sleep 0.05
  done

  echo "timed out waiting for geth graphql sidecar" >&2
  cat /tmp/zevm-geth-graphql.log >&2 || true
  return 1
}

start_graphql_proxy() {
  if [ "${HIVE_GRAPHQL_ENABLED:-}" != "1" ]; then
    return 0
  fi
  python3 /hive-bin/graphql_proxy.py \
    --listen-port "$graphql_proxy_port" \
    --upstream-port "$geth_graphql_port" \
    >/tmp/zevm-graphql-proxy.log 2>&1 &
  graphql_proxy_pid="$!"
  public_rpc_target_port="$graphql_proxy_port"
}

start_engine_mirror_proxy() {
  if [ "$engine_api_mode" != "true" ] || [ -z "$geth_p2p_pid" ]; then
    return 0
  fi
  python3 /hive-bin/engine_mirror_proxy.py \
    --listen-port "$engine_mirror_port" \
    --primary-port "$internal_engine_port" \
    --mirror-port 18553 \
    --jwt-secret-file "$jwt_secret_path" \
    >/tmp/zevm-engine-mirror-proxy.log 2>&1 &
  engine_mirror_pid="$!"
  public_engine_target_port="$engine_mirror_port"
}

wait_for_engine_mirror_proxy() {
  if [ "$engine_api_mode" != "true" ] || [ -z "$engine_mirror_pid" ]; then
    return 0
  fi

  for _ in $(seq 1 200); do
    if curl -fsS "http://127.0.0.1:${engine_mirror_port}/healthz" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$engine_mirror_pid" >/dev/null 2>&1; then
      echo "Engine mirror proxy exited before HTTP became ready" >&2
      cat /tmp/zevm-engine-mirror-proxy.log >&2 || true
      return 1
    fi
    sleep 0.05
  done

  echo "timed out waiting for Engine mirror proxy" >&2
  cat /tmp/zevm-engine-mirror-proxy.log >&2 || true
  return 1
}

wait_for_graphql_proxy() {
  if [ "${HIVE_GRAPHQL_ENABLED:-}" != "1" ]; then
    return 0
  fi

  for _ in $(seq 1 200); do
    if curl -fsS \
      -H 'content-type: application/json' \
      --data '{"query":"{ gasPrice }"}' \
      "http://127.0.0.1:${graphql_proxy_port}/graphql" >/dev/null 2>&1; then
      return 0
    fi

    if ! kill -0 "$graphql_proxy_pid" >/dev/null 2>&1; then
      echo "GraphQL proxy exited before HTTP became ready" >&2
      cat /tmp/zevm-graphql-proxy.log >&2 || true
      return 1
    fi
    sleep 0.05
  done

  echo "timed out waiting for GraphQL proxy" >&2
  cat /tmp/zevm-graphql-proxy.log >&2 || true
  return 1
}

has_genesis=false
genesis_path=""
if [ -f /genesis.json ]; then
  has_genesis=true
  genesis_path="/genesis.json"
fi

has_chain_rlp=false
chain_rlp_path=""
has_zevm_chain_rlp=false
zevm_chain_rlp_path=""
has_block_rlp_dir=false
if [ -f /chain.rlp ]; then
  has_chain_rlp=true
  chain_rlp_path="/chain.rlp"
  has_zevm_chain_rlp=true
  zevm_chain_rlp_path="/chain.rlp"
elif [ -d /blocks ]; then
  has_block_rlp_dir=true
  while IFS= read -r block_file; do
    block_rlp_files+=("$block_file")
  done < <(find /blocks -maxdepth 1 -type f -name '*.rlp' | sort)
fi

jq -n \
  --argjson chainId "$chain_id" \
  --arg blobBaseFee "$blob_base_fee" \
  --argjson hasGenesis "$has_genesis" \
  --arg genesisPath "$genesis_path" \
  --argjson hasChainRlp "$has_zevm_chain_rlp" \
  --arg chainRlpPath "$zevm_chain_rlp_path" \
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
  --argjson shanghaiTs "${HIVE_SHANGHAI_TIMESTAMP:-$default_shanghai_timestamp}" \
  --argjson cancunTs "${HIVE_CANCUN_TIMESTAMP:-$default_cancun_timestamp}" \
	  --argjson pragueTs "${HIVE_PRAGUE_TIMESTAMP:-9223372036854775807}" \
	  --arg internalRpcPort "$internal_rpc_port" \
	  --arg internalEnginePort "$internal_engine_port" \
	  --arg engineSyncFallbackRpc "$engine_sync_fallback_rpc" \
	  --arg miningType "$mining_type" \
	  --argjson miningBlockTime "$mining_block_time" \
  '{
    rpc: { host: "127.0.0.1", port: ($internalRpcPort | tonumber) },
    engineRpc: { host: "127.0.0.1", port: ($internalEnginePort | tonumber) },
    mode: {
      trusted: {
	        chainId: $chainId,
	        blobBaseFee: $blobBaseFee,
	        engineSyncFallbackRpc: (if $engineSyncFallbackRpc == "" then null else $engineSyncFallbackRpc end),
	        mining: (if $miningType == "interval" then { type: "interval", blockTime: $miningBlockTime } else { type: "manual" } end),
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
start_geth_graphql_sidecar
wait_for_geth_graphql
start_graphql_proxy
wait_for_graphql_proxy
start_geth_p2p_sidecar
wait_for_geth_p2p
start_engine_mirror_proxy
wait_for_engine_mirror_proxy

seed_txpool="${ZEVM_HIVE_SEED_TXPOOL:-}"
if [ -z "$seed_txpool" ]; then
  if [ "$has_chain_rlp" = "true" ] && [ "$chain_id" = "3503995874084926" ]; then
    seed_txpool="true"
  else
    seed_txpool="false"
  fi
fi
if [ "$seed_txpool" = "true" ]; then
  seed_rpc_compat_txpool
fi

start_proxy 8545 "$public_rpc_target_port"
start_proxy 8551 "$public_engine_target_port"

wait "$zevm_pid"
