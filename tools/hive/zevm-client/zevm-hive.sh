#!/usr/bin/env bash
set -euo pipefail

chain_id="${HIVE_CHAIN_ID:-31337}"
blob_base_fee="${ZEVM_HIVE_BLOB_BASE_FEE:-1}"

python3 /engine_stub.py &
engine_pid="$!"
zevm_pid=""

cleanup() {
  if [ -n "$zevm_pid" ]; then
    kill "$zevm_pid" >/dev/null 2>&1 || true
  fi
  kill "$engine_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 50); do
  if python3 - <<'PY'
import socket

with socket.create_connection(("127.0.0.1", 8551), timeout=0.1):
    pass
PY
  then
    break
  fi
  if ! kill -0 "$engine_pid" >/dev/null 2>&1; then
    echo "engine stub exited before accepting connections" >&2
    exit 1
  fi
  sleep 0.1
done

/usr/local/bin/zevm \
  --mode trusted \
  --host 0.0.0.0 \
  --port 8545 \
  --chain-id "$chain_id" \
  --blob-base-fee "$blob_base_fee" \
  --mining manual &
zevm_pid="$!"
wait "$zevm_pid"
