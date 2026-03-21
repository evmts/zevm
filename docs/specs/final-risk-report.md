# ZEVM Final Risk Report

Last updated: 2026-03-21

## Verification Baseline

- authoritative docs reviewed: `docs/specs/prd.md`, `docs/specs/docs-first-process.md`
- implementation reality reviewed: `src/` and tests
- secondary repo evidence reviewed: `docs/issues/*`, `docs/context/*`, `docs/plans/*`, `PROGRESS.md`
- `git status --short` on 2026-03-21 shows the docs tree as local work in progress
- current repo state baseline on 2026-03-21 still includes a failing `zig build test` and an executable path that only wires transport host/port parsing

## Audit Result

The documentation-control pass is materially stronger after this remediation:

- the docs-first rule now explicitly requires the full spec rather than conceptual buckets
- startup and configuration are now documented with exact flags, config fields, defaults, precedence, invalid combinations, and failure behavior
- notification semantics are now documented as a settled contract and current violation
- trusted-mode tag semantics are now explicit and consistent across internal and public docs
- light-mode status and checkpoint precedence are now documented as exact contract surfaces
- traceability files now target the same claim IDs, contradiction IDs, question IDs, and public pages
- a shared Mintlify snippet now carries the dated current-`HEAD` caveat to reduce drift

## Meta-Risks Addressed By This Pass

These review findings are now treated as addressed at the documentation layer:

1. **Docs-first incompleteness**
   - previously: the docs-first process did not state the exhaustive full-spec rule strongly enough
   - now: `docs/specs/docs-first-process.md` makes the full-spec requirement explicit
2. **Notification contract mismatch being framed too softly**
   - previously: some docs treated notifications as wording drift
   - now: the contract is explicit and the current behavior is logged as a contradiction
3. **Broken traceability**
   - previously: matrix, page map, ownership, questions, and risks drifted apart
   - now: those control docs share one claim/question/contradiction set
4. **Evidence-boundary drift**
   - previously: non-primary evidence could dominate the docs story
   - now: repo-primary authority is explicit and external/upstream references are secondary
5. **Write-scope and snippet drift**
   - previously: ownership discipline and repeated dated caveats were too hand-wavy
   - now: page ownership includes write-scope rules and Mintlify pages share a single dated caveat snippet

## Remaining Blockers

1. `C-001` through `C-012` still block any claim that current `HEAD` satisfies the documented product contract.
2. `C-002` remains especially significant because the current transport still violates the now-settled notification contract.
3. `C-007` remains especially significant because the managed-wallet contract is now exact and public while current `HEAD` still contains conflicting sources of truth.
4. `C-011` and `C-012` remain especially significant because light mode is now fully specified but still not publicly exposed in code.

## Shipment Gate

- documentation-control gate: pass
- product-shipment gate: fail

Shipment remains blocked because the repo still has multiple implementation contradictions (`C-001` through `C-012`).

## Residual Risks

1. The docs now specify more exact contract detail than `HEAD` implements, so current-state caveats must keep pace with future code changes.
2. The shared Mintlify snippet reduces drift for the dated baseline, but page-specific “Current Repo State” sections still require maintenance.
3. The managed-wallet policy is now settled, so the remaining drift risk is implementation drift against the exact documented account table rather than policy ambiguity.
4. Even though the control-doc machinery now agrees internally, a future partial edit that changes claim IDs or contradictions without updating the control docs would quickly reintroduce traceability risk.

## Current State

This docs pass is now a real audit artifact rather than a loose summary. It is not ready to support shipment claims, but it is materially closer to being a reliable source of truth for future implementation work.
