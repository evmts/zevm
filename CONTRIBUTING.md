# Contributing

ZEVM uses docs-first changes and pinned Zig package-manager dependencies.

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

Do not edit `build.zig.zon` back to sibling `../voltaire` or `../guillotine-mini` paths. Dependency pins must be immutable archive URLs plus Zig package hashes.

## Local Gates

```bash
zig build test
zig build verify-fast
zig build c-smoke
zig build npm-smoke
npm --prefix npm/zevm run typecheck
```

Before a release candidate, run:

```bash
zig build qualification-check -- --require-covered
zig build verify
bun tools/hive_rpc_compat_smoke.ts
```

## Release Artifacts

Build release-style artifacts for the selected target:

```bash
zig build release-binaries -Doptimize=ReleaseSafe
zig build c-ffi -Doptimize=ReleaseSafe
zig build npm-platform-artifacts -Doptimize=ReleaseSafe
```

The C ABI contract lives in `include/zevm.h`. The TypeScript package in `npm/zevm` must call ZEVM through that header and the N-API addon in `npm/zevm/native`.

## Docs-First Rule

Behavior changes that affect startup, runtime modes, JSON-RPC behavior, release metadata, C ABI, or npm distribution need docs/spec updates in the same change. Start with:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`
- `docs/reference/ci-and-release-gates.mdx`
- `docs/quickstart/installation.mdx`
