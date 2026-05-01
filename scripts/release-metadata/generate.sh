#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/.ops/release-metadata}"
RELEASE_IDENTIFIER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-identifier)
      RELEASE_IDENTIFIER="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$OUT_DIR"

ARGS=(release-metadata -- --out-dir "$OUT_DIR")
if [[ -n "$RELEASE_IDENTIFIER" ]]; then
  ARGS+=(--release-identifier "$RELEASE_IDENTIFIER")
fi

(cd "$ROOT_DIR" && zig build "${ARGS[@]}")

echo "generated: $OUT_DIR/release-tuple.json"
echo "generated: $OUT_DIR/light-default-checkpoints.json"
