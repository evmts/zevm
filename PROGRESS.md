# ZEVM Progress Report

**Last Updated:** 2026-03-01  
**Zig Version:** 0.15.2

## Executive Summary

ZEVM now provides a functional Hardhat/Anvil-style Ethereum dev node and light-client foundation on Zig, backed by upstream `voltaire` and `guillotine-mini`. The originally missing RPC/runtime layers are implemented, tested, and build-clean.

## Project Status

| Area | Status |
|------|--------|
| Consensus light client sync | ✅ Complete |
| Transaction processing | ✅ Complete |
| Block building | ✅ Complete |
| Host adapter (guillotine-mini ↔ state-manager) | ✅ Complete |
| HTTP JSON-RPC server + dispatch + batch | ✅ Complete |
| Core `eth_*` read methods | ✅ Complete |
| `eth_call` + `eth_estimateGas` (checkpoint/revert + overrides) | ✅ Complete |
| Transaction submission + mempool integration | ✅ Complete |
| Block/tx queries (`getBlock*`, `getTransaction*`, receipts, logs) | ✅ Complete |
| Mining modes (auto/manual/interval + RPC controls) | ✅ Complete |
| Snapshot/revert (`evm_snapshot`, `evm_revert`) | ✅ Complete |
| State manipulation (`hardhat_*`, `anvil_*`, `evm_setBlockGasLimit`) | ✅ Complete |
| Impersonation (`hardhat_impersonateAccount`) | ✅ Complete |
| Fork mode (`--fork-url`, ForkBackend integration) | ✅ Complete |
| Debug tracing (`debug_traceCall`, `debug_traceTransaction`) | ✅ Complete |
| Filters + WebSocket subscriptions | ✅ Complete |
| Time controls (`evm_increaseTime`, `evm_setNextBlockTimestamp`) | ✅ Complete |

## Validation

- Full test suite: **205/205 passing** (`zig build test --summary all`)
- Full build: **passing** (`zig build`)

## Recent Completion Highlights

- Added runtime snapshot restoration (mempool, tx index, mining config/events, impersonation set) on `evm_revert`.
- Added mining mode RPC controls:
  - `hardhat_setAutomine`, `evm_setAutomine`, `anvil_setAutomine`
  - `hardhat_setIntervalMining`, `evm_setIntervalMining`, `anvil_setIntervalMining`
- Added background interval-mining loop in RPC server runtime.
- Expanded NodeHandler coverage for block/pending filters, mining aliases, time/randao controls, and nested snapshot invalidation.
- Fixed server runtime build issues discovered by `zig build` validation.
- Hardened JSON-RPC runtime ownership in NodeHandler conversion paths (no server crashes under live request handling).
- Added server-context regression tests for NodeHandler responses (`eth_chainId`, `hardhat_mine`, `eth_feeHistory`, `eth_getBlockByNumber`).
- Mapped unknown filter lookups to JSON-RPC server error `-32000` (`Filter not found`) and validated via tests.
- Expanded subscription coverage (`newHeads` notifications and `eth_unsubscribe` lifecycle semantics).
- Implemented JSON-RPC notification suppression semantics (`204` for notifications without `id`; `id: null` still responds).

## Notes

- ZEVM intentionally remains a thin integration layer. If a capability is missing in primitives/runtime internals, it should still be added upstream (`voltaire` / `guillotine-mini`) and consumed here.
