#!/usr/bin/env bash
set -euo pipefail

# Bare-metal Ubuntu coverage-guided Zig fuzzing runner for zevm.
#
# Runs all `test "fuzz: ..."` targets across src/fuzz/*.zig and
# tools/c_abi_fuzz_test.zig using Zig 0.15.2's native coverage-guided fuzzer
# (`zig build fuzz --fuzz`), either locally on Linux or remotely on a bare-metal
# Latitude Ubuntu host (default: nyc-02 in RAM-backed /dev/shm/zevm-fuzz).

SECONDS_PER_TARGET="${FUZZ_SECONDS:-30}"
JOBS="${FUZZ_JOBS:-8}"
FILTER="${FUZZ_FILTER:-}"
OPTIMIZE="${FUZZ_OPTIMIZE:-Debug}"
REMOTE_HOST="${FUZZ_HOST:-lane@160.202.128.229}"
REMOTE_DIR="${FUZZ_REMOTE_DIR:-/dev/shm/zevm-fuzz}"
SSH_KEY="${FUZZ_SSH_KEY:-$HOME/.ssh/smithers-linux}"
LOCAL_MODE=0
LIST_ONLY=0
RUN_PROPERTIES=1

usage() {
    cat <<'EOF'
Usage: tools/fuzz_ubuntu.sh [options]

Options:
  --seconds N        Coverage-guided fuzzing seconds per target (default: 30)
  --jobs N           Parallel fuzz workers (default: 8)
  --optimize MODE    Zig optimize mode: Debug or ReleaseSafe (default: Debug)
  --filter SUBSTR    Only run fuzz targets whose name contains SUBSTR
  --host USER@HOST   Remote Ubuntu host (default: lane@160.202.128.229)
  --remote-dir PATH  Remote working directory (default: /dev/shm/zevm-fuzz)
  --local            Run directly on this Linux host instead of syncing over SSH
  --skip-properties  Skip the deterministic property+corpus pass before --fuzz
  --list             List all discovered native std.testing.fuzz targets and exit
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) SECONDS_PER_TARGET="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --optimize) OPTIMIZE="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --host) REMOTE_HOST="$2"; shift 2 ;;
        --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
        --local) LOCAL_MODE=1; shift ;;
        --skip-properties) RUN_PROPERTIES=0; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$REPO_ROOT/.." && pwd)"

