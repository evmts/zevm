# Redirect Note: Contradictions

Last updated: 2026-03-30

## Not A Live Ledger

This file remains non-normative and redirect-first.

Do not use it as a general contradiction backlog, remediation plan, or status matrix.

The normative product contract lives in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

## Docs-First Resolution Process (Non-Normative)

When a contradiction is found:

1. Resolve it by updating the normative source document(s) directly in the same change.
2. If rationale is worth keeping, record it in `docs/specs/maintainer-decisions.md`.
3. Remove any temporary pending metadata entry in this file as soon as closure criteria are met.

## Current Pending State (Auditable Snapshot)

As of `2026-03-30`, pending contradictions: `none`.

Audit invariant:

- This file keeps only currently pending rows.
- When nothing is pending, the table must contain exactly one sentinel row: `_none_`.
- When one or more items are pending, remove the sentinel row and keep only real pending rows.

## Minimal Pending Metadata (Exception-Only)

Exception: while a contradiction is genuinely unresolved, temporary rows are allowed only to keep owner and target anchors explicit.

Allowed fields only:

- `pendingId`: stable short ID (for example `C-2026-03-30-01`)
- `openedOn`: ISO date (`YYYY-MM-DD`)
- `ownerRole`: role, not person name (for example `Docs IA Owner`, `Runtime/Mode Spec Owner`, `Configuration Spec Owner`, `JSON-RPC Spec Owner`)
- `normativeTarget`: explicit section anchors in `prd.md` and/or `json-rpc-contract.md`
- `closureRule`: explicit condition that closes the row

Prohibited backlog fields:

- priority, severity, ETA, sprint, remediation checklist, percent complete, dependency graph
- multi-state workflow columns beyond `pending`/removed
- long historical narrative

Temporary-row mechanism:

1. Add one row per currently unresolved contradiction.
2. Use only the allowed columns.
3. Keep the row only while unresolved.
4. Delete the row immediately after normative anchors are updated and contradiction is closed.

Closure rule (mandatory):

- close by deleting the row after the normative contradiction is resolved at the declared anchors
- if rationale is needed, add/update `docs/specs/maintainer-decisions.md`
- this file keeps only currently pending rows; no resolved-history ledger

## Pending Rows

| pendingId | openedOn | ownerRole | normativeTarget | closureRule |
| --- | --- | --- | --- | --- |
| _none_ | _n/a_ | _n/a_ | _n/a_ | _n/a_ |

## Archive Scope

Historical contradiction ledgers were removed intentionally to avoid stale process artifacts that conflict with docs-first convergence.
