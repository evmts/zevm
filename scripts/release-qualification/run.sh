#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

zig build test
zig build qualification-check -- --require-covered

echo "release qualification: PASS"
echo "assertion map: docs/specs/qualification/assertion-map.json"
