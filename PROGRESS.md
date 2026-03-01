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

- Full test suite: **295/295 passing** (`zig build test --summary all`)
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
- Implemented `eth_subscribe` `"syncing"` notification behavior by emitting a `false` subscription result once (matching non-syncing dev-node status), with regression coverage.
- Tightened `eth_call` parameter validation to reject non-string `from` values (no silent fallback to default sender), with NodeHandler and server-level `-32602` coverage.
- Expanded `eth_feeHistory` response completeness:
  - now includes `baseFeePerBlobGas` and `blobGasUsedRatio` fields,
  - supports `reward` matrix output when reward percentiles are requested,
  - validates reward percentiles (finite, 0..100, nondecreasing) and maps invalid input to `Invalid params`.
- Fixed block response conversion to preserve real `extraData` bytes instead of always returning `"0x"`, with regression coverage.
- Added NodeHandler/server regression coverage for `eth_feeHistory` extended outputs (blob fee fields and reward matrix path).
- Hardened mining-control RPC input parsing:
  - malformed `hardhat_setIntervalMining` / `evm_setIntervalMining` arguments now return `Invalid params`,
  - malformed `evm_mine` / `hardhat_mine` count arguments now return `Invalid params`,
  - added NodeHandler and server-level `-32602` regressions.
- Added server-level regression coverage that `eth_newFilter` with missing params maps to `-32602`.
- Added shared call-request parser regressions so non-string `from` is rejected consistently across `eth_call`, `eth_estimateGas`, and `debug_traceCall` (including server-level `-32602` coverage).
- Implemented canonical block sealing for mined transactions and empty `evm_mine`/`hardhat_mine` blocks:
  - mined blocks are now persisted in blockchain storage,
  - block bodies include mined transactions,
  - transaction metadata (`blockHash`, `blockNumber`, index) now reflects canonical sealed blocks.
- Wired production mining flow to index receipts/logs at seal time, fixing end-to-end `eth_getTransactionReceipt` / `eth_getBlockReceipts` / `eth_getLogs` visibility for real mined transactions.
- Added stable ownership for block-body transaction bytes to prevent dangling references across runtime snapshot/revert.
- Extended `evm_snapshot`/`evm_revert` runtime snapshots to include receipt/log indexes, restoring index state correctly on revert.
- Added regression coverage for:
  - canonical empty-block persistence via `evm_mine`,
  - canonical mined block body persistence in automine,
  - receipt/log index rollback correctness after `evm_revert`.
- Added server-level end-to-end regressions for:
  - automined receipt visibility through `eth_getTransactionReceipt`,
  - `eth_getBlockReceipts` returning `[]` for manually mined empty blocks.
- Hardened canonical block-header correctness for mined blocks:
  - `transactions_root` now computed from canonical tx trie entries,
  - `receipts_root` now computed from canonical receipt trie entries (typed/legacy),
  - local-mode `state_root` now recomputed from runtime state caches during block sealing.
- Added handler-level regression assertions that non-empty mined blocks no longer emit empty tx/receipt/state roots.
- Fixed runtime snapshot fidelity for `evm_snapshot`/`evm_revert` to include sealed block-transaction byte storage, preventing unbounded retained memory across mine/revert loops.
- Fixed `eth_getFilterLogs` to honor the originally installed filter block range instead of force-overriding to `0..head`; added regression coverage for range-preserving behavior.
- Hardened `eth_call` / `eth_estimateGas` / `debug_traceCall` block-parameter validation to reject invalid second-parameter types with `Invalid params` (`-32602`), with NodeHandler and server-level regressions.
- Fixed log-filter first-poll semantics for `eth_getFilterChanges`:
  - `fromBlock` filters now replay historical logs on first poll,
  - `blockHash` log filters now return matching logs once on first poll (instead of returning empty/invalid behavior).
  - explicit `fromBlock: "latest"` now correctly tails future logs only (no historical head replay).
- Hardened log-filter polling across chain movement:
  - `blockHash` filters no longer replay duplicate logs after unrelated head advances,
  - log filters now recover correctly after `evm_revert` head rewinds instead of stalling permanently.

## Notes

- ZEVM intentionally remains a thin integration layer. If a capability is missing in primitives/runtime internals, it should still be added upstream (`voltaire` / `guillotine-mini`) and consumed here.
