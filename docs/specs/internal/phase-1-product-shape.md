# ZEVM Internal Support: Phase 1 Product Shape

Last updated: 2026-03-31

This page is non-normative support for:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

Use those normative docs for exact startup behavior, method tuples, and error contract.

## 1. Phase 1 Scope

Phase 1 is the trusted-mode-first ZEVM release shape:

- one binary: `zevm`
- startup/configuration surface for trusted and light runtime selection
- HTTP JSON-RPC transport
- complete trusted-mode dev-node RPC contract (standard methods plus canonical `zevm_*` controls and documented accepted aliases)
- limited light-mode read surface is in scope now (`zevm_lightSyncStatus`, `eth_chainId`, `eth_blockNumber`, `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount`)

Forking remains trusted-mode configuration, not a third runtime mode.

## 2. Runtime Boundary Across Phases

- trusted mode is the writable local dev-node runtime and is the phase-1 primary runtime surface
- light mode is part of phase-1 scope through the limited proof-backed read surface
- phase sequencing remains trusted-first, with expanded light-mode features delivered in later phases while deferred surfaces stay out of scope

## 3. Phase-1 Source-Build Installation (PRD 3.3 Summary)

Keep the install/release boundary short here so this page stays about product shape:

- phase-1 installation contract is source-build only
- ZEVM ships one `zevm` binary built from this repository with sibling dependencies at `../voltaire` and `../guillotine-mini`
- metadata-backed release reproducibility, append-only correction rules, and qualification acceptance criteria are defined in PRD sections 3.3 through 3.5
- public onboarding pages should treat release-metadata provenance as an optional deeper path; default installation guidance should stay focused on the source-build flow
- packaged binaries, installers, and package-manager distribution channels remain out of scope in phase 1

## 4. Release Qualification And Verification (PRD 3.5 Summary)

Qualification is still part of phase shape, but the canonical detail remains in the PRD:

- shipped phase-1 surface means the trusted-mode-first runtime, source-build contract, transport, and method families defined in PRD sections 3.1, 3.3, 3.4, and 4 through 12
- qualification requires clean-checkout source builds plus default `zig build test` coverage for shipped startup/configuration/runtime/transport/method behavior
- metadata-backed candidates additionally require release-asset, release-provenance, and supersession-note validation for the selected `releaseIdentifier`
- listener/socket smoke coverage and HTTP `204` notification behavior remain part of the phase-1 release bar
- use `docs/specs/internal/release-metadata-and-installation.md` for condensed install/provenance support and the PRD for exact qualification assertions

## 5. Phase 1 Public Capabilities (Summary)

Phase-1 trusted-mode summary includes:

- core reads and fee reads
- simulation (`eth_call`, `eth_estimateGas`)
- transaction submission (`eth_sendTransaction`, `eth_sendRawTransaction`)
- mining controls and timestamp controls
- canonical block/transaction/receipt/log query methods (including `eth_getLogs`)
- trusted state mutation, snapshot/revert, impersonation, and fork-source controls via canonical `zevm_*` methods

Exact inventory, params, return payloads, and alias mapping are defined in `docs/specs/json-rpc-contract.md`.

## 6. Out-Of-Scope Surfaces For Phase 1

- WebSocket transport and subscriptions
- filter lifecycle APIs beyond `eth_getLogs`
- debug tracing APIs
- proof-backed `eth_call` in light mode
- `eth_estimateGas` in light mode
- `eth_feeHistory` and canonical block/receipt/log queries in light mode
- expanded light-mode features beyond the phase-1 read subset
- packaged binary distribution and installer/distribution-channel guarantees

This support summary mirrors `docs/specs/prd.md` section 3.2.

## 7. Precedence

If this support summary differs from normative docs:

1. `docs/specs/prd.md` defines product scope and phase boundaries.
2. `docs/specs/json-rpc-contract.md` defines exact JSON-RPC API behavior.
