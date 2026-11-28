#!/bin/sh
set -eu

tools=$(mktemp -d)
trap 'rm -rf "$tools"' EXIT
python3 -m pip install --disable-pip-version-check --no-cache-dir --no-deps --only-binary=:all: --target "$tools" ziglang==0.15.2
export PATH="$tools/ziglang:$PATH"
npm exec --yes --package=bun@1.4.2 --package=uphill@0.0.11 -- sh -ec '
  uphill check
  uphill --compact
  node tools/audit_report.mjs --input .uphill/report.json --out .uphill/audit-report.html --feed-out .uphill/factory-feed.json --md-out .uphill/audit-comment.md --trust untrusted
'
