# ZEVM Contradiction Inventory

Last updated: 2026-03-29

## C-001

- contradiction ID: `C-001`
- product surface: trusted-mode startup, shared CLI flags, config loading, precedence, and validation
- PRD claim: ZEVM starts as one binary, defaults to trusted mode, allows CLI `--mode light` or a sole `mode.light` config branch to select light mode, accepts the documented shared and trusted-mode startup surface, and validates invalid combinations before opening the listener
- observed code reality: `src/main.zig` delegates startup to `src/rpc/server.zig.parseConfig`, and `parseConfig` only recognizes `--host` and `--port`; no mode selection, config-file parsing, precedence logic, light-mode selection path, or trusted-mode validation is wired, and trusted-mode prototype helpers remain split between the top-level node runtime and sidecar `DevRuntime` code instead of one startup-owned authoritative runtime model
- user-facing impact: current `HEAD` cannot be described as exposing the intended startup or configuration contract
- public-doc stance: document the full intended startup and configuration contract, and mark current executable startup as a prototype gap
- maintainer-question needed: no

## C-002

- contradiction ID: `C-002`
- product surface: current repo health baseline
- PRD claim: docs must separate intended product behavior from current repo reality and keep the current baseline dated and explicit
- observed code reality: on 2026-03-29, `git status --short` shows a dirty worktree with docs/control changes plus Mintlify IA additions, removals, and renames; on the same date, `zig build` fails first in `src/rpc/server.zig` because current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`; `zig build test` fails in `src/rpc/dispatcher_test.zig` and `src/rpc/server.zig` because current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`, and also fails in `src/tx_processor.zig` because current `guillotine-mini` requires a wider `evm.init` signature than ZEVM provides; `src/main.zig` still only wires `src/rpc/server.zig.parseConfig`, and `parseConfig` still only accepts `--host` and `--port`
- user-facing impact: no public page may imply that current `HEAD` is a clean, runnable implementation baseline
- public-doc stance: use dated current-`HEAD` caveats and treat the failing build as observed evidence only, not as the product definition
- maintainer-question needed: no

## C-003

- contradiction ID: `C-003`
- product surface: canonical HTTP JSON-RPC transport, batching, notifications, and error framing
- PRD claim: phase 1 ships one canonical HTTP JSON-RPC 2.0 transport rooted in `src/rpc/server.zig` plus `src/rpc/dispatcher.zig`, and missing-`id` notifications produce no JSON-RPC response
- observed code reality: the intended `src/rpc/server.zig` plus `src/rpc/dispatcher.zig` path does not compile against the current upstream `jsonrpc` export surface, `src/rpc/server.zig` does not inspect the request target and therefore does not enforce the documented `/` path, the older `src/rpc/envelope.zig` plus `src/rpc/router.zig` stack is still present, both in-tree transport paths serialize responses for notification-shaped requests instead of returning HTTP `204` with an empty body, and in-tree tests codify that wrong notification behavior
- user-facing impact: current transport behavior is not release-ready and would misstate standard notification semantics if documented as-shipped
- public-doc stance: document the intended transport exactly, explicitly call the missing `/` path enforcement plus the current notification behavior and dual-stack drift a contradiction, and keep empty-batch `[]` in the settled invalid-request contract instead of leaving it implicit
- maintainer-question needed: no

## C-004

- contradiction ID: `C-004`
- product surface: trusted-mode core reads
- PRD claim: phase 1 trusted mode exposes the documented core read set, including correct balance, code, storage, nonce, fee, coinbase, account, and fee-history behavior
- observed code reality: helper implementations exist in `src/rpc/handlers/eth_read.zig`, but they are not wired into executable startup; `eth_getCode` currently ignores stored code and returns `"0x"`; `eth_getStorageAt` currently catches malformed slot parsing and returns zero instead of surfacing `-32602`; and `eth_feeHistory` is still synthetic because it repeats the current base fee, zeroes `gasUsedRatio`, ignores `newestBlock` and reward-percentile behavior, clamps or defaults malformed `blockCount` instead of cleanly rejecting it, and does not reflect mined history
- user-facing impact: current `HEAD` cannot be documented as a correct trusted-read implementation
- public-doc stance: keep the intended read contract intact and call out the current partial or placeholder implementation explicitly
- maintainer-question needed: no

