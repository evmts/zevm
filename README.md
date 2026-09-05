# ZEVM

ZEVM is a Zig Ethereum client with two runtime modes:

- **Trusted mode**: a writable local dev node with deterministic dev accounts, mining controls, transaction submission, snapshots, and local state mutation helpers.
- **Light mode**: a proof-backed, consensus-anchored read-only client for execution reads.

Forking is trusted-mode configuration, not a separate runtime mode.

## Installation

ZEVM builds from pinned Zig package-manager dependencies. Requires Zig `0.15.2` or newer plus Rust/Cargo for Voltaire's Rust crypto archive.

### Build From Source

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

For pinned release tuples, mode-specific startup, and runtime configuration, start with [docs/quickstart/installation.mdx](./docs/quickstart/installation.mdx).

## Documentation

The public docs are authored under [docs/](./docs/), with Astro/Starlight site sources mirrored under [docs/src/content/docs/](./docs/src/content/docs/).

Canonical contract sources:

- [docs/specs/prd.md](./docs/specs/prd.md): product, startup, runtime, release, and qualification contract
- [docs/specs/json-rpc-contract.md](./docs/specs/json-rpc-contract.md): exact JSON-RPC methods, params, payloads, selectors, and errors

If implementation, tests, or public docs diverge from those specs, treat the mismatch as release-blocking unless the behavior is explicitly moved to deferred or out-of-contract docs.

## Contributing

```bash
npm --prefix npm/zevm install --ignore-scripts
zig build test
zig build verify-fast
zig build c-smoke
zig build npm-smoke
node --check npm/zevm/src/index.js
```

Behavior changes are docs-first: update `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` before landing code that changes startup, runtime modes, JSON-RPC behavior, release metadata, the C ABI, or npm distribution. The full process is in [docs/specs/docs-first-process.md](./docs/specs/docs-first-process.md).

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the local workflow, release gates, C ABI, and npm package notes.

## Native package release

The next execution-node package version is `0.1.0`. Release builders must stage
all platform addons advertised in `npm/zevm/package.json`, then run
`node npm/zevm/scripts/publish-all.cjs --dry-run` before the same command without
`--dry-run`. Publication fails before uploading anything if a platform is missing.
`zig build npm-platform-artifacts -Doptimize=ReleaseSafe -Dtarget=<zig-triple>`
builds one selected platform; it is not a cross-platform release matrix.

CI obtains the native sibling sources from `native-dependencies.json` using
`bash tools/checkout-native.sh`. Existing local checkouts are never reset.
