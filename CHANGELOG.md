# Changelog

## Unreleased

- Install the canonical EIP-4788, EIP-2935, EIP-7002, and EIP-7251 system contract
  bytecode (nonce 1, empty storage) in every node-owned local/dev genesis. Mining a
  Prague or Osaka block on a dev or mainnet-configured chain previously failed with
  `MissingSystemContractCode`. Explicit `--genesis` files and forked state remain
  unchanged, and Prague/Osaka blocks without system contract code remain invalid.
  **The devnet genesis state root and block hash change.**
- Populate `requests_hash` directly on mined Prague/Osaka `BlockHeader`s and execute
  canonical EIP-4788 and EIP-2935 bytecode via `SYSTEM_ADDRESS` when deployed.

## 0.1.0

- Report `0.1.0` from the native `version()` export; it reported `0.0.0`. `npm-smoke` now fails when the addon and package versions differ.
- Add npm metadata to `@evmts/zevm`: repository, homepage, bugs, keywords, and `engines.node >= 22.12.0`, the first Node 22 release that loads this ES module through `require()`.
- Ship the repository `LICENSE` in the main and platform packages.
- Add `npm run verify:release`, which checks that the package, platform packages, optional dependencies, `build.zig.zon`, the native version, and an optional `v<version>` tag agree. `publish:all` runs it first.
- `publish:all` lists every platform package without a staged addon, publishes prereleases under their prerelease dist-tag instead of `latest`, and adds `--provenance` in GitHub Actions.
- Always return canonical `difficulty` and `totalDifficulty` quantities in block responses, including zero-valued dev blocks.
- Embed the execution node through the C ABI and JavaScript Node-API bindings.
- Execute using adjacent Voltaire and Guillotine Mini sources, with immutable CI pins.
- Support serialized native JSON-RPC, fork state resolution, deployment, state editing,
  mining, receipts, filters, and bounded opcode tracing for the TEVM host.
- Remove the EthereumJS implementation and all owned TypeScript source.
- Preserve constructor output and structured execution failure diagnostics.

This is a breaking replacement for the old EthereumJS re-export package.
