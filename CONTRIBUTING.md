# Contributing

ZEVM uses docs-first changes and the maintained sibling Zig sources.

## Prerequisites

- Zig `0.15.2`
- Rust/Cargo
- Node `22` or newer for npm package checks
- Bun for Hive and release audit tooling
- `jj` for local version-control work in this repository

## Setup

```bash
zig build --fetch
zig build dependency-preflight -- --zig-version 0.15.2
npm --prefix npm/zevm install --ignore-scripts
zig build
```

Keep `../voltaire` and `../guillotine-mini` beside this checkout. Native builds use those sources directly.

## Local Gates

```bash
zig build test
zig build verify-fast
zig build fuzz -Doptimize=ReleaseSafe
zig build c-smoke
zig build npm-smoke
node --check npm/zevm/src/index.js
```

For live coverage-guided fuzzing (`std.testing.fuzz --fuzz`, supported on Linux/Ubuntu):

```bash
./tools/fuzz_ubuntu.sh --list
./tools/fuzz_ubuntu.sh --optimize ReleaseSafe --seconds 30 --jobs 8
```

Before a release candidate, run:

```bash
zig build qualification-check -- --require-covered
zig build verify
bun tools/hive_rpc_compat_smoke.js
```

`zig build verify` includes `zig build trie-tests`, which replays `lib/ethereum-tests/TrieTests` against `primitives.TrieHash` roots and ZEVM `eth_getProof` proofs (`tools/trie_tests.zig`). `trietestnextprev.json` is excluded because ZEVM exposes no trie iterator; any new unclassified fixture file fails the run.

## Release Artifacts

Build release-style artifacts for the selected target:

```bash
zig build release-binaries -Doptimize=ReleaseSafe
zig build c-ffi -Doptimize=ReleaseSafe
zig build npm-platform-artifacts -Doptimize=ReleaseSafe
```

The C ABI contract lives in `include/zevm.h`. The JavaScript loader in `npm/zevm` must call ZEVM through that header and the N-API addon in `npm/zevm/native`.

## Docs-First Rule

Behavior changes that affect startup, runtime modes, JSON-RPC behavior, release metadata, C ABI, or npm distribution need docs/spec updates in the same change. Start with:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`
- `docs/reference/ci-and-release-gates.mdx`
- `docs/quickstart/installation.mdx`