## C-005

- contradiction ID: `C-005`
- product surface: trusted-mode simulation
- PRD claim: phase 1 trusted mode supports `eth_call` and `eth_estimateGas`, including checkpoint-and-revert semantics and state overrides
- observed code reality: no `eth_call` or `eth_estimateGas` handler implementation or dispatcher wiring was found in `src/rpc/handlers` or `src/rpc/dispatcher.zig` on 2026-03-29
- user-facing impact: public docs cannot present current `HEAD` as supporting the simulation surface
- public-doc stance: describe the intended simulation contract and mark it as a prototype gap in current code
- maintainer-question needed: no

## C-006

- contradiction ID: `C-006`
- product surface: transaction submission and mining
- PRD claim: trusted mode supports transaction submission, pending-state semantics, and automine, manual, and interval mining
- observed code reality: `src/rpc/handlers/tx_submission.zig` assumes runtime fields such as `pool`, `mining_mode`, and managed private-key lookup that `src/node/runtime.zig` does not provide, while `src/mining_coordinator.zig` is disconnected from startup and canonical chain state
- user-facing impact: current `HEAD` does not provide a coherent submission or mining runtime
- public-doc stance: document the intended transaction and mining contract and treat the current code as disconnected prototype coverage
- maintainer-question needed: no

## C-007

- contradiction ID: `C-007`
- product surface: canonical block, receipt, log, and transaction queries
- PRD claim: trusted mode exposes canonical block, receipt, log, and transaction query methods with complete response data
- observed code reality: query helpers are unwired, `src/rpc/block_queries.zig` and `src/rpc/handlers/block_query_handlers.zig` still use placeholder transaction hydration and lossy receipt or log serialization, `eth_getTransactionByHash` is a stub that always returns `null`, receipt and log indexes are not populated by the executable path after mining, and `handleGetLogs` currently catches invalid-filter errors and collapses them to `[]` instead of surfacing `-32602`; `eth_getLogs` is therefore part of the intended trusted query surface but still contradictory on current `HEAD`, not a deferred filter-lifecycle API
- user-facing impact: current query output cannot be documented as the intended public contract
- public-doc stance: document the full intended query surface and keep the placeholder or stub reality explicit
- maintainer-question needed: no

## C-008

- contradiction ID: `C-008`
- product surface: exact managed-account contract
- PRD claim: trusted mode publicly specifies the exact mnemonic, derivation root, address order, and private-key table for the first 10 managed accounts
- observed code reality: `src/node/runtime.zig` hardcodes only addresses, omits the private-key table entirely, and disagrees with `src/genesis.zig` and the PRD on account `#7`; `src/rpc/handlers/tx_submission_test.zig` expects a managed private-key table that the runtime does not define
- user-facing impact: current `HEAD` cannot be treated as implementing the exact published managed-wallet contract
- public-doc stance: document the exact PRD table and call the current repo mismatch explicit
- maintainer-question needed: no

## C-009

- contradiction ID: `C-009`
- product surface: trusted-mode snapshot boundary, state mutation, impersonation, and time controls
- PRD claim: trusted mode includes snapshot or revert, Hardhat or Anvil-compatible state mutation methods, impersonation, and time controls, with snapshots capturing the full mutable trusted shell
- observed code reality: `src/rpc/dev_runtime.zig` snapshots only state snapshot ID, block number, and a narrow config; `src/rpc/dev_handlers.zig` exposes only a partial helper subset; implemented setters mutate prototype `DevRuntime` config rather than a shipped top-level runtime; `zevm_reset([forkConfig])`, `zevm_setRpcUrl`, impersonation, and time controls are absent or partial; and the code path is disconnected from executable startup
- user-facing impact: current `HEAD` does not implement the intended `zevm_*` trusted-mode control surface or its documented `anvil_*`, `hardhat_*`, and `evm_*` compatibility aliases
- public-doc stance: document the exact ZEVM-owned `zevm_*` inventory, the exact supported `anvil_*` subset, the exact supported `hardhat_*` subset, the exact shared `evm_*` aliases, and keep the current partial or disconnected code reality explicit
- maintainer-question needed: no

