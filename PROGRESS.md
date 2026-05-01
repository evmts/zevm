# ZEVM Engineering Status (Current)

Last updated: 2026-04-30

This file is the single engineering-facing status summary for implementation progress.

Normative behavior still lives in:
- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

## Scope and interpretation

Status labels are split by execution reality:
- `implemented`: helper/domain code exists
- `wired`: runtime endpoint/path is connected in the shipping binary
- `tested`: covered by default `zig build test` graph or explicit qualification validation
- `release-ready`: can be claimed in phase-1 release qualification today

## Current status by area

| Area | Implemented | Wired | Tested | Release-ready | Notes |
| --- | --- | --- | --- | --- | --- |
| Trusted-mode runtime and startup/config parsing | yes | yes | partial | partial | Broadly present; qualification map still carries explicit gaps for some shipped surfaces. |
| Trusted JSON-RPC core reads | yes | yes | partial | partial | Public docs/specs define contract; qualification rows include both covered and gap entries. |
| Trusted simulation/submission/mining/state controls | yes | yes | partial | partial | Behavior is contract-defined and wired; release qualification still requires closing remaining gaps. |
| Canonical block/tx/receipt/log queries | yes | yes | partial | partial | Contract and docs are current; assertion-map tracks remaining coverage work. |
| Light-mode lifecycle and supported proof-backed reads | yes | yes | partial | partial | Readiness/error semantics are specified; release qualification not fully closed yet. |
| Release metadata contract (`release-tuple.json`, `light-default-checkpoints.json`) | spec yes | runtime n/a | partial | partial | Contract is normative in PRD; implementation/validation closure is tracked in release tickets. |
| Release qualification evidence map | yes | yes | yes | partial | `docs/specs/qualification/assertion-map.json` exists with explicit `gap` rows. |

## Source-of-truth docs posture

- `docs/specs/` is the active current source for product/API contract and engineering support docs.
- `docs/issues/` is archival only and must not be used as normative/current implementation status.
- docs site configuration is tracked at `docs/mint.json` in this repository layout (no separate active `mintlify/` tree in this worktree).
- `docs/specs/features.ts` is tracked as the non-normative feature inventory used for engineering/docs coverage bookkeeping and should stay aligned to PRD + JSON-RPC contract.

## Public docs alignment guardrail

- Public docs under `docs/` must not claim behavior that is not wired in the binary.
- If behavior is planned/not-ready, docs must say so explicitly and use the contract error/readiness semantics from `docs/specs/json-rpc-contract.md`.

## Release metadata and qualification next actions

Phase-1 release qualification is still in progress and remains explicit work:
- release metadata artifact generation/validation closure: `.smithers/tickets/015-implement-release-metadata-artifact-generation-and-validation.md` (ticket path may exist outside minimal worktrees)
- release qualification smoke + coverage closure: `.smithers/tickets/016-implement-release-qualification-assertion-mapping-and-smoke-gates.md` (ticket path may exist outside minimal worktrees)

Until those close, claim status should remain "partial release-ready" rather than complete phase-1 qualification.
