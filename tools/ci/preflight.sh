#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "preflight failed: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command '$1'"
}

require_cmd git
require_cmd zig

check_sibling_repo() {
  local path="$1"
  [ -d "$path/.git" ] || fail "missing sibling dependency at $path (expected git checkout)"
}

check_clean_tree() {
  local repo_path="$1"
  local repo_name="$2"
  git -C "$repo_path" update-index -q --refresh
  if ! git -C "$repo_path" diff --quiet || ! git -C "$repo_path" diff --cached --quiet; then
    fail "dirty worktree in $repo_name ($repo_path)"
  fi
}

check_sibling_repo "../voltaire"
check_sibling_repo "../guillotine-mini"

if [[ "$MODE" == "release" ]]; then
  TUPLE_PATH="${RELEASE_TUPLE_PATH:-release-tuple.json}"
  [[ -f "$TUPLE_PATH" ]] || fail "missing release tuple file: $TUPLE_PATH"

  check_clean_tree "." "zevm"
  check_clean_tree "../voltaire" "voltaire"
  check_clean_tree "../guillotine-mini" "guillotine-mini"

  require_cmd jq

  expected_zevm="$(jq -r '.zevmGitRevision // empty' "$TUPLE_PATH")"
  expected_voltaire="$(jq -r '.voltaireGitRevision // empty' "$TUPLE_PATH")"
  expected_gm="$(jq -r '.guillotineMiniGitRevision // empty' "$TUPLE_PATH")"
  expected_zig="$(jq -r '.zigVersion // empty' "$TUPLE_PATH")"

  [[ -n "$expected_zevm" && -n "$expected_voltaire" && -n "$expected_gm" && -n "$expected_zig" ]] || fail "release tuple missing required pin fields"

  actual_zevm="$(git rev-parse HEAD)"
  actual_voltaire="$(git -C ../voltaire rev-parse HEAD)"
  actual_gm="$(git -C ../guillotine-mini rev-parse HEAD)"
  actual_zig="$(zig version)"

  [[ "$actual_zevm" == "$expected_zevm" ]] || fail "pin mismatch: zevm HEAD ($actual_zevm) != tuple ($expected_zevm)"
  [[ "$actual_voltaire" == "$expected_voltaire" ]] || fail "pin mismatch: ../voltaire HEAD ($actual_voltaire) != tuple ($expected_voltaire)"
  [[ "$actual_gm" == "$expected_gm" ]] || fail "pin mismatch: ../guillotine-mini HEAD ($actual_gm) != tuple ($expected_gm)"
  [[ "$actual_zig" == "$expected_zig" ]] || fail "zig version mismatch: zig version ($actual_zig) != tuple ($expected_zig)"
fi

echo "preflight ok: mode=$MODE"