## C-010

- contradiction ID: `C-010`
- product surface: trusted-mode fork startup and overlay semantics
- PRD claim: forking is configuration inside trusted mode, local reads resolve from the local overlay first, and remote reads come from the upstream fork backend
- observed code reality: `src/node/runtime.zig` still initializes `StateManager` with `null`, startup exposes no fork flags, and no executable runtime path wires `ForkBackend`
- user-facing impact: current `HEAD` cannot start the documented fork-backed trusted mode
- public-doc stance: document fork semantics as intended behavior and state plainly that startup integration is still missing
- maintainer-question needed: no

## C-011

- contradiction ID: `C-011`
- product surface: light-mode startup, network selection, and checkpoint configuration
- PRD claim: light mode exposes exact startup and config fields for network selection, consensus RPC, checkpoint input, checkpoint persistence, and checkpoint-age policy
- observed code reality: the consensus substrate exists in `src/consensus_sync.zig`, `src/beacon_api.zig`, and `src/checkpoint.zig`, but `src/main.zig` exposes no light-mode startup path, no CLI `--mode light` selection path, no config-file selection flow, and no public checkpoint selection flow; current code also treats `age == maxCheckpointAgeSeconds` as stale via `age < max_checkpoint_age`, which contradicts the settled contract that equality remains valid
- user-facing impact: current `HEAD` cannot start the documented light-mode runtime
- public-doc stance: document the full light-mode startup contract, state that baked network defaults participate in precedence without freezing exact literal default hashes as public contract, and mark current executable startup as a prototype gap
- maintainer-question needed: no

## C-012

- contradiction ID: `C-012`
- product surface: light-mode status, readiness, verified reads, and consensus-backed tag semantics
- PRD claim: light mode exposes `zevm_lightSyncStatus`, sets `ready = true` only when `status = "synced"` and ZEVM can serve proof-backed reads, exposes consensus-derived `safe` and `finalized`, and fails proof-backed core reads safely when ZEVM is not ready
- observed code reality: the repository contains consensus verification helpers, but no public status method, no proof-backed execution-read bridge, and no light-mode RPC routing for verified reads or not-ready errors; the current `SyncStatus` enum uses `err` rather than the intended `error` spelling, the available selector helpers collapse `pending`, `safe`, and `finalized` to the local head instead of a distinct light-mode selector model, and there is no live implementation of the settled bounded verified-history numeric-selector contract or its `-32011` versus `-32602` split
- user-facing impact: current `HEAD` cannot satisfy the documented light-mode RPC contract
- public-doc stance: keep the settled light-mode RPC contract intact and state clearly that current `HEAD` does not yet implement it, including the readiness-gated `eth_blockNumber` rule
- maintainer-question needed: no

## C-013

- contradiction ID: `C-013`
- product surface: upstream ownership and runtime composition boundary
- PRD claim: ZEVM must remain a thin integration shell and must not create a second canonical JSON-RPC method model or duplicate upstream state or EVM ownership
- observed code reality: ZEVM still carries a second local envelope or router or handler stack, runtime-critical modules such as `genesis` and block-query helpers are orphaned from startup, and the live path is coded against upstream APIs that no longer exist
- user-facing impact: docs must distinguish intended ownership from current repo drift so implementation work lands in the correct repo
- public-doc stance: document the intended ownership boundary exactly and call out the current duplicate-stack drift as an implementation contradiction
- maintainer-question needed: no
