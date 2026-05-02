# ZEVM

ZEVM is a Zig Ethereum client with two runtime modes: a writable local dev node (trusted mode) and a proof-backed, consensus-anchored read-only client (light mode). Forking is configuration inside trusted mode, not a separate mode.

## Installation

> [!WARNING]
> ZEVM is source-build only. Phase 1 does not ship packaged binaries.
> Before building, clone the upstream sibling repos in the same parent directory:
>
> - [`voltaire`](https://github.com/evmts/voltaire) — path dependency for primitives, state, and JSON-RPC types
> - [`guillotine-mini`](https://github.com/evmts/guillotine-mini) — path dependency for the EVM interpreter
>
> Requires Zig `0.15.2` or newer plus Rust/Cargo for Voltaire's Rust crypto archive.

### Build from source

```bash
git clone git@github.com:evmts/zevm.git
git clone git@github.com:evmts/voltaire.git
git clone git@github.com:evmts/guillotine-mini.git
cd zevm
zig build dependency-preflight -- --zig-version 0.15.2
zig build
```

The binary is installed to `./zig-out/bin/zevm`.

For pinned release tuples and per-mode setup, see [docs/quickstart/installation.mdx](./docs/quickstart/installation.mdx).

## Some notes

We are very very early in this project. Expect bugs.

We are not accepting contributions yet.

Product contract: [docs/specs/prd.md](./docs/specs/prd.md) and [docs/specs/json-rpc-contract.md](./docs/specs/json-rpc-contract.md). Full docs site sources live under [docs/](./docs/).

## If you REALLY want to contribute still.... read this first

```bash
zig build test
```

The canonical specs in `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` define the phase-1 public contract. If implementation or tests diverge from those specs, treat that as release-blocking unless the behavior is explicitly moved to deferred or out-of-contract docs.

Behavior changes are docs-first: update `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` before landing code. The full process is in [docs/specs/docs-first-process.md](./docs/specs/docs-first-process.md).

`voltaire` and `guillotine-mini` are upstream dependencies we own. If something is missing or broken there, fix it in those repos rather than working around it in `zevm`.
