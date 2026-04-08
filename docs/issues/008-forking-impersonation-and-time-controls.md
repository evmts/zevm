# Forking, Impersonation, And Time Controls

> **Archived / non-normative:** This issue is historical context only. Claims below are filing-time observations and may contradict current contract docs. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md); if anything differs, those normative docs win.
>
> **Resolved / superseded status:** This issue is closed as an active gap tracker and retained for archive history only. For current requirements and behavior, use [docs/specs/prd.md](../specs/prd.md), [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md), and [docs/specs/page-ownership.md](../specs/page-ownership.md).


## Historical Gap Snapshot At Filing Time

- There is no `--fork-url` or other fork-mode startup/config surface in ZEVM.
- `NodeRuntime` and `Database` hardcode `StateManager.init(..., null)` and never use upstream `ForkBackend`.
- `hardhat_impersonateAccount`, `hardhat_stopImpersonatingAccount`, `evm_increaseTime`, `evm_setNextBlockTimestamp`, and `hardhat_setPrevRandao` are absent from the codebase.
- The runtime has no fields for impersonated-account state, time offsets, next-block timestamps, or `prevRandao` overrides.

## Evidence

- `src/main.zig`
- `src/rpc/server.zig`
- `src/node/runtime.zig`
- `src/database/database.zig`
- `../voltaire/packages/voltaire-zig/src/state-manager/root.zig`
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`

## Historical Resolution Criteria

- Starting with a fork URL reads remote state while preserving local overlays.
- Local writes on forked state are isolated from the remote source and survive subsequent reads.
- Impersonation allows `eth_sendTransaction` from unmanaged addresses only while active.
- Time controls affect the next mined block exactly as specified and interact correctly with mining modes.
- Snapshot/revert on forked state restores local overlays, pending state, and time overrides.
