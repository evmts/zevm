#!/usr/bin/env sh
set -eu

# Ensures Zig path dependencies resolve from either:
# 1) a normal checkout:   <workspace>/zevm
# 2) a git worktree path: <workspace>/zevm/.worktrees/<name>

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
repo_parent="$(CDPATH= cd -- "$repo_root/.." && pwd)"
repo_parent_name="$(basename "$repo_parent")"

deps="voltaire guillotine-mini"

require_repo() {
    dep_path="$2"
    if [ ! -d "$dep_path" ]; then
        printf 'error: required sibling checkout missing: %s\n' "$dep_path" >&2
        exit 1
    fi
}

if [ "$repo_parent_name" = ".worktrees" ]; then
    # Worktree checkout: build.zig.zon still resolves ../<dep>, which points at
    # <workspace>/zevm/.worktrees/<dep>. Create links there to canonical siblings
    # at <workspace>/<dep>.
    workspace_parent="$(CDPATH= cd -- "$repo_root/../../.." && pwd)"

    for dep in $deps; do
        canonical_dep="$workspace_parent/$dep"
        require_repo "$dep" "$canonical_dep"

        link_path="$repo_parent/$dep"
        link_target="../../$dep"

        if [ -L "$link_path" ]; then
            rm -f "$link_path"
        elif [ -e "$link_path" ]; then
            printf 'error: expected symlink path is occupied by a non-link: %s\n' "$link_path" >&2
            exit 1
        fi
        ln -s "$link_target" "$link_path"
    done

    printf 'linked dependencies for worktree checkout:\n'
    for dep in $deps; do
        printf '  %s -> %s\n' "$repo_parent/$dep" "$(readlink "$repo_parent/$dep")"
    done
else
    # Normal checkout: validate that required siblings already exist.
    for dep in $deps; do
        require_repo "$dep" "$repo_parent/$dep"
    done
    printf 'sibling layout is present for normal checkout in %s\n' "$repo_parent"
fi
