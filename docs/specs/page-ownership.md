# Active Map: Mintlify Page Ownership, Anchors, and Verification

Last updated: 2026-03-30

## Status

This file is the active, non-normative traceability and maintenance map for public Mintlify docs.

It maps each current navigation page to:

1. owner-role routing (no personal-name assignments)
2. authoritative normative source docs
3. required normative section anchors
4. per-page verification status and dates
5. optional support docs

## Normative Boundary

Product behavior is normative only in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

If this map conflicts with normative docs, normative docs win.

## Scope

- In scope: pages listed in `mintlify/mint.json` navigation.
- Out of scope: merge authority, personnel assignment, and product behavior definition.
- This map is for maintenance routing and active source traceability only.
- Active redirect-first exception trackers (`contradiction-inventory.md`, `open-questions.md`) are non-normative blocker registries used for `pendingId` routing in `blocked` verification rows.
- Archival/history-only artifacts (`public-docs-sources.md`, `source-evidence-matrix.md`, `final-risk-report.md`) are not active planning or source-of-truth inputs.

## Verification Field Rules

Required per-page fields in the Active Page Map:

- `Normative anchors (required)`: explicit section anchors in `docs/specs/prd.md` and/or `docs/specs/json-rpc-contract.md`.
- `Verification status`: one of `verified`, `pending-review`, `blocked`.
- `Last content verified on`: ISO date (`YYYY-MM-DD`) or `_never_`.
- `Last nav reconciled on`: ISO date (`YYYY-MM-DD`) or `_never_`.

Status usage:

- `verified`: owner checked page coverage against declared normative anchors and current `mintlify/mint.json` tuple.
- `pending-review`: row exists but needs content and/or nav verification after a change.
- `blocked`: verification blocked by unresolved normative contradiction/question; row must reference active `pendingId` from `contradiction-inventory.md` or `open-questions.md` in `Verification notes`.

## Deterministic Nav Reconciliation Procedure (`mintlify/mint.json`)

1. Read `mintlify/mint.json` and flatten `navigation` into ordered `(Navigation group, Page)` tuples by list order.
2. Flatten the Active Page Map below into ordered `(Navigation group, Page)` tuples.
3. Validate both tuple lists:
- each page ID appears once (no duplicates)
- tuple counts are equal
- every tuple in `mintlify/mint.json` appears in this table with the same group label
- group ordering matches the current nav model: `Start`, `Specs & Policy`, `Quickstart`, `Concepts`, `Configuration Reference`, `JSON-RPC Reference`
- this table has no extra tuples not present in `mintlify/mint.json`
4. For each tuple, confirm required traceability fields are populated: owner role, authoritative source docs, normative anchors, verification status, and both verification dates.
5. If any mismatch exists, update this file in the same PR as the `mintlify/mint.json` change and set affected rows to `pending-review` (or `blocked` with active `pendingId` when applicable).
6. After reconciliation and anchor verification are complete, set affected rows to `verified` and set both date fields to the reconciliation date.

## Role Labels

- `Docs IA Owner`: owns page placement, grouping, and cross-link coherence.
- `Runtime/Mode Spec Owner`: owns runtime-mode semantics and behavior wording.
- `Configuration Spec Owner`: owns startup/configuration semantics and validation wording.
- `JSON-RPC Spec Owner`: owns method-level RPC contract wording and inventories.

## Update Policy

1. Update this file in the same PR when `mintlify/mint.json` navigation groups/pages change.
2. Update per-page normative anchors and verification fields in the same PR when normative docs change for affected topics.
3. When PRD or JSON-RPC contract semantics change (`docs/specs/prd.md` or `docs/specs/json-rpc-contract.md`), reconcile affected Mintlify pages plus this map and `docs/specs/mintlify-docs-plan.md` in the same PR.
4. Keep optional support-doc pointers only when they are still aligned; remove stale pointers until refreshed.
5. Use active redirect-first exception trackers (`contradiction-inventory.md`, `open-questions.md`) for unresolved contradiction/question routing only (`pendingId` linkage); keep them non-normative and do not duplicate active page-map tuples there.
6. Treat archival artifacts (`public-docs-sources.md`, `source-evidence-matrix.md`, `final-risk-report.md`) as history-only pointers.
7. Maintain explicit owner-role and update-expectation entries for every `docs/specs/internal/*` support doc used by active pages.

## Internal Dependency Maintenance Ownership

These internal docs are non-normative support dependencies for active Mintlify pages. Owners keep them aligned with normative sources and page usage.

