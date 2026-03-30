# Snapshots And State Manipulation

> **Archived / non-normative:** This issue is historical context only. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md).


## Verified Gap

- `dev_runtime.zig` and `dev_handlers.zig` are disconnected from `main`, and the live dispatcher rejects `evm_*` / `hardhat_*` methods outright.
- `DevRuntime.revertSnapshot` calls `bc.revertToBlock(...)`, but the current sibling `Blockchain` API does not expose that method.
- The snapshot model only captures a state snapshot ID, block number, and a narrow config; it does not capture pending txs, mining mode, indexes, timestamps, impersonation, or fork state.
- Config mutators update `DevRuntime.config`, while normal reads use `NodeRuntime`, so coinbase/base-fee/block-gas-limit changes are not wired into the standard read surface.
- Input validation is too weak: negative JSON integers can be bitcast into huge `u256` values instead of being rejected.
- The dev-runtime tests live inside orphan files and are not on the default test graph.

## Evidence

- `src/main.zig`
- `src/rpc/dispatcher.zig`
- `src/rpc/dev_runtime.zig`
- `src/rpc/dev_handlers.zig`
- `src/rpc/handlers/eth_read.zig`
- `src/node/runtime.zig`
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`

## Resolution Verification

- Snapshot/revert is exposed over RPC and restores the full node state model, not just `StateManager` contents.
- Unknown snapshot IDs return `false` without corrupting runtime state.
- Hardhat-style mutators are visible immediately through the normal read surface and later block production.
- Invalid addresses, malformed hex, over-width quantities, and negative integers return `-32602`.
- The dev-control test surface is on the default graph and backed by end-to-end RPC verification.
