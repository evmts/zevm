#!/bin/sh
# Fast local/sandbox tier-1 check for evmts/zevm (completes in a few seconds).
set -eu

node tools/docs_mirror.mjs
node tools/generate_llms_txt.mjs --check
node tools/wiki_sync.mjs --check
node npm/zevm/scripts/verify-release.cjs
node --test tools/audit_report.test.mjs
for f in npm/zevm/src/*.js npm/zevm/scripts/*.cjs tools/*.mjs tools/*.js; do
  [ -e "$f" ] || continue
  node --check "$f"
done
echo "fast-check: all checks passed"
