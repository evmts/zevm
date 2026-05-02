# Mintlify Page Ownership and Anchors

## Status

This file is the non-normative traceability map for public Mintlify docs.

It maps each current navigation page to:

1. owner-role routing (no personal-name assignments)
2. authoritative normative source docs
3. required normative section anchors
4. optional internal support docs

## Normative Boundary

Product behavior is normative only in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

If this map conflicts with normative docs, normative docs win.

## Scope

- In scope: pages listed in `docs/mint.json` navigation.
- Out of scope: merge authority, personnel assignment, and product behavior definition.
- This map is for maintenance routing and source traceability only.

## Nav Reconciliation Procedure (`docs/mint.json`)

1. Read `docs/mint.json` and flatten `navigation` into ordered `(Navigation group, Page)` tuples by list order.
2. Flatten the Page Map below into ordered `(Navigation group, Page)` tuples.
3. Validate both tuple lists:
- each page ID appears once (no duplicates)
- tuple counts are equal
- every tuple in `docs/mint.json` appears in this table with the same group label
- this table has no extra tuples not present in `docs/mint.json`
4. For each tuple, confirm required traceability fields are populated: owner role, authoritative source docs, and normative anchors.
5. If any mismatch exists, update this file in the same PR as the `docs/mint.json` change.

## Role Labels

- `Docs IA Owner`: owns page placement, grouping, and cross-link coherence.
- `Runtime/Mode Spec Owner`: owns runtime-mode semantics and behavior wording.
- `Configuration Spec Owner`: owns startup/configuration semantics and validation wording.
- `JSON-RPC Spec Owner`: owns method-level RPC contract wording and inventories.

## Update Policy

1. Update this file in the same PR when `docs/mint.json` navigation groups/pages change.
2. Update per-page normative anchors in the same PR when normative docs change for affected topics.
3. When PRD or JSON-RPC contract semantics change (`docs/specs/prd.md` or `docs/specs/json-rpc-contract.md`), reconcile affected Mintlify pages plus this map and `docs/specs/mintlify-docs-plan.md` in the same PR.
4. Keep optional internal support-doc pointers only when they are still aligned; remove stale pointers until refreshed.
5. Maintain explicit owner-role and update-expectation entries for every `docs/specs/internal/*` support doc used by active pages.

## Internal Dependency Maintenance Ownership

These internal docs are non-normative support dependencies for active Mintlify pages. Owners keep them aligned with normative sources and page usage.

