#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IN_DIR="${IN_DIR:-$ROOT_DIR/.ops/release-metadata}"
RELEASE_IDENTIFIER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-identifier)
      RELEASE_IDENTIFIER="$2"
      shift 2
      ;;
    --in-dir)
      IN_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$IN_DIR/release-tuple.json" ]]; then
  echo "missing required artifact: $IN_DIR/release-tuple.json" >&2
  exit 1
fi
if [[ ! -f "$IN_DIR/light-default-checkpoints.json" ]]; then
  echo "missing required artifact: $IN_DIR/light-default-checkpoints.json" >&2
  exit 1
fi

ARGS=(release-metadata -- --validate --in-dir "$IN_DIR")
if [[ -n "$RELEASE_IDENTIFIER" ]]; then
  ARGS+=(--release-identifier "$RELEASE_IDENTIFIER")
fi

(cd "$ROOT_DIR" && zig build "${ARGS[@]}")

echo "validated: $IN_DIR/release-tuple.json"
echo "validated: $IN_DIR/light-default-checkpoints.json"
