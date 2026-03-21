# ZEVM Page Ownership

Last updated: 2026-03-21

This file defines write-scope discipline for the docs set.

## Write-Scope Rules

1. Update `docs/specs/prd.md` before changing downstream contract docs.
2. If a claim ID changes, update the same commit's copies in:
   - `docs/specs/source-evidence-matrix.md`
   - `docs/specs/public-docs-sources.md`
   - any affected internal support docs
   - any affected public pages
3. If a contradiction ID changes, update the same commit's copies in:
   - `docs/specs/contradiction-inventory.md`
   - `docs/specs/source-evidence-matrix.md`
   - `docs/specs/public-docs-sources.md`
   - `docs/specs/final-risk-report.md`
4. If the open-question set changes, update the same commit's copies in:
   - `docs/specs/open-questions.md`
   - `docs/specs/maintainer-decisions.md`
   - `docs/specs/source-evidence-matrix.md`
   - `docs/specs/public-docs-sources.md`
   - any affected public pages
5. Shared snippet files under `mintlify/docs/_snippets/` are main-thread-owned. Repeated dated caveats belong there instead of being copy-pasted across pages.
6. Control docs are main-thread-owned because they must remain globally consistent.

## Shared Files

| Exact file path | Purpose | Owner |
| --- | --- | --- |
| `docs/specs/prd.md` | Primary product contract | `main-thread` |
| `docs/specs/docs-first-process.md` | Docs-first authoring rules | `main-thread` |
| `docs/specs/source-evidence-matrix.md` | Claim-to-evidence audit map | `main-thread` |
| `docs/specs/public-docs-sources.md` | Page-to-source traceability map | `main-thread` |
| `docs/specs/contradiction-inventory.md` | Product-vs-code contradiction inventory | `main-thread` |
| `docs/specs/open-questions.md` | Open blocker list | `main-thread` |
| `docs/specs/maintainer-decisions.md` | Resolved and pending decision log | `main-thread` |
| `docs/specs/final-risk-report.md` | Audit and residual-risk report | `main-thread` |
| `docs/specs/mintlify-docs-plan.md` | Public-doc delivery plan | `main-thread` |
| `mintlify/mint.json` | Public navigation | `main-thread` |
| `mintlify/docs/_snippets/current-head-note.mdx` | Shared dated current-`HEAD` caveat | `main-thread` |
| `mintlify/docs/_snippets/trusted-managed-wallet.mdx` | Shared exact trusted-mode managed-wallet contract | `main-thread` |

## Internal Support Docs

| Exact file path | Purpose | Owner |
| --- | --- | --- |
| `docs/specs/internal/phase-1-product-shape.md` | Product-boundary and docs-first framing support | `contract-core-slice` |
| `docs/specs/internal/runtime-modes-and-boundaries.md` | Mode split, tag semantics, and mode-gating support | `modes-slice` |
| `docs/specs/internal/startup-and-configuration.md` | Exact startup/config contract support | `startup-config-slice` |
| `docs/specs/internal/trusted-mode-semantics.md` | Trusted-mode defaults and method semantics support | `modes-slice` |
| `docs/specs/internal/light-mode-semantics.md` | Light-mode checkpoint, status, and verified-read support | `modes-slice` |
| `docs/specs/internal/rpc-support-matrix.md` | Public RPC support matrix backing doc | `rpc-slice` |
| `docs/specs/internal/state-fork-and-snapshot-semantics.md` | Fork and snapshot boundary support | `modes-slice` |
| `docs/specs/internal/transport-and-error-semantics.md` | Transport, notification, and error contract support | `rpc-slice` |
| `docs/specs/internal/upstream-ownership-and-boundaries.md` | Repo-primary evidence and upstream-boundary support | `contract-core-slice` |

## Public Pages

| Exact file path | Purpose | Source IDs | Contradiction IDs | Question IDs | Owner |
| --- | --- | --- | --- | --- | --- |
| `mintlify/docs/index.mdx` | Landing page and docs-first framing | `DOCS-01`, `ARCH-01`, `BOOT-01`, `LIGHT-01` | `C-001`, `C-010`, `C-011`, `C-012` | `-` | `overview-slice` |
| `mintlify/docs/quickstart/run-trusted-mode.mdx` | Exact trusted-mode startup path | `BOOT-01`, `BOOT-02`, `BOOT-03`, `TRUST-01` | `C-001`, `C-007`, `C-010` | `-` | `startup-config-slice` |
| `mintlify/docs/quickstart/connect-json-rpc.mdx` | Transport contract and notification rules | `RPC-01`, `RPC-02`, `RPC-03` | `C-002`, `C-010` | `-` | `rpc-slice` |
| `mintlify/docs/concepts/runtime-modes.mdx` | Mode split and tag semantics | `ARCH-01`, `TRUST-02`, `LIGHT-01`, `LIGHT-04`, `LIGHT-05` | `C-001`, `C-011`, `C-012` | `-` | `modes-slice` |
| `mintlify/docs/concepts/trusted-mode.mdx` | Trusted-mode conceptual contract | `TRUST-01`, `TRUST-02`, `RPC-04`, `RPC-05`, `RPC-06` | `C-003`, `C-004`, `C-005`, `C-006`, `C-007` | `-` | `modes-slice` |
| `mintlify/docs/concepts/light-mode.mdx` | Light-mode conceptual contract | `LIGHT-01`, `LIGHT-03`, `LIGHT-04`, `LIGHT-05`, `RPC-03` | `C-011`, `C-012` | `-` | `modes-slice` |
| `mintlify/docs/concepts/state-forking-and-snapshots.mdx` | Fork layering and snapshot boundary | `TRUST-03`, `TRUST-04`, `RPC-05` | `C-005`, `C-008`, `C-009` | `-` | `modes-slice` |
| `mintlify/docs/reference/configuration/overview.mdx` | Shared startup/config contract | `DOCS-01`, `BOOT-01`, `BOOT-02`, `BOOT-03`, `LIGHT-03` | `C-001`, `C-011` | `-` | `startup-config-slice` |
| `mintlify/docs/reference/configuration/trusted-mode.mdx` | Trusted-mode config reference | `BOOT-02`, `BOOT-03`, `TRUST-01`, `TRUST-03` | `C-001`, `C-007`, `C-009` | `-` | `startup-config-slice` |
| `mintlify/docs/reference/configuration/light-mode.mdx` | Light-mode config reference | `BOOT-02`, `BOOT-03`, `LIGHT-01`, `LIGHT-02`, `LIGHT-03` | `C-011` | `-` | `startup-config-slice` |
| `mintlify/docs/reference/json-rpc/overview.mdx` | Transport and error overview | `RPC-01`, `RPC-02`, `RPC-03`, `RPC-07`, `LIGHT-04`, `LIGHT-05` | `C-002`, `C-010`, `C-012` | `-` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/trusted-reads.mdx` | Trusted read reference | `TRUST-01`, `TRUST-02`, `RPC-04` | `C-003`, `C-007` | `-` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/execution-and-submission.mdx` | Trusted execution and submission reference | `TRUST-01`, `RPC-05` | `C-004`, `C-005`, `C-007` | `-` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/canonical-queries.mdx` | Trusted canonical query reference | `TRUST-02`, `RPC-06` | `C-006` | `-` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/dev-controls.mdx` | Trusted dev-control reference | `TRUST-04`, `RPC-05` | `C-005`, `C-008` | `-` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/deferred-surfaces.mdx` | Deferred surface reference | `RPC-07` | `-` | `-` | `rpc-slice` |