| Internal support doc (`docs/specs/internal/*`) | Owner role label | Update expectation |
| --- | --- | --- |
| `phase-1-product-shape.md` | `Docs IA Owner` | Refresh in the same PR when PRD scope/framing changes or mapped pages (`index`, `reference/canonical-specs`, `reference/specs-and-process`, `reference/json-rpc/unsupported-and-deferred`) are updated. |
| `startup-and-configuration.md` | `Configuration Spec Owner` | Refresh in the same PR when startup/config semantics in `docs/specs/prd.md` change or mapped quickstart/config pages are updated. |
| `trusted-mode-semantics.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when trusted-mode semantics in `docs/specs/prd.md` change or mapped trusted-mode/RPC pages are updated. |
| `state-fork-and-snapshot-semantics.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when state-fork/snapshot semantics in `docs/specs/prd.md` change or mapped fork/snapshot pages are updated. |
| `light-mode-semantics.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when light-mode semantics in `docs/specs/prd.md` change or mapped light-mode pages are updated. |
| `runtime-modes-and-boundaries.md` | `Runtime/Mode Spec Owner` | Refresh in the same PR when runtime-mode boundaries in `docs/specs/prd.md` change or `concepts/runtime-modes` is updated. |
| `rpc-support-matrix.md` | `JSON-RPC Spec Owner` | Refresh in the same PR when method inventories/mode support in `docs/specs/json-rpc-contract.md` change or mapped JSON-RPC pages are updated. |
| `transport-and-error-semantics.md` | `JSON-RPC Spec Owner` | Refresh in the same PR when transport/error semantics in `docs/specs/json-rpc-contract.md` change or mapped troubleshooting/JSON-RPC pages are updated. |
| `upstream-ownership-and-boundaries.md` | `Docs IA Owner` | Refresh in the same PR when architecture/upstream ownership boundaries in `docs/specs/prd.md` change or `concepts/architecture-and-upstream-ownership` is updated. |

## Page Map

| Navigation group | Page | Owner role label | Authoritative normative source docs | Normative anchors (required) | Optional internal support docs |
| --- | --- | --- | --- | --- | --- |
| Overview | `index` | `Docs IA Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#1-purpose`; `docs/specs/prd.md#3-product-scope` | `docs/specs/internal/phase-1-product-shape.md` |
| Overview | `reference/canonical-specs` | `Docs IA Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#2-normative-documents`; `docs/specs/json-rpc-contract.md#zevm-json-rpc-contract` | `docs/specs/internal/phase-1-product-shape.md` |
| Overview | `reference/specs-and-process` | `Docs IA Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#2-normative-documents`; `docs/specs/json-rpc-contract.md#zevm-json-rpc-contract` | `docs/specs/internal/phase-1-product-shape.md` |
| Overview | `reference/release-metadata-runbook` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#34-release-metadata-and-provenance-contract`; `docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria` | `docs/specs/internal/startup-and-configuration.md` |
| Overview | `reference/ci-and-release-gates` | `Docs IA Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria`; `docs/specs/prd.md#12-architecture-and-ownership-boundaries` | `docs/specs/internal/phase-1-product-shape.md`; `docs/specs/internal/transport-and-error-semantics.md` |
| Quickstart | `quickstart/installation` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#33-phase-1-source-build-installation-contract` | `docs/specs/internal/startup-and-configuration.md` |
| Quickstart | `quickstart/run-trusted-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#52-trusted-mode-cli` | `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/startup-and-configuration.md` |
| Quickstart | `quickstart/forked-dev-node` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#8-trusted-mode-mining-semantics`; `docs/specs/json-rpc-contract.md#94-zevm_reset-semantics` | `docs/specs/internal/state-fork-and-snapshot-semantics.md`; `docs/specs/internal/trusted-mode-semantics.md` |
| Quickstart | `quickstart/run-light-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#42-light-mode`; `docs/specs/prd.md#53-light-mode-cli`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics` | `docs/specs/internal/light-mode-semantics.md`; `docs/specs/internal/startup-and-configuration.md` |
| Quickstart | `quickstart/troubleshooting` | `Configuration Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#58-startup-failure-behavior`; `docs/specs/prd.md#59-startup-logging-surface`; `docs/specs/json-rpc-contract.md#5-errors` | `docs/specs/internal/transport-and-error-semantics.md`; `docs/specs/internal/startup-and-configuration.md` |
| Concepts | `concepts/runtime-modes` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#4-runtime-modes` | `docs/specs/internal/runtime-modes-and-boundaries.md` |
| Concepts | `concepts/trusted-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#8-trusted-mode-mining-semantics` | `docs/specs/internal/trusted-mode-semantics.md` |
| Concepts | `concepts/light-mode` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#42-light-mode`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics` | `docs/specs/internal/light-mode-semantics.md` |
| Concepts | `concepts/state-fork-and-snapshots` | `Runtime/Mode Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#41-trusted-mode`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics`; `docs/specs/json-rpc-contract.md#94-zevm_reset-semantics` | `docs/specs/internal/state-fork-and-snapshot-semantics.md` |
| Concepts | `concepts/method-support-by-mode` | `JSON-RPC Spec Owner` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | `docs/specs/prd.md#7-json-rpc-method-surface`; `docs/specs/json-rpc-contract.md#8-trusted-mode-standard-methods`; `docs/specs/json-rpc-contract.md#9-trusted-mode-zevm_-methods`; `docs/specs/json-rpc-contract.md#13-light-mode-methods`; `docs/specs/json-rpc-contract.md#14-unsupported-public-surface` | `docs/specs/internal/rpc-support-matrix.md` |
| Concepts | `concepts/architecture-and-upstream-ownership` | `Docs IA Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#12-architecture-and-ownership-boundaries` | `docs/specs/internal/upstream-ownership-and-boundaries.md` |
| Configuration Reference | `reference/configuration/overview` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#5-startup-and-configuration`; `docs/specs/prd.md#51-shared-cli`; `docs/specs/prd.md#54-config-file-schema`; `docs/specs/prd.md#55-precedence` | `docs/specs/internal/startup-and-configuration.md` |
| Configuration Reference | `reference/configuration/trusted-mode` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#52-trusted-mode-cli`; `docs/specs/prd.md#54-config-file-schema`; `docs/specs/prd.md#55-precedence` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/trusted-mode-semantics.md` |
| Configuration Reference | `reference/configuration/light-mode` | `Configuration Spec Owner` | `docs/specs/prd.md` | `docs/specs/prd.md#53-light-mode-cli`; `docs/specs/prd.md#54-config-file-schema`; `docs/specs/prd.md#55-precedence`; `docs/specs/prd.md#56-persisted-checkpoint-file-contract`; `docs/specs/prd.md#57-checkpoint-age-policy` | `docs/specs/internal/startup-and-configuration.md`; `docs/specs/internal/light-mode-semantics.md` |
| JSON-RPC Reference | `reference/json-rpc/overview` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#1-common-types`; `docs/specs/json-rpc-contract.md#4-json-rpc-envelope`; `docs/specs/json-rpc-contract.md#5-errors`; `docs/specs/json-rpc-contract.md#6-selector-and-mode-semantics`; `docs/specs/prd.md#6-json-rpc-transport` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/transport-and-error-semantics.md` |
| JSON-RPC Reference | `reference/json-rpc/core-reads` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#81-core-reads`; `docs/specs/prd.md#7-json-rpc-method-surface` | `docs/specs/internal/rpc-support-matrix.md` |
| JSON-RPC Reference | `reference/json-rpc/managed-dev-wallet` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#93-canonical-methods-and-accepted-aliases`; `docs/specs/json-rpc-contract.md#96-impersonation-semantics`; `docs/specs/prd.md#7-json-rpc-method-surface` | `docs/specs/internal/trusted-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md` |
| JSON-RPC Reference | `reference/json-rpc/simulation` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#82-simulation`; `docs/specs/json-rpc-contract.md#73-stateoverrideset`; `docs/specs/prd.md#7-json-rpc-method-surface` | `docs/specs/internal/rpc-support-matrix.md` |
| JSON-RPC Reference | `reference/json-rpc/transactions-and-mining` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#83-submission`; `docs/specs/json-rpc-contract.md#10-trusted-mining-semantics`; `docs/specs/prd.md#8-trusted-mode-mining-semantics`; `docs/specs/prd.md#9-fee-model-and-transaction-types` | `docs/specs/internal/rpc-support-matrix.md` |
| JSON-RPC Reference | `reference/json-rpc/blocks-receipts-and-logs` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#76-block-object`; `docs/specs/json-rpc-contract.md#77-receipt-object`; `docs/specs/json-rpc-contract.md#78-log-object`; `docs/specs/json-rpc-contract.md#79-logfilter-for-eth_getlogs`; `docs/specs/json-rpc-contract.md#84-queries` | `docs/specs/internal/rpc-support-matrix.md` |
| JSON-RPC Reference | `reference/json-rpc/dev-controls` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#93-canonical-methods-and-accepted-aliases`; `docs/specs/json-rpc-contract.md#94-zevm_reset-semantics`; `docs/specs/json-rpc-contract.md#95-zevm_setrpcurl-semantics`; `docs/specs/json-rpc-contract.md#96-impersonation-semantics` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/trusted-mode-semantics.md` |
| JSON-RPC Reference | `reference/json-rpc/verified-light-mode-reads` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#62-light-selectors-and-retained-history`; `docs/specs/json-rpc-contract.md#13-light-mode-methods`; `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics` | `docs/specs/internal/light-mode-semantics.md`; `docs/specs/internal/rpc-support-matrix.md` |
| JSON-RPC Reference | `reference/json-rpc/unsupported-and-deferred` | `JSON-RPC Spec Owner` | `docs/specs/json-rpc-contract.md`; `docs/specs/prd.md` | `docs/specs/json-rpc-contract.md#12-deferred-trusted-helpers`; `docs/specs/json-rpc-contract.md#14-unsupported-public-surface`; `docs/specs/prd.md#32-out-of-scope` | `docs/specs/internal/rpc-support-matrix.md`; `docs/specs/internal/phase-1-product-shape.md` |
