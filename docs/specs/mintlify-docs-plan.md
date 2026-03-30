# Active Plan: Mintlify Docs Maintenance

Last updated: 2026-03-30

## Status

This file is a lightweight active maintenance plan for the current Mintlify docs structure.

It is non-normative and does not define product behavior. Normative behavior remains only in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

## Inputs

- `mintlify/mint.json` for active navigation structure (read `navigation` as the current page list; these are Mintlify page IDs, not expected local `docs/reference/*` files)
- `docs/specs/page-ownership.md` for active traceability fields (owner role, authoritative sources, normative anchors, verification status, and verification dates) and deterministic nav reconciliation procedure
- `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` for normative anchors

## Traceability Control Rules (Non-Normative Process Map)

1. Use `docs/specs/page-ownership.md` as the active traceability ledger; do not maintain a parallel claim matrix in this file.
2. When `mintlify/mint.json` or normative docs change, set affected page rows in `page-ownership.md` to `pending-review` (or `blocked` with active `pendingId`), then return them to `verified` after anchor and nav reconciliation.
3. Keep `page-ownership.md` `Normative anchors (required)`, `Last content verified on`, and `Last nav reconciled on` current for each affected page in the same PR.
4. Keep process artifacts redirect-first: `contradiction-inventory.md` and `open-questions.md` may contain temporary pending rows only while unresolved.

## Structure-Level Plan

This file tracks structure/process only. Do not duplicate tuple-level semantics, per-page ownership, or verification matrices here.

1. Treat `mintlify/mint.json` as the nav source of truth (groups and page IDs).
2. Treat `docs/specs/page-ownership.md` as the only per-page ledger for owners, authoritative sources, normative anchors, and verification timestamps.
3. Keep this plan focused on reconciliation workflow and update triggers, not page-level inventories.

## Maintenance Notes

1. When `mintlify/mint.json` adds/removes/renames groups or pages, reconcile this plan and `docs/specs/page-ownership.md` in the same PR.
2. When `docs/specs/prd.md` or `docs/specs/json-rpc-contract.md` changes semantics, update affected Mintlify pages and reconcile this plan plus `docs/specs/page-ownership.md` in the same PR.
3. Keep this plan structure-level and routing-level only; tuple-level content and verification ledgers stay in `docs/specs/page-ownership.md`.
4. Internal support docs under `docs/specs/internal/*` may guide edits but are non-normative and must not override normative sources.
