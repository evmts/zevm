# Archived Issues and Audit Notes

Last updated: 2026-03-30

This directory contains historical issue tracking and audit artifacts.
All issue claims in this directory are filing-time observations and may contradict current contract docs.
When archive text and current contract docs differ, current contract docs win.

Scope of this directory:

- point-in-time gap reports from earlier implementation audits
- historical issue narratives, investigations, and backlog snapshots

Normative status:

- archival
- non-normative
- not part of the active product contract
- not a source of API or behavior requirements
- not a source of active ownership or traceability routing

Current normative product definition lives in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

Current non-normative support summaries live in:

- `docs/specs/internal/*` (explanatory, non-overriding)

Current active traceability authority lives in:

- `docs/specs/page-ownership.md` (active owner-role routing ledger, page-level verification status, and normative-anchor linkage)

Architecture/upstream boundary context support lives in:

- `docs/specs/internal/upstream-ownership-and-boundaries.md` (non-normative support context; not a traceability authority)

## Archive-To-Normative Trace Map

Use this table to map each archived issue narrative to the current authoritative contract sections.
If archive text and normative docs differ, the normative docs win.

Routing columns below are non-exhaustive context pointers only:

- `Active public-doc routing context` points to current Mintlify page IDs in `docs/specs/page-ownership.md`.
- `Active internal support-doc routing` points to current non-normative support docs used by active pages.

