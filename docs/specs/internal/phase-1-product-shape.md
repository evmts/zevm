# ZEVM Internal Support: Phase 1 Product Shape

Last updated: 2026-03-30

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

Non-normative summary of `docs/specs/prd.md` section 3.3:

- phase-1 installation contract is source-build only
- canonical build command is `zig build`
- minimum Zig version is `0.15.2`
- required sibling dependencies are `../voltaire` and `../guillotine-mini`
- reproducibility pin tuple is `(zevmGitRevision, voltaireGitRevision, guillotineMiniGitRevision, zigVersion)`
- release metadata uses canonical `releaseIdentifier` naming: tag-based `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`; commit-based `^commit-[0-9a-f]{40}$`
- each ZEVM `releaseIdentifier` publishes immutable tuple/checkpoint metadata assets at canonical URLs: `https://github.com/evmts/zevm/releases/download/<releaseIdentifier>/release-tuple.json` and `.../light-default-checkpoints.json`
- metadata-backed reproducibility applies only when both required metadata assets are present exactly once and satisfy PRD 3.4 schema/value invariants
- canonical publication claims require a publication-time CI/release gate that validates both required artifacts (`release-tuple.json`, `light-default-checkpoints.json`) from published release assets against PRD 3.4 requirements
- publication-time gate failure on either required artifact (missing/duplicate/unreadable/malformed/schema-mismatched/value-mismatched) blocks canonical publication claims for that `releaseIdentifier`
- missing/malformed/mismatched/duplicate release metadata assets make that published `releaseIdentifier` metadata-invalid for reproducibility; correction requires a new superseding `releaseIdentifier`
- tuple corrections are append-only: publish a new `releaseIdentifier` with new metadata assets and one release-notes supersession note under `## ZEVM Supersession Note`; do not mutate prior assets
- phase-1 source-build provenance has two states only: metadata-backed published-release provenance or operator-recorded source provenance
- metadata-backed operator flow is strict: select one `releaseIdentifier`, fetch/validate required assets for that identifier, materialize tuple-pinned commits/toolchain, then build
- operator-recorded source provenance covers unreleased commits and metadata-invalid published identifiers; operators self-record tuple pins from local state and must not claim metadata-backed reproducibility
- operator verification path is: materialize pinned commits for `.` / `../voltaire` / `../guillotine-mini`, verify each with `git rev-parse HEAD`, and verify `zig version` equals the tuple `zigVersion`
- runtime/CLI does not expose or repair `releaseIdentifier` metadata state; release identity/provenance remains an operator workflow
- packaged binaries, installers, and package-manager distribution channels are explicitly out of scope in phase 1

## 4. Release Qualification And Verification (PRD 3.5 Summary)

- clean-checkout qualification requires `zig build` and `zig build test` success for pinned ZEVM/Voltaire/`guillotine-mini` commits without manual sibling repair or ad-hoc dependency edits
- shipped phase-1 surface means any normative phase-1 behavior requirement in PRD sections 3.1, 3.3, 3.4, and 4 through 12, excluding section 3.2 out-of-scope items
- assertion mapping records are structured qualification entries and include, at minimum: `surfaceId`, `surfaceSection`, `surfaceCategory` (`startup`, `configuration`, `runtime`, `transport`, `method`, `release-asset`, `release-provenance`, `supersession-note`), `assertionType` (`default-graph-test`, `release-asset-validation`, `release-provenance-validation`, `supersession-note-validation`), `assertionIdentifier`, and expected contract outcome
- default `zig build test` must cover shipped executable startup/configuration/runtime/transport/method behaviors in PRD sections 3.1 and 4 through 12; anything outside the default graph must be explicitly treated as non-shipping
- qualification coverage is actionable only when mapping rows explicitly cover startup/configuration semantics (PRD section 5), runtime/lifecycle semantics (sections 4, 8, 9, 10, 11, 12), transport semantics (section 6), method tuple/error semantics (section 7 + JSON-RPC contract), release-asset semantics (sections 3.3 and 3.4), and section-3.4 release-provenance/supersession-note semantics
- method-family mappings must include concrete assertions for the normative success/unsupported/readiness/error behaviors in scope
- when qualification claims a published `releaseIdentifier` under metadata-backed reproducibility, qualification must validate both required release artifacts and all PRD section 3.4 field/schema/value invariants; any artifact conformance failure disqualifies that claim
- metadata-backed qualification records include explicit release-asset mapping rows for both required artifacts, including URL/identifier binding, schema-field conformance, and cross-field equality checks
- metadata-backed qualification records include explicit `release-provenance` and `supersession-note` mapping rows for PRD section 3.4 operator-flow and correction-release-note invariants when those surfaces apply
- qualification includes real listener-socket smoke coverage for trusted runtime startup/request flow and light startup plus restart/resume from persisted checkpoint input path
- light startup checkpoint precedence is absence-driven (`CLI > config > persisted > baked default`); once a checkpoint source is selected, selected-source validation/derivation failure is startup-terminal before listener bind with no fallback to lower-precedence sources
- persisted checkpoint lifecycle is operator-managed: ZEVM reads `${resolvedCheckpointDir}/checkpoint` at startup precedence only, does not auto-seed/write it from runtime state, and re-evaluates it on each restart
- qualification verifies notification-only HTTP `204` semantics and one canonical ZEVM-owned shipping transport/parser stack

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