| Internal support doc (`docs/specs/internal/*`) | Owner role label | Update expectation |
| --- | --- | --- |
| `phase-1-product-shape.md` | `Docs IA Owner` | Refresh in the same PR when PRD scope/framing changes or mapped pages (`index`, `reference/canonical-specs`, `reference/specs-and-process`, `reference/json-rpc/unsupported-and-deferred`) are updated. |
| `release-metadata-and-installation.md` | `Configuration Spec Owner` | Refresh in the same PR when installation/release-metadata semantics in `docs/specs/prd.md` change or mapped pages (`reference/release-metadata-runbook`, `quickstart/installation`) are updated. |
| `startup-and-configuration.md` | `Configuration Spec Owner` | Refresh in the same PR when startup/config semantics in `docs/specs/prd.md` change or mapped quickstart/config pages are updated. |
| `trusted-mode-semantics.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when trusted-mode semantics in `docs/specs/prd.md` change or mapped trusted-mode/RPC pages are updated. |
| `state-fork-and-snapshot-semantics.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when state-fork/snapshot semantics in `docs/specs/prd.md` change or mapped fork/snapshot pages are updated. |
| `light-mode-semantics.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when light-mode semantics in `docs/specs/prd.md` change or mapped light-mode pages are updated. |
| `runtime-modes-and-boundaries.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when runtime-mode boundaries in `docs/specs/prd.md` change or `concepts/runtime-modes` is updated. |
| `rpc-support-matrix.md` | `JSON-RPC Spec Owner` | Refresh in the same PR when method inventories/mode support in `docs/specs/json-rpc-contract.md` change or mapped JSON-RPC pages are updated. |
| `transport-and-error-semantics.md` | `JSON-RPC Spec Owner` | Refresh in the same PR when transport/error semantics in `docs/specs/json-rpc-contract.md` change or mapped troubleshooting/JSON-RPC pages are updated. |
| `upstream-ownership-and-boundaries.md` | `Docs IA Owner` | Refresh in the same PR when architecture/upstream ownership boundaries in `docs/specs/prd.md` change or `concepts/architecture-and-upstream-ownership` is updated. |

## Active Page Map

As of `2026-03-30`, all rows below are `verified` for both anchor coverage and nav reconciliation against `mintlify/mint.json`.

