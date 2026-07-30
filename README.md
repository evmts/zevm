# ZEVM

ZEVM is a Zig Ethereum client with two runtime modes:

- **Trusted mode**: a writable local dev node with deterministic dev accounts, mining controls, transaction submission, snapshots, and local state mutation helpers.
- **Light mode**: a proof-backed, consensus-anchored read-only client for execution reads.

Forking is trusted-mode configuration, not a separate runtime mode.

## Installation

Install the prerelease TypeScript bindings and native addon from npm:

```bash
npm install @evmts/zevm@beta
```

`@evmts/zevm` is published from this repository together with optional native
packages for macOS, Linux (glibc and musl), and Windows. The Zig package is also
consumable directly from a pinned Git commit, but npm is the supported
distribution target for Node.js consumers.

ZEVM builds from pinned Zig package-manager dependencies. The supported source
toolchain is Zig `0.15.2`, Rust `1.89.0`, and Node.js `22.22.0` or newer. Release
publishing uses Node.js `24.11.1` with npm `11.6.2` for npm trusted publishing.

### Build From Source

```bash
git clone https://github.com/evmts/zevm.git
cd zevm
git submodule update --init --depth 1 lib/execution-apis
zig build --fetch
zig build dependency-preflight -- --zig-version 0.15.2
zig build
```

The binary is installed to `./zig-out/bin/zevm`.

Run the complete local unit suite:

```bash
zig build test
```

Release-style artifacts for the selected target:

```bash
zig build release-binaries -Doptimize=ReleaseSafe
zig build c-ffi
zig build npm-platform-artifacts -Doptimize=ReleaseSafe
```

Outputs are written under `zig-out/dist/`, `zig-out/lib`, `zig-out/include`, and `zig-out/npm/prebuilds/`.

For pinned release tuples, mode-specific startup, and runtime configuration, start with [docs/quickstart/installation.mdx](./docs/quickstart/installation.mdx).

## Documentation

Published documentation lives at [zevm.tevm.sh](https://zevm.tevm.sh).

The public docs are authored under [docs/](./docs/), with Astro/Starlight site sources mirrored under [docs/src/content/docs/](./docs/src/content/docs/).

Canonical contract sources:

- [docs/specs/prd.md](./docs/specs/prd.md): product, startup, runtime, release, and qualification contract
- [docs/specs/json-rpc-contract.md](./docs/specs/json-rpc-contract.md): exact JSON-RPC methods, params, payloads, selectors, and errors

If implementation, tests, or public docs diverge from those specs, treat the mismatch as release-blocking unless the behavior is explicitly moved to deferred or out-of-contract docs.

## Contributing

```bash
npm --prefix npm/zevm ci --ignore-scripts
zig build test
zig build verify-fast
zig build c-smoke
zig build npm-smoke
npm --prefix npm/zevm run typecheck
```

Behavior changes are docs-first: update `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` before landing code that changes startup, runtime modes, JSON-RPC behavior, release metadata, the C ABI, or npm distribution. The full process is in [docs/specs/docs-first-process.md](./docs/specs/docs-first-process.md).

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the local workflow, release gates, C ABI, and npm package notes.

## Release policy

The first real release is `0.1.0-beta.1`: the public API and native ABI are
usable, while the client is still pre-1.0 and its cross-platform packaging needs
consumer feedback. A GitHub Release whose tag exactly matches
`v<package-version>` runs the full build and tests, builds every supported native
package, and publishes the platform packages before `@evmts/zevm` with npm
provenance. Maintainers must not run `npm publish` locally.