| Archived issue file | Authoritative PRD anchors | Authoritative JSON-RPC anchors | Active public-doc routing context (non-normative, page IDs) | Active internal support-doc routing (non-normative) | Maintainer-decision context (optional, non-normative) |
| --- | --- | --- | --- | --- | --- |
| [`001-runnable-dev-node-and-rpc-wiring.md`](./001-runnable-dev-node-and-rpc-wiring.md) | [`prd.md#4-runtime-modes`](../specs/prd.md#4-runtime-modes); [`prd.md#5-startup-and-configuration`](../specs/prd.md#5-startup-and-configuration); [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface) | [`json-rpc-contract.md#3-transport`](../specs/json-rpc-contract.md#3-transport); [`json-rpc-contract.md#8-trusted-mode-standard-methods`](../specs/json-rpc-contract.md#8-trusted-mode-standard-methods) | `quickstart/run-trusted-mode`; `reference/configuration/overview`; `reference/json-rpc/overview` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/runtime-modes-and-boundaries.md`; `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/transport-and-error-semantics.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-017` |
| [`002-core-eth-read-methods.md`](./002-core-eth-read-methods.md) | [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface); [`prd.md#9-fee-model-and-transaction-types`](../specs/prd.md#9-fee-model-and-transaction-types) | [`json-rpc-contract.md#81-core-reads`](../specs/json-rpc-contract.md#81-core-reads); [`json-rpc-contract.md#11-eth_feehistory-exact-behavior`](../specs/json-rpc-contract.md#11-eth_feehistory-exact-behavior); [`json-rpc-contract.md#6-selector-and-mode-semantics`](../specs/json-rpc-contract.md#6-selector-and-mode-semantics) | `reference/json-rpc/core-reads`; `concepts/method-support-by-mode` | `docs/specs/internal/rpc-support-matrix.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-005` |
| [`003-eth-call-and-estimate-gas.md`](./003-eth-call-and-estimate-gas.md) | [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface); [`prd.md#9-fee-model-and-transaction-types`](../specs/prd.md#9-fee-model-and-transaction-types) | [`json-rpc-contract.md#82-simulation`](../specs/json-rpc-contract.md#82-simulation); [`json-rpc-contract.md#73-stateoverrideset`](../specs/json-rpc-contract.md#73-stateoverrideset); [`json-rpc-contract.md#6-selector-and-mode-semantics`](../specs/json-rpc-contract.md#6-selector-and-mode-semantics) | `reference/json-rpc/simulation`; `concepts/method-support-by-mode` | `docs/specs/internal/rpc-support-matrix.md` | none |
| [`004-transaction-submission-and-mempool.md`](./004-transaction-submission-and-mempool.md) | [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface); [`prd.md#8-trusted-mode-mining-semantics`](../specs/prd.md#8-trusted-mode-mining-semantics); [`prd.md#9-fee-model-and-transaction-types`](../specs/prd.md#9-fee-model-and-transaction-types) | [`json-rpc-contract.md#83-submission`](../specs/json-rpc-contract.md#83-submission); [`json-rpc-contract.md#72-supported-transaction-envelope-types`](../specs/json-rpc-contract.md#72-supported-transaction-envelope-types); [`json-rpc-contract.md#101-pending-pool-and-inclusion`](../specs/json-rpc-contract.md#101-pending-pool-and-inclusion) | `reference/json-rpc/transactions-and-mining`; `concepts/trusted-mode` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/trusted-mode-semantics.md` | none |
| [`005-mining-modes.md`](./005-mining-modes.md) | [`prd.md#8-trusted-mode-mining-semantics`](../specs/prd.md#8-trusted-mode-mining-semantics); [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface) | [`json-rpc-contract.md#10-trusted-mining-semantics`](../specs/json-rpc-contract.md#10-trusted-mining-semantics); [`json-rpc-contract.md#93-canonical-methods-and-accepted-aliases`](../specs/json-rpc-contract.md#93-canonical-methods-and-accepted-aliases) | `concepts/trusted-mode`; `reference/json-rpc/transactions-and-mining`; `reference/json-rpc/dev-controls` | `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-012` |
| [`006-block-transaction-and-log-queries.md`](./006-block-transaction-and-log-queries.md) | [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface) | [`json-rpc-contract.md#84-queries`](../specs/json-rpc-contract.md#84-queries); [`json-rpc-contract.md#75-transaction-object`](../specs/json-rpc-contract.md#75-transaction-object); [`json-rpc-contract.md#76-block-object`](../specs/json-rpc-contract.md#76-block-object); [`json-rpc-contract.md#77-receipt-object`](../specs/json-rpc-contract.md#77-receipt-object); [`json-rpc-contract.md#78-log-object`](../specs/json-rpc-contract.md#78-log-object); [`json-rpc-contract.md#79-logfilter-for-eth_getlogs`](../specs/json-rpc-contract.md#79-logfilter-for-eth_getlogs) | `reference/json-rpc/blocks-receipts-and-logs` | `docs/specs/internal/rpc-support-matrix.md` | none |
| [`007-snapshots-and-state-manipulation.md`](./007-snapshots-and-state-manipulation.md) | [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface); [`prd.md#11-compatibility-namespace-policy`](../specs/prd.md#11-compatibility-namespace-policy) | [`json-rpc-contract.md#9-trusted-mode-zevm_-methods`](../specs/json-rpc-contract.md#9-trusted-mode-zevm_-methods); [`json-rpc-contract.md#94-zevm_reset-semantics`](../specs/json-rpc-contract.md#94-zevm_reset-semantics) | `concepts/state-fork-and-snapshots`; `reference/json-rpc/dev-controls` | `docs/specs/internal/state-fork-and-snapshot-semantics.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-015` |
| [`008-forking-impersonation-and-time-controls.md`](./008-forking-impersonation-and-time-controls.md) | [`prd.md#52-trusted-mode-cli`](../specs/prd.md#52-trusted-mode-cli); [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface); [`prd.md#8-trusted-mode-mining-semantics`](../specs/prd.md#8-trusted-mode-mining-semantics) | [`json-rpc-contract.md#95-zevm_setrpcurl-semantics`](../specs/json-rpc-contract.md#95-zevm_setrpcurl-semantics); [`json-rpc-contract.md#96-impersonation-semantics`](../specs/json-rpc-contract.md#96-impersonation-semantics); [`json-rpc-contract.md#104-timestamp-progression`](../specs/json-rpc-contract.md#104-timestamp-progression) | `quickstart/forked-dev-node`; `reference/json-rpc/dev-controls`; `reference/json-rpc/managed-dev-wallet` | `docs/specs/internal/state-fork-and-snapshot-semantics.md`; `docs/specs/internal/trusted-mode-semantics.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-002` |
| [`009-debug-tracing-filters-and-subscriptions.md`](./009-debug-tracing-filters-and-subscriptions.md) | [`prd.md#31-in-scope`](../specs/prd.md#31-in-scope); [`prd.md#32-out-of-scope`](../specs/prd.md#32-out-of-scope); [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface) | [`json-rpc-contract.md#12-deferred-trusted-helpers`](../specs/json-rpc-contract.md#12-deferred-trusted-helpers); [`json-rpc-contract.md#14-unsupported-public-surface`](../specs/json-rpc-contract.md#14-unsupported-public-surface) | `reference/json-rpc/unsupported-and-deferred` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/phase-1-product-shape.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-010` |
| [`010-light-client-mode-and-proof-verified-reads.md`](./010-light-client-mode-and-proof-verified-reads.md) | [`prd.md#42-light-mode`](../specs/prd.md#42-light-mode); [`prd.md#53-light-mode-cli`](../specs/prd.md#53-light-mode-cli); [`prd.md#56-persisted-checkpoint-file-contract`](../specs/prd.md#56-persisted-checkpoint-file-contract); [`prd.md#57-checkpoint-age-policy`](../specs/prd.md#57-checkpoint-age-policy); [`prd.md#10-light-mode-checkpoint-and-history-semantics`](../specs/prd.md#10-light-mode-checkpoint-and-history-semantics) | [`json-rpc-contract.md#62-light-selectors-and-retained-history`](../specs/json-rpc-contract.md#62-light-selectors-and-retained-history); [`json-rpc-contract.md#710-light-sync-status-object`](../specs/json-rpc-contract.md#710-light-sync-status-object); [`json-rpc-contract.md#13-light-mode-methods`](../specs/json-rpc-contract.md#13-light-mode-methods) | `quickstart/run-light-mode`; `concepts/light-mode`; `reference/json-rpc/verified-light-mode-reads` | `docs/specs/internal/light-mode-semantics.md`; `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/rpc-support-matrix.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-007`, `DEC-008`, `DEC-009`, `DEC-019`, `DEC-021` |
| [`011-build-and-test-coverage.md`](./011-build-and-test-coverage.md) | [`prd.md#33-phase-1-source-build-installation-contract`](../specs/prd.md#33-phase-1-source-build-installation-contract); [`prd.md#35-release-qualification-and-verification-acceptance-criteria`](../specs/prd.md#35-release-qualification-and-verification-acceptance-criteria) | none (PRD-only operational contract) | `quickstart/installation`; `reference/release-metadata-runbook` | `docs/specs/internal/release-metadata-and-installation.md`; `docs/specs/internal/phase-1-product-shape.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-011`, `DEC-025` |
| [`012-block-state-root-and-context-integrity.md`](./012-block-state-root-and-context-integrity.md) | [`prd.md#8-trusted-mode-mining-semantics`](../specs/prd.md#8-trusted-mode-mining-semantics); [`prd.md#12-architecture-and-ownership-boundaries`](../specs/prd.md#12-architecture-and-ownership-boundaries) | [`json-rpc-contract.md#76-block-object`](../specs/json-rpc-contract.md#76-block-object); [`json-rpc-contract.md#77-receipt-object`](../specs/json-rpc-contract.md#77-receipt-object); [`json-rpc-contract.md#10-trusted-mining-semantics`](../specs/json-rpc-contract.md#10-trusted-mining-semantics) | `reference/json-rpc/blocks-receipts-and-logs`; `concepts/trusted-mode` | `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md` | none |
| [`013-upstream-api-alignment-and-ownership.md`](./013-upstream-api-alignment-and-ownership.md) | [`prd.md#6-json-rpc-transport`](../specs/prd.md#6-json-rpc-transport); [`prd.md#7-json-rpc-method-surface`](../specs/prd.md#7-json-rpc-method-surface); [`prd.md#12-architecture-and-ownership-boundaries`](../specs/prd.md#12-architecture-and-ownership-boundaries) | [`json-rpc-contract.md#3-transport`](../specs/json-rpc-contract.md#3-transport); [`json-rpc-contract.md#4-json-rpc-envelope`](../specs/json-rpc-contract.md#4-json-rpc-envelope) | `concepts/architecture-and-upstream-ownership`; `reference/json-rpc/overview` | `docs/specs/internal/upstream-ownership-and-boundaries.md`; `docs/specs/internal/transport-and-error-semantics.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-003`, `DEC-017` |
| [`014-json-rpc-transport-compliance.md`](./014-json-rpc-transport-compliance.md) | [`prd.md#6-json-rpc-transport`](../specs/prd.md#6-json-rpc-transport) | [`json-rpc-contract.md#3-transport`](../specs/json-rpc-contract.md#3-transport); [`json-rpc-contract.md#4-json-rpc-envelope`](../specs/json-rpc-contract.md#4-json-rpc-envelope); [`json-rpc-contract.md#5-errors`](../specs/json-rpc-contract.md#5-errors) | `reference/json-rpc/overview`; `quickstart/troubleshooting` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/transport-and-error-semantics.md` | [`maintainer-decisions.md`](../specs/maintainer-decisions.md): `DEC-003`, `DEC-004`, `DEC-023` |

## Usage Rule

This map is an indexing aid only.
It does not create, extend, or override requirements.
It must not be used as ownership-routing or traceability authority.