| Navigation group | Page | Owner role label | Authoritative normative source docs | Normative anchors (required) | Optional support docs | Verification status | Last content verified on | Last nav reconciled on | Verification notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Start | `index` | `Docs IA Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#1-purpose`; `docs/specs/prd.md#3-product-scope` | `docs/specs/internal/phase-1-product-shape.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Specs & Policy | `reference/canonical-specs` | `Docs IA Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#2-normative-documents`; `docs/specs/json-rpc-contract.md#zevm-json-rpc-contract` | `docs/specs/README.md` | `verified` | `2026-03-30` | `2026-03-30` | `Canonical-spec source index verified against specs index.` |
| Specs & Policy | `reference/specs-and-process` | `Docs IA Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#2-normative-documents`; `docs/specs/json-rpc-contract.md#zevm-json-rpc-contract` | `docs/specs/README.md`; `docs/specs/docs-first-process.md` | `verified` | `2026-03-30` | `2026-03-30` | `Docs-first process routing verified against canonical process docs.` |
| Specs & Policy | `reference/release-metadata-runbook` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#34-release-metadata-and-provenance-contract`; `docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria` | `docs/specs/internal/release-metadata-and-installation.md` | `verified` | `2026-03-30` | `2026-03-30` | `Dedicated release/install support-doc linkage in place.` |
| Quickstart | `quickstart/installation` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#33-phase-1-source-build-installation-contract` | `docs/specs/internal/release-metadata-and-installation.md` | `verified` | `2026-03-30` | `2026-03-30` | `Dedicated release/install support-doc linkage in place.` |
| Quickstart | `quickstart/run-trusted-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#52-trusted-mode-cli` | `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/startup-and-configuration.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Quickstart | `quickstart/forked-dev-node` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#52-trusted-mode-cli`; `docs/specs/prd.md#8-trusted-mode-mining-semantics`; `docs/specs/json-rpc-contract.md#94-zevm_reset-semantics` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/state-fork-and-snapshot-semantics.md`; `docs/specs/internal/trusted-mode-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Fork startup/config routing reconciled with trusted-mode CLI anchors.` |
| Quickstart | `quickstart/run-light-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#42-light-mode`; `docs/specs/prd.md#53-light-mode-cli`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics` | `docs/specs/internal/light-mode-semantics.md`; `docs/specs/internal/startup-and-configuration.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Quickstart | `quickstart/troubleshooting` | `Configuration Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#58-startup-failure-behavior`; `docs/specs/prd.md#59-startup-logging-surface`; `docs/specs/json-rpc-contract.md#5-errors` | `docs/specs/internal/transport-and-error-semantics.md`; `docs/specs/internal/startup-and-configuration.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Concepts | `concepts/runtime-modes` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#4-runtime-modes` | `docs/specs/internal/runtime-modes-and-boundaries.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Concepts | `concepts/trusted-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#8-trusted-mode-mining-semantics` | `docs/specs/internal/trusted-mode-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Concepts | `concepts/light-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#42-light-mode`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics` | `docs/specs/internal/light-mode-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Concepts | `concepts/method-support-by-mode` | `JSON-RPC Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#7-json-rpc-method-surface`; `docs/specs/json-rpc-contract.md#8-trusted-mode-standard-methods`; `docs/specs/json-rpc-contract.md#9-trusted-mode-zevm_-methods`; `docs/specs/json-rpc-contract.md#13-light-mode-methods`; `docs/specs/json-rpc-contract.md#14-unsupported-public-surface` | `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Concepts | `concepts/state-fork-and-snapshots` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics`; `docs/specs/json-rpc-contract.md#94-zevm_reset-semantics` | `docs/specs/internal/state-fork-and-snapshot-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Concepts | `concepts/architecture-and-upstream-ownership` | `Docs IA Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#12-architecture-and-ownership-boundaries` | `docs/specs/internal/upstream-ownership-and-boundaries.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Configuration Reference | `reference/configuration/overview` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#5-startup-and-configuration`; `docs/specs/prd.md#51-shared-cli`; `docs/specs/prd.md#54-config-file-schema`; `docs/specs/prd.md#55-precedence` | `docs/specs/internal/startup-and-configuration.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Configuration Reference | `reference/configuration/trusted-mode` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#52-trusted-mode-cli`; `docs/specs/prd.md#54-config-file-schema`; `docs/specs/prd.md#55-precedence` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/trusted-mode-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| Configuration Reference | `reference/configuration/light-mode` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#53-light-mode-cli`; `docs/specs/prd.md#54-config-file-schema`; `docs/specs/prd.md#55-precedence`; `docs/specs/prd.md#56-persisted-checkpoint-file-contract`; `docs/specs/prd.md#57-checkpoint-age-policy` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/light-mode-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/overview` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#1-common-types`; `docs/specs/json-rpc-contract.md#4-json-rpc-envelope`; `docs/specs/json-rpc-contract.md#5-errors`; `docs/specs/json-rpc-contract.md#6-selector-and-mode-semantics`; `docs/specs/prd.md#6-json-rpc-transport` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/transport-and-error-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/core-reads` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#81-core-reads`; `docs/specs/prd.md#7-json-rpc-method-surface` | `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/managed-dev-wallet` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#93-canonical-methods-and-accepted-aliases`; `docs/specs/json-rpc-contract.md#96-impersonation-semantics`; `docs/specs/prd.md#7-json-rpc-method-surface` | `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/simulation` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#82-simulation`; `docs/specs/json-rpc-contract.md#73-stateoverrideset`; `docs/specs/prd.md#7-json-rpc-method-surface` | `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/transactions-and-mining` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#83-submission`; `docs/specs/json-rpc-contract.md#10-trusted-mining-semantics`; `docs/specs/prd.md#8-trusted-mode-mining-semantics`; `docs/specs/prd.md#9-fee-model-and-transaction-types` | `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/blocks-receipts-and-logs` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#76-block-object`; `docs/specs/json-rpc-contract.md#77-receipt-object`; `docs/specs/json-rpc-contract.md#78-log-object`; `docs/specs/json-rpc-contract.md#79-logfilter-for-eth_getlogs`; `docs/specs/json-rpc-contract.md#84-queries` | `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/dev-controls` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#93-canonical-methods-and-accepted-aliases`; `docs/specs/json-rpc-contract.md#94-zevm_reset-semantics`; `docs/specs/json-rpc-contract.md#95-zevm_setrpcurl-semantics`; `docs/specs/json-rpc-contract.md#96-impersonation-semantics` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/state-fork-and-snapshot-semantics.md`; `docs/specs/internal/trusted-mode-semantics.md` | `verified` | `2026-03-30` | `2026-03-30` | `Dev-controls support-doc routing reconciled for fork/time/snapshot semantics.` |
| JSON-RPC Reference | `reference/json-rpc/verified-light-mode-reads` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#62-light-selectors-and-retained-history`; `docs/specs/json-rpc-contract.md#13-light-mode-methods`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics` | `docs/specs/internal/light-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
| JSON-RPC Reference | `reference/json-rpc/unsupported-and-deferred` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#12-deferred-trusted-helpers`; `docs/specs/json-rpc-contract.md#14-unsupported-public-surface`; `docs/specs/prd.md#32-out-of-scope` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/phase-1-product-shape.md` | `verified` | `2026-03-30` | `2026-03-30` | `Baseline reconciliation complete.` |
