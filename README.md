# ZEVM

ZEVM is a Zig Ethereum client with two runtime modes: a writable local dev node (trusted mode) and a proof-backed, consensus-anchored read-only client (light mode). Forking is configuration inside trusted mode, not a separate mode.

## Installation

ZEVM builds from pinned Zig package-manager dependencies. Requires Zig `0.15.2` or newer plus Rust/Cargo for Voltaire's Rust crypto archive.

### Build from source

```bash
git clone git@github.com:evmts/zevm.git
cd zevm
zig build --fetch
zig build dependency-preflight -- --zig-version 0.15.2
zig build
```

The binary is installed to `./zig-out/bin/zevm`.

Release-style artifacts for the selected target:

```bash
zig build release-binaries -Doptimize=ReleaseSafe
zig build c-ffi
zig build npm-platform-artifacts -Doptimize=ReleaseSafe
```

Outputs are written under `zig-out/dist/`, `zig-out/lib`, `zig-out/include`, and `zig-out/npm/prebuilds/`.

For pinned release tuples and per-mode setup, see [docs/quickstart/installation.mdx](./docs/quickstart/installation.mdx).

## Some notes

We are very very early in this project. Expect bugs.

Product contract: [docs/specs/prd.md](./docs/specs/prd.md) and [docs/specs/json-rpc-contract.md](./docs/specs/json-rpc-contract.md). Full docs site sources live under [docs/](./docs/).

## Contributing

```bash
npm --prefix npm/zevm install --ignore-scripts
zig build test
zig build c-smoke
zig build npm-smoke
npm --prefix npm/zevm run typecheck
```

The canonical specs in `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` define the phase-1 public contract. If implementation or tests diverge from those specs, treat that as release-blocking unless the behavior is explicitly moved to deferred or out-of-contract docs.

Behavior changes are docs-first: update `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` before landing code. The full process is in [docs/specs/docs-first-process.md](./docs/specs/docs-first-process.md).

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the local workflow, release gates, C ABI, and npm package notes.
