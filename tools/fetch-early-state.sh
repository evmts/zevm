#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The release was filled by execution-specs. Keep its post-state oracles intact.
dest=.cache/early-state-v5.4.0
mkdir -p "$dest"
stage=$(mktemp -d "$dest/download.XXXXXX")
trap 'rm -rf "$stage"' EXIT
archive=$stage/fixtures_stable.tar.gz
curl -fLsS --retry 3 https://github.com/ethereum/execution-spec-tests/releases/download/v5.4.0/fixtures_stable.tar.gz -o "$archive"
echo "92cf1b47ad12fb27163261fc3c1cea5df72439cab507983d06b56c94f8741909  $archive" | shasum -a 256 -c -
manifest=tools/early_state_files.txt
grep '^fixtures/' "$manifest" | tar -xzf "$archive" -C "$stage" -T -

# The legacytests revision pinned by lib/ethereum-tests supplies the original
# Constantinople rules, which EEST v5.4.0 omits.
legacy=https://raw.githubusercontent.com/ethereum/legacytests/1f581b8ccdc4c63acf5f2c5c1b155c690c32a8eb
while IFS= read -r path; do
    case "$path" in
        fixtures/*) ;;
        Constantinople/*)
            mkdir -p "$stage/${path%/*}"
            curl -fLsS --retry 3 "$legacy/$path" -o "$stage/$path"
            ;;
        *) echo "Unknown fixture source for $path" >&2; exit 1 ;;
    esac
done < "$manifest"

while IFS= read -r path; do
    mkdir -p "$dest/${path%/*}"
    mv -f "$stage/$path" "$dest/$path"
done < "$manifest"
