# Archived Implementation Context

Last updated: 2026-03-29

This directory contains historical implementation context artifacts (design notes, investigative write-ups, and point-in-time analysis).

Governance status:

- archival
- non-normative
- not part of the active product contract

Do not treat files in this directory as current ZEVM behavior requirements.
Historical files may include placeholders or TODO snippets captured during drafting and are non-authoritative.

Known historical divergences in this archive:

- some ticket context files enumerate broader method inventories than the active phase-1 ZEVM contract
- some ticket context files discuss `blockTimestamp` extension fields in transaction/receipt/log payloads; the active ZEVM contract intentionally excludes those extension fields

Active contract sources:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`
- support summaries in `docs/specs/internal/*` (explanatory, non-overriding)
