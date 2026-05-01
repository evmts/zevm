#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VOLTAIRE_DIR="${ROOT_DIR}/../voltaire"
GUILLOTINE_DIR="${ROOT_DIR}/../guillotine-mini"

EXPECTED_ZIG_VERSION="${EXPECTED_ZIG_VERSION:-0.15.2}"
EXPECTED_ZEVM_REVISION="${EXPECTED_ZEVM_REVISION:-28675c7280d54fcd5aa842b4852d7ecb55cc08c3}"
EXPECTED_VOLTAIRE_REVISION="${EXPECTED_VOLTAIRE_REVISION:-58d3c7b65dc8f313add502cae53ef0863fd143fb}"
EXPECTED_GUILLOTINE_MINI_REVISION="${EXPECTED_GUILLOTINE_MINI_REVISION:-e2089da49faeafce03f03ba2a8276550855bd512}"

fail() {
  printf 'preflight: %s\n' "$1" >&2
  exit 1
}

require_clean_repo() {
  repo_dir="$1"
  repo_name="$2"

  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "$repo_name repo missing at $repo_dir"
  fi

  # Restrict cleanliness checks to the repository root path itself so nested
  # worktree/superproject metadata does not leak into this check.
  if [ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=all -- .)" ]; then
    fail "$repo_name repo is dirty at $repo_dir"
  fi
}

require_revision() {
  repo_dir="$1"
  repo_name="$2"
  expected_revision="$3"

  actual_revision="$(git -C "$repo_dir" rev-parse HEAD)"
  if [ "$actual_revision" != "$expected_revision" ]; then
    fail "$repo_name repo HEAD mismatch: expected $expected_revision got $actual_revision"
  fi
}

actual_zig_version="$(zig version)"
if [ "$actual_zig_version" != "$EXPECTED_ZIG_VERSION" ]; then
  fail "zig version mismatch: expected $EXPECTED_ZIG_VERSION got $actual_zig_version"
fi

require_clean_repo "$ROOT_DIR" "zevm"
require_clean_repo "$VOLTAIRE_DIR" "voltaire"
require_clean_repo "$GUILLOTINE_DIR" "guillotine-mini"

require_revision "$ROOT_DIR" "zevm" "$EXPECTED_ZEVM_REVISION"
require_revision "$VOLTAIRE_DIR" "voltaire" "$EXPECTED_VOLTAIRE_REVISION"
require_revision "$GUILLOTINE_DIR" "guillotine-mini" "$EXPECTED_GUILLOTINE_MINI_REVISION"

printf 'preflight: ok\n'
