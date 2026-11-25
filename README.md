# ZEVM

ZEVM is a Zig Ethereum client with two runtime modes:

- **Trusted mode**: a writable local dev node with deterministic dev accounts, mining controls, transaction submission, snapshots, and local state mutation helpers.
- **Light mode**: a proof-backed, consensus-anchored read-only client for execution reads.

Forking is trusted-mode configuration, not a separate runtime mode.

## Installation

ZEVM builds against sibling checkouts of Voltaire and Guillotine Mini at `../voltaire` and `../guillotine-mini`; `build.zig.zon` resolves both by path, and `native-dependencies.json` pins each to a commit. Requires Zig `0.15.2`, Rust/Cargo for Voltaire's Rust crypto archive, and `git` plus `jq` for the checkout script.

### Build From Source

```bash
git clone git@github.com:evmts/zevm.git
cd zevm
bash tools/checkout-native.sh
zig build --fetch
zig build dependency-preflight -- --zig-version 0.15.2
zig build
```

`tools/checkout-native.sh` clones each missing sibling at its pinned commit. It never resets an existing checkout, and it fails if an existing sibling's `HEAD` differs from the pin. CI runs the same script.

The binary is installed to `./zig-out/bin/zevm`.

Release-style artifacts for the selected target:

```bash
zig build release-binaries -Doptimize=ReleaseSafe
zig build c-ffi -Doptimize=ReleaseSafe
zig build npm-platform-artifacts -Doptimize=ReleaseSafe
```

Outputs are written under `zig-out/dist/`, `zig-out/lib`, `zig-out/include`, and `zig-out/npm/prebuilds/`.

For pinned release tuples, mode-specific startup, and runtime configuration, start with [docs/quickstart/installation.mdx](./docs/quickstart/installation.mdx).

## Documentation

The public docs are authored under [docs/](./docs/), with Astro/Starlight site sources mirrored under [docs/src/content/docs/](./docs/src/content/docs/). After editing `docs/`, run `node tools/docs_mirror.mjs --write` to refresh the mirror; `node tools/docs_mirror.mjs` fails on drift.
To build the site locally, use Node.js 22.23.4 or later and run `npm ci` followed by `npm run build` from `docs/`.

Canonical contract sources:

- [docs/specs/prd.md](./docs/specs/prd.md): product, startup, runtime, release, and qualification contract
- [docs/specs/json-rpc-contract.md](./docs/specs/json-rpc-contract.md): exact JSON-RPC methods, params, payloads, selectors, and errors

If implementation, tests, or public docs diverge from those specs, treat the mismatch as release-blocking unless the behavior is explicitly moved to deferred or out-of-contract docs.

## Contributing

```bash
npm --prefix npm/zevm install --ignore-scripts
zig build test
zig build verify-fast
zig build fuzz -Doptimize=ReleaseSafe
zig build c-smoke
zig build npm-smoke
node --check npm/zevm/src/index.js
```

### Fuzz Testing

ZEVM ships 14 property-based and native `std.testing.fuzz` suites (30 coverage-guided targets covering consensus, EVM execution, state/MPT proofs, KZG blobs, JSON-RPC, Engine API, light client, config/CLI/genesis, and the C ABI):

```bash
# Run all deterministic property tests and fuzz corpora (macOS & Linux)
zig build fuzz -Doptimize=ReleaseSafe
zig build fuzz-c-abi -Doptimize=ReleaseSafe
zig build fuzz -Dfuzz-filter="rpc"

# Run live coverage-guided --fuzz across all 30 targets (Linux locally, or synced to bare-metal Ubuntu from macOS)
./tools/fuzz_ubuntu.sh --list
./tools/fuzz_ubuntu.sh --optimize ReleaseSafe --seconds 30 --jobs 8
```

Behavior changes are docs-first: update `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` before landing code that changes startup, runtime modes, JSON-RPC behavior, release metadata, the C ABI, or npm distribution. The full process is in [docs/specs/docs-first-process.md](./docs/specs/docs-first-process.md).

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the local workflow, release gates, C ABI, and npm package notes.

See the [submodule update policy](./docs/reference/submodule-update-policy.md) for the fixture inputs required by `zig build verify` and the status of the archived Execution Spec Tests repository.

## npm release

Run `gh workflow run release.yml --ref main` to build all 11 platform addons and the browser WASM, validate their tarballs, and test installation. The workflow retains the 12 tarballs as the `npm-tarballs` artifact. To publish, dispatch with `-f publish=true` or push the matching version tag (for this release, `v0.1.0`) at the tip of main. Publication requires successful CI on that commit and uploads the platform packages first.

Configure the npm trusted publisher on each package for `evmts/zevm`, workflow `release.yml`, environment `npm`. For bootstrap, the environment can supply an npm granular publish token as `NPM_TOKEN`. The publisher checks registry integrity before resuming a partial publication.
