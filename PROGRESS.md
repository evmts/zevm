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

- Full test suite: **260/260 passing** (`zig build test --summary all`)
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
- Added coverage that notifications still execute side effects while suppressing responses (single and mixed batch).
- Improved batch compliance for mixed-validity payloads by returning per-item `-32600` errors for invalid batch entries.
- Expanded notification tests to cover unknown-method suppression behavior in both single and mixed batch requests.
- Added CLI support for deterministic fork pinning via `--fork-block-number` (decimal or hex).
- Improved invalid-request compatibility by echoing request `id` when present and parseable.
- Added config validation that `--fork-block-number` requires `--fork-url`.
- Expanded invalid-request ID compatibility coverage (integer/string/float input handling for error `id` echo).
- Hardened host adapter fork behavior to resolve async `RpcPending` requests safely instead of panicking.
- Wired fork request resolution into `eth_call`, gas estimation, tracing, and mined transaction execution paths.
- Fixed automine to only evict transactions that were actually mined in the block.
- Added host adapter fork regression tests for unresolved-default fallback and resolver-backed request completion.
- Hardened invalid-request `id` echo for float values (integral in-range only; fractional/out-of-range safely return `null` id).
- Fixed automine to enforce runtime block gas limit for transaction inclusion (no hardcoded gas limit in mined tx execution path).
- Hardened `eth_sendTransaction` input parsing to reject malformed `to` and `data` fields instead of coercing to contract-create/empty input defaults.
- Tightened access-list parsing cleanup to avoid partial-allocation leaks on malformed input error paths.
- Added NodeHandler-level regression coverage for malformed `eth_sendTransaction` input mapping to `InvalidParams`.
- Added NodeHandler-level regression coverage that `evm_setBlockGasLimit` constrains automine inclusion.
- Added server-level guardrails against unsafe float request IDs (fractional/out-of-range), preventing parser trap risk and returning compliant `-32600` invalid-request responses.
- Added `eth_sendTransaction` support for EIP-4844 typed transactions (`type: 0x3`) including blob-fee/hash field parsing, signing, and tx indexing.
- Added regression coverage for EIP-4844 typed send success and required-field validation.
- Added NodeHandler-level regression coverage for EIP-4844 typed `eth_sendTransaction`.
- Added `eth_sendTransaction` support for EIP-7702 typed transactions (`type: 0x4`) including authorization-list parsing, signing, and tx indexing.
- Added regression coverage for EIP-7702 typed send support in both handler-level and NodeHandler-level paths.
- Fixed `eth_getLogs` and `eth_getTransactionReceipt` log conversion to preserve real `data` and `topics` instead of returning empty placeholders.
- Added regression coverage ensuring RPC log payload fidelity for both log queries and receipt queries.
- Changed invalid `eth_getLogs` filter handling to return JSON-RPC `Invalid params` semantics instead of silently returning empty arrays.
- Changed malformed block-spec handling for `eth_getBlockByNumber` and `eth_getBlockReceipts` to return `Invalid params` while preserving null responses for out-of-range block lookups.
- Fixed `eth_getLogs` block-range quantity parsing so malformed quantities are rejected as `Invalid params` instead of being treated as omitted filters.
- Hardened `eth_read` input validation:
  - malformed block specs now map to `Invalid params` for state-read RPCs,
  - malformed `eth_getStorageAt` slot values no longer coerce to zero,
  - malformed/zero `eth_feeHistory` block counts now return `Invalid params`.
- Added server-level regression coverage for malformed `eth_getStorageAt` and `eth_getLogs` parameters to verify end-to-end `-32602` JSON-RPC mapping.
- Hardened filter/subscription input validation:
  - `eth_newFilter` now requires exactly one object filter argument,
  - `eth_subscribe` with `logs` now rejects non-object filter payloads,
  - malformed stored filter JSON now propagates `Invalid params` instead of silently becoming `{}`.

## Notes

- ZEVM intentionally remains a thin integration layer. If a capability is missing in primitives/runtime internals, it should still be added upstream (`voltaire` / `guillotine-mini`) and consumed here.
