# Eth Call And Estimate Gas

## Verified Gap

- There is no `eth_call` implementation under `src/rpc/`.
- There is no `eth_estimateGas` implementation under `src/rpc/`.
- No non-persisted execution path, revert-data path, state-override support, or gas-estimation search exists on the RPC surface.
- The only execution substrate here is `tx_processor`, which is persisted, legacy-only, and currently stale against the upstream `guillotine-mini` API.

## Evidence

- `src/rpc/handlers/`
- `src/tx_processor.zig`
- `src/host_adapter.zig`
- `../guillotine-mini/src/evm.zig`

## Resolution Verification

- `eth_call` executes calls and creations without persisting state.
- `eth_call` returns revert data correctly and supports state overrides.
- `eth_estimateGas` finds the minimum successful gas for transfer, call, storage-write, and create flows.
- Both methods support pending overlays, forked state, and explicit block-selector semantics.
- Malformed params and invalid selectors return deterministic compat-oriented errors.
