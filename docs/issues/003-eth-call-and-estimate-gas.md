# Eth Call And Estimate Gas

> **Archived / non-normative:** This issue is historical context only. Claims below are filing-time observations and may contradict current contract docs. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md); if anything differs, those normative docs win.
>
> **Resolved / superseded status:** This issue is closed as an active gap tracker and retained for archive history only. For current requirements and behavior, use [docs/specs/prd.md](../specs/prd.md), [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md), and [docs/specs/page-ownership.md](../specs/page-ownership.md).


## Historical Gap Snapshot At Filing Time

- There is no `eth_call` implementation under `src/rpc/`.
- There is no `eth_estimateGas` implementation under `src/rpc/`.
- No non-persisted execution path, revert-data path, state-override support, or gas-estimation search exists on the RPC surface.
- The only execution substrate here is `tx_processor`, which is persisted, legacy-only, and currently stale against the upstream `guillotine-mini` API.

## Evidence

- `src/rpc/handlers/`
- `src/tx_processor.zig`
- `src/host_adapter.zig`
- `../guillotine-mini/src/evm.zig`

## Historical Resolution Criteria

- `eth_call` executes calls and creations without persisting state.
- `eth_call` returns revert data correctly and supports state overrides.
- `eth_estimateGas` finds the minimum successful gas for transfer, call, storage-write, and create flows.
- Both methods support pending overlays, forked state, and explicit block-selector semantics.
- Malformed params and invalid selectors return deterministic compat-oriented errors.
