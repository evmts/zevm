# ZEVM Contradiction Inventory

Last updated: 2026-03-21

## C-001

- contradiction ID: `C-001`
- product surface: startup and configuration surface
- intended contract: ZEVM starts as one binary, defaults to trusted mode, accepts the documented shared and mode-specific flags, and validates invalid combinations before listening.
- observed repo reality: `src/main.zig` only parses `--host` and `--port` through `src/rpc/server.zig`. No config file, mode selector, or mode-specific startup validation is wired.
- user-facing impact: current `HEAD` cannot be documented as implementing the intended startup contract.
- public-doc stance: document the full intended startup/config contract and explicitly mark `HEAD` as not yet exposing it.
- maintainer input required: no

## C-002

- contradiction ID: `C-002`
- product surface: HTTP JSON-RPC transport and notifications
- intended contract: ZEVM ships one canonical HTTP JSON-RPC 2.0 transport, and requests with no `id` produce no response.
- observed repo reality: the executable transport direction in `src/rpc/server.zig` still depends on a broken upstream `jsonrpc.envelope` path, the older `src/rpc/envelope.zig` plus `src/rpc/router.zig` stack remains in-tree, and both paths serialize responses for notification-shaped requests.
- user-facing impact: `HEAD` does not satisfy the documented transport or notification contract.
- public-doc stance: document the intended contract exactly and call the current notification behavior a bug.
- maintainer input required: no

## C-003

- contradiction ID: `C-003`
- product surface: trusted-mode read methods
- intended contract: trusted mode exposes the documented read set, including correct code reads.
- observed repo reality: minimal helper coverage exists, richer handlers are unwired, and `eth_getCode` currently returns `"0x"` instead of real stored code.
- user-facing impact: public docs cannot treat current `HEAD` as a correct trusted-read implementation.
- public-doc stance: keep the intended read contract intact and call out the specific `eth_getCode` mismatch.
- maintainer input required: no

## C-004

- contradiction ID: `C-004`
- product surface: trusted-mode execution simulation
- intended contract: trusted mode supports `eth_call` and `eth_estimateGas` with checkpoint-and-revert semantics and state overrides.
- observed repo reality: no implementation or tests for `eth_call` or `eth_estimateGas` were found in `src/` on 2026-03-21.
- user-facing impact: `HEAD` does not currently implement the documented simulation surface.
- public-doc stance: describe the intended simulation contract and state plainly that it is not yet implemented.
- maintainer input required: no

## C-005

- contradiction ID: `C-005`
- product surface: transaction submission and mining
- intended contract: trusted mode supports transaction submission, nonce-aware pending state, and automine/manual/interval mining.
- observed repo reality: `src/rpc/handlers/tx_submission.zig` and its tests rely on runtime fields that do not exist in `src/node/runtime.zig`, and mining coordination is disconnected from startup/runtime.
- user-facing impact: `HEAD` does not provide a working submission or mining runtime.
- public-doc stance: document the full intended submission/mining contract and mark the current code as disconnected prototype coverage.
- maintainer input required: no

## C-006

- contradiction ID: `C-006`
- product surface: canonical block, receipt, log, and transaction queries
- intended contract: trusted mode exposes canonical block, receipt, log, and transaction query methods with complete response data.
- observed repo reality: query helpers are unwired, some block and log response fields are placeholder-filled or dropped, and `eth_getTransactionByHash` remains a stub.
- user-facing impact: current query output cannot be described as the intended public contract.
- public-doc stance: document the full query contract and keep the placeholder/stub reality explicit.
- maintainer input required: no

## C-007

- contradiction ID: `C-007`
- product surface: deterministic managed-account set
- intended contract: trusted mode exposes one exact public managed-wallet contract: mnemonic `test test test test test test test test test test test junk`, derivation path root `m/44'/60'/0'/0/`, indices `0..9`, and the published address/private-key table in the PRD and trusted-mode docs.
- observed repo reality: `src/node/runtime.zig` hardcodes most canonical addresses but omits the private-key table and hardcodes a different account `#7`; `src/genesis.zig` hardcodes a different account `#7` and a conflicting private-key table; `src/rpc/handlers/tx_submission_test.zig` expects a runtime private-key table that `src/node/runtime.zig` does not define.
- user-facing impact: current `HEAD` does not implement the now-settled exact managed-wallet contract.
- public-doc stance: document the exact mnemonic, derivation path, address order, and private-key table as the contract, and call the current repo mismatch explicit.
- maintainer input required: no

## C-008

- contradiction ID: `C-008`
- product surface: snapshot and dev controls
- intended contract: trusted mode includes the documented snapshot boundary, state mutation methods, impersonation, and time controls.
- observed repo reality: snapshot/revert prototypes are narrower than the intended contract, some state-mutation handlers exist, and impersonation/time controls were not found.
- user-facing impact: `HEAD` does not currently implement the full documented dev-control surface.
- public-doc stance: enumerate the full intended method set and call out the current missing groups explicitly.
- maintainer input required: no

## C-009

- contradiction ID: `C-009`
- product surface: trusted-mode fork startup
- intended contract: fork startup is configuration inside trusted mode and layers local writes over remote fork-backed reads.
- observed repo reality: `src/node/runtime.zig` still initializes `StateManager` with `null`, and no executable startup path wires fork input.
- user-facing impact: `HEAD` cannot currently start the documented fork-backed trusted mode.
- public-doc stance: document fork semantics as intended behavior and state that startup integration is still missing.
- maintainer input required: no

## C-010

- contradiction ID: `C-010`
- product surface: current build/test baseline
- intended contract: public docs describe the product contract while keeping current repo state accurate and dated.
- observed repo reality: `zig build test` is still failing on 2026-03-21, including the broken upstream `jsonrpc.envelope` references and other build drift.
- user-facing impact: docs must not present `HEAD` as a runnable implementation baseline.
- public-doc stance: keep dated current-state caveats in public docs and treat them as implementation evidence only.
- maintainer input required: no

## C-011

- contradiction ID: `C-011`
- product surface: light-mode startup and checkpoint selection
- intended contract: light mode exposes exact startup/config fields, baked network defaults, persisted checkpoint behavior, and explicit checkpoint precedence.
- observed repo reality: the consensus substrate exists, but there is no public startup dispatcher or runtime path that exposes the light-mode startup contract.
- user-facing impact: `HEAD` cannot currently start the documented light-mode runtime.
- public-doc stance: document the full light-mode startup contract and keep the executable gap explicit.
- maintainer input required: no

## C-012

- contradiction ID: `C-012`
- product surface: light-mode status and proof-backed reads
- intended contract: light mode exposes `zevm_lightSyncStatus`, real consensus-backed `safe` and `finalized` semantics, and proof-backed core reads.
- observed repo reality: no public status method is wired, no proof-backed execution-read bridge exists, and no light-mode query bridge exposes the documented tag semantics.
- user-facing impact: `HEAD` cannot currently satisfy the documented light-mode RPC contract.
- public-doc stance: keep the full light-mode RPC contract intact and state clearly that current `HEAD` does not yet implement it.
- maintainer input required: no