discover_targets() {
    local root="$1"
    # Emit lines formatted as: <step>\t<test name>
    (
        cd "$root"
        while IFS= read -r line; do
            local name="${line#*test \"}"
            name="${name%\"*}"
            printf 'fuzz\t%s\n' "$name"
        done < <(grep -hE '^test "fuzz: ' src/fuzz/*.zig 2>/dev/null | sort)
        while IFS= read -r line; do
            local name="${line#*test \"}"
            name="${name%\"*}"
            printf 'fuzz-c-abi\t%s\n' "$name"
        done < <(grep -hE '^test "fuzz: ' tools/c_abi_fuzz_test.zig 2>/dev/null | sort)
    )
}

if [[ "$LIST_ONLY" -eq 1 ]]; then
    discover_targets "$REPO_ROOT" | while IFS=$'\t' read -r step name; do
        if [[ -z "$FILTER" || "$name" == *"$FILTER"* ]]; then
            printf '[%s] %s\n' "$step" "$name"
        fi
    done
    exit 0
fi

if [[ "$(uname -s)" == "Linux" ]]; then
    LOCAL_MODE=1
fi

run_local_linux() {
    local zevm_dir="$1"
    cd "$zevm_dir"

    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
    local zig_bin="${ZIG_BIN:-}"
    if [[ -z "$zig_bin" ]]; then
        if [[ -x "/home/lane/gm-maint/tools/zig-0.15.2/zig" ]]; then
            zig_bin="/home/lane/gm-maint/tools/zig-0.15.2/zig"
        elif command -v zig >/dev/null 2>&1; then
            zig_bin="$(command -v zig)"
        else
            echo "ERROR: zig 0.15.2 not found on Linux host" >&2
            exit 1
        fi
    fi

    local global_cache_args=()
    if [[ -d "/home/lane/gm-maint/zig-global" ]]; then
        global_cache_args=(--global-cache-dir "/home/lane/gm-maint/zig-global")
    fi

    echo "=== Host: $(hostname) ($(uname -srm)) | Zig: $($zig_bin version) | Jobs: $JOBS | Seconds/target: $SECONDS_PER_TARGET ==="

    # Pre-build Voltaire Rust crypto once so parallel workers never contend on cargo locks.
    if [[ -d "../voltaire" ]]; then
        echo ">>> Building voltaire Rust crypto..."
        (cd ../voltaire && cargo build --release --quiet)
    fi

    if [[ "$RUN_PROPERTIES" -eq 1 ]]; then
        echo ">>> Running full deterministic property & corpus fuzz suite (zig build fuzz -Doptimize=$OPTIMIZE)..."
        "$zig_bin" build fuzz "-Doptimize=$OPTIMIZE" "${global_cache_args[@]}"
    fi

    local log_dir="$zevm_dir/.fuzz-logs"
    rm -rf "$log_dir"
    mkdir -p "$log_dir"

    local targets=()
    while IFS= read -r entry; do
        local name="${entry#*$'\t'}"
        if [[ -z "$FILTER" || "$name" == *"$FILTER"* ]]; then
            targets+=("$entry")
        fi
    done < <(discover_targets "$zevm_dir")

    local total="${#targets[@]}"
    if [[ "$total" -eq 0 ]]; then
        echo "ERROR: No fuzz targets matched filter '$FILTER'" >&2
        exit 1
    fi
    echo ">>> Launching $total coverage-guided native Zig fuzz targets ($JOBS concurrent, ${SECONDS_PER_TARGET}s each)..."

    # Pre-compile the two fuzz test binaries once (with -ffuzz instrumentation) so
    # parallel runs share the cache without racing on compilation.
    "$zig_bin" build fuzz "-Doptimize=$OPTIMIZE" -Dskip-rust-build=true -Dfuzz-filter="__warmup_none__" "${global_cache_args[@]}" --fuzz >/dev/null 2>&1 || true
    "$zig_bin" build fuzz-c-abi "-Doptimize=$OPTIMIZE" -Dskip-rust-build=true -Dfuzz-filter="__warmup_none__" "${global_cache_args[@]}" --fuzz >/dev/null 2>&1 || true

    local pids=()
    local names=()
    local logfiles=()
    local active=0
    local idx=0
    local failures=0

    run_one_target() {
        local step="$1"
        local name="$2"
        local log="$3"
        local deadline=$(( $(date +%s) + SECONDS_PER_TARGET ))
        local attempt=0
        : >"$log"

        while true; do
            local now
            now="$(date +%s)"
            local remaining=$(( deadline - now ))
            if [[ "$remaining" -le 0 ]]; then
                return 0
            fi

            local attempt_log="${log}.attempt${attempt}"
            local rc=0
            # SIGTERM, not SIGINT: this runs in a background job, where bash
            # ignores SIGINT. uutils timeout (Ubuntu 26.04 runners) passes that
            # disposition to zig, so SIGINT never stopped `zig build --fuzz`
            # and the CI job hung until its timeout. --kill-after is the backstop.
            timeout --signal=TERM --kill-after=30s "${remaining}s" \
                "$zig_bin" build "$step" \
                "-Doptimize=$OPTIMIZE" \
                -Dskip-rust-build=true \
                -Dfuzz-filter="$name" \
                "${global_cache_args[@]}" \
                --fuzz >"$attempt_log" 2>&1 || rc=$?

            cat "$attempt_log" >>"$log"
            rm -f "$attempt_log"

            # Check for any real crash, panic, memory leak, or assertion failure.
            if grep -qE '(^|\s)(failure|panic:|Segmentation fault|failed with |leaked:|error: the following command|error: while executing test)' "$log" 2>/dev/null; then
                # Upstream Zig 0.15.2 lib/fuzzer.zig:607 crashes when `.remove_byte`
                # shrinks a corpus entry to 0 bytes and mutates it again. Only ignore
                # that exact compiler-runtime crash (never any failure inside zevm),
                # clear the poisoned corpus dir, and keep fuzzing until the deadline.
                if grep -A1 'Segmentation fault at address 0x0' "$log" 2>/dev/null | grep -q 'lib/fuzzer\.zig:607' && \
                   ! grep -qE '(failed with |leaked:|panic:)' "$log" 2>/dev/null; then
                    local poisoned
                    poisoned="$(find "$zevm_dir/.zig-cache/f" -maxdepth 1 -type d -name "*${name}" 2>/dev/null | head -n 1 || true)"
                    if [[ -n "$poisoned" && -d "$poisoned" ]]; then
                        rm -rf "$poisoned"
                    fi
                    : >"$log"
                    attempt=$((attempt + 1))
                    if [[ "$attempt" -ge 8 ]]; then
                        return 0
                    fi
                    continue
                fi
                return 1
            fi

            if [[ "$rc" -eq 0 || "$rc" -eq 124 || "$rc" -eq 130 ]]; then
                return 0
            fi
            return "$rc"
        done
    }

    reap_one() {
        local pid="$1"
        local label="$2"
        local log="$3"
        local target_name="$4"
        local rc=0
        wait "$pid" || rc=$?

        local corpus_count=0
        local corpus_dir
        corpus_dir="$(find "$zevm_dir/.zig-cache/f" -maxdepth 1 -type d -name "*${target_name}" 2>/dev/null | head -n 1 || true)"
        if [[ -n "$corpus_dir" && -d "$corpus_dir" ]]; then
            corpus_count="$(find "$corpus_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
        fi

        if [[ "$rc" -eq 0 ]]; then
            printf '  [PASS] (%ss, corpus=%s) %s\n' "$SECONDS_PER_TARGET" "$corpus_count" "$label"
        else
            printf '  [FAIL rc=%d corpus=%s] %s\n' "$rc" "$corpus_count" "$label"
            echo "    --- log tail ($log) ---"
            tail -n 40 "$log" | sed 's/^/    /'
            failures=$((failures + 1))
        fi
    }

    local raw_names=()
    for entry in "${targets[@]}"; do
        local step="${entry%%$'\t'*}"
        local name="${entry#*$'\t'}"
        local slug
        slug="$(printf '%02d_%s' "$idx" "$(printf '%s' "$name" | tr -cs 'A-Za-z0-9' '_' | cut -c1-48)")"
        local log="$log_dir/$slug.log"

        run_one_target "$step" "$name" "$log" &
        pids+=("$!")
        names+=("[$step] $name")
        raw_names+=("$name")
        logfiles+=("$log")
        idx=$((idx + 1))
        active=$((active + 1))

        if [[ "$active" -ge "$JOBS" ]]; then
            reap_one "${pids[0]}" "${names[0]}" "${logfiles[0]}" "${raw_names[0]}"
            pids=("${pids[@]:1}")
            names=("${names[@]:1}")
            raw_names=("${raw_names[@]:1}")
            logfiles=("${logfiles[@]:1}")
            active=$((active - 1))
        fi
    done

    for i in "${!pids[@]}"; do
        reap_one "${pids[$i]}" "${names[$i]}" "${logfiles[$i]}" "${raw_names[$i]}"
    done

    echo "=== Fuzzing Summary: $((total - failures))/$total targets passed, $failures failed ==="
    if [[ "$failures" -ne 0 ]]; then
        exit 1
    fi
}

if [[ "$LOCAL_MODE" -eq 1 ]]; then
    run_local_linux "$REPO_ROOT"
    exit 0
fi

# Remote bare-metal Ubuntu mode (macOS -> nyc-02)
SSH_OPTS=(-o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
if [[ -f "$SSH_KEY" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi
RSYNC_RSH="ssh ${SSH_OPTS[*]}"

echo ">>> Syncing zevm, voltaire, and guillotine-mini to $REMOTE_HOST:$REMOTE_DIR..."
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/zevm' '$REMOTE_DIR/voltaire' '$REMOTE_DIR/guillotine-mini'"

RSYNC_EXCLUDES=(
    --exclude='.git'
    --exclude='.jj'
    --exclude='.zig-cache'
    --exclude='zig-cache'
    --exclude='zig-out'
    --exclude='node_modules'
    --exclude='target'
    --exclude='smithers.db*'
    --exclude='.fuzz-logs'
    --exclude='docs/dist'
    --exclude='apps'
    --exclude='examples'
    --exclude='execution-specs'
    --exclude='cloudflare'
)

ZEVM_RSYNC_EXCLUDES=(
    "${RSYNC_EXCLUDES[@]}"
    --exclude='/lib'
    --exclude='/npm'
    --exclude='/docs'
    --exclude='/workflow'
    --exclude='*.log'
)

rsync -az --delete -e "$RSYNC_RSH" "${ZEVM_RSYNC_EXCLUDES[@]}" "$REPO_ROOT/" "$REMOTE_HOST:$REMOTE_DIR/zevm/"
if [[ -f "$REPO_ROOT/lib/execution-apis/tests/chain.rlp" ]]; then
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/zevm/lib/execution-apis/tests'"
    rsync -az -e "$RSYNC_RSH" \
        "$REPO_ROOT/lib/execution-apis/tests/chain.rlp" \
        "$REPO_ROOT/lib/execution-apis/tests/genesis.json" \
        "$REMOTE_HOST:$REMOTE_DIR/zevm/lib/execution-apis/tests/"
fi
if [[ -d "$PARENT_DIR/voltaire" ]]; then
    rsync -az --delete -e "$RSYNC_RSH" "${RSYNC_EXCLUDES[@]}" "$PARENT_DIR/voltaire/" "$REMOTE_HOST:$REMOTE_DIR/voltaire/"
fi
if [[ -d "$PARENT_DIR/guillotine-mini" ]]; then
    rsync -az --delete -e "$RSYNC_RSH" "${RSYNC_EXCLUDES[@]}" "$PARENT_DIR/guillotine-mini/" "$REMOTE_HOST:$REMOTE_DIR/guillotine-mini/"
fi

REMOTE_ARGS=(--local --seconds "$SECONDS_PER_TARGET" --jobs "$JOBS" --optimize "$OPTIMIZE")
if [[ -n "$FILTER" ]]; then
    REMOTE_ARGS+=(--filter "$FILTER")
fi
if [[ "$RUN_PROPERTIES" -eq 0 ]]; then
    REMOTE_ARGS+=(--skip-properties)
fi

printf -v REMOTE_CMD '%q ' "$REMOTE_DIR/zevm/tools/fuzz_ubuntu.sh" "${REMOTE_ARGS[@]}"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_DIR/zevm/tools/fuzz_ubuntu.sh' && $REMOTE_CMD"
