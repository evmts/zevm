---
title: "Active Plan: Public Docs Maintenance"
---

# Active Plan: Public Docs Maintenance

## Status

This file is a lightweight maintenance plan for the current public docs structure.

It is non-normative and does not define product behavior. Normative behavior remains only in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

## Inputs

- docs navigation sources for current page lists (`docs/astro.config.mjs` for the Starlight sidebar and `docs/mint.json` while the legacy navigation file is retained)
- `docs/specs/page-ownership.md` for the page-to-anchor traceability map
- `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` for normative anchors

## Traceability Control Rules (Non-Normative Process Map)

1. Use `docs/specs/page-ownership.md` as the page-to-anchor map; do not maintain a parallel mapping in this file.
2. When docs navigation or normative docs change, update affected rows in `page-ownership.md` in the same PR.
3. Keep the `Normative anchors (required)` field in `page-ownership.md` current for each affected page in the same PR.

## Structure-Level Plan

This file tracks structure/process only. Do not duplicate tuple-level semantics, per-page ownership, or verification matrices here.

1. Treat the Starlight sidebar in `docs/astro.config.mjs` as the site navigation source of truth; keep `docs/mint.json` aligned while the legacy file remains in the repo.
2. Treat `docs/specs/page-ownership.md` as the only per-page ledger for owners, authoritative sources, normative anchors, and verification timestamps.
3. Keep this plan focused on reconciliation workflow and update triggers, not page-level inventories.

## Maintenance Notes

1. When docs navigation adds/removes/renames groups or pages, reconcile this plan and `docs/specs/page-ownership.md` in the same PR.
2. When `docs/specs/prd.md` or `docs/specs/json-rpc-contract.md` changes semantics, update affected public docs pages and reconcile this plan plus `docs/specs/page-ownership.md` in the same PR.
3. Keep this plan structure-level and routing-level only; tuple-level content and verification ledgers stay in `docs/specs/page-ownership.md`.
4. Internal support docs under `docs/specs/internal/*` may guide edits but are non-normative and must not override normative sources.
