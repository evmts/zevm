#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for dependency in voltaire guillotine-mini; do
  revision=$(jq -er --arg name "$dependency" '.[$name].revision' native-dependencies.json)
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid $dependency revision" >&2; exit 1; }
  destination="../$dependency"
  if [ ! -e "$destination" ]; then
    git init "$destination"
    git -C "$destination" remote add origin "https://github.com/evmts/$dependency.git"
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach FETCH_HEAD
    if [ "$dependency" = voltaire ]; then
      # Build inputs only; the optional skills submodule requires SSH credentials.
      git -C "$destination" submodule update --init --recursive -- packages/voltaire-zig/lib/libwally-core vendor/execution-apis
    else
      git -C "$destination" submodule update --init --recursive
    fi
  fi
  test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
done
