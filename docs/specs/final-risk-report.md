# ZEVM Final Risk Report

Last updated: 2026-03-29

## Verification Baseline

- authoritative docs read:
  - `docs/specs/prd.md`
  - `docs/specs/docs-first-process.md`
  - `docs/specs/maintainer-decisions.md`
  - `docs/specs/json-rpc-contract.md`
  - `docs/specs/open-questions.md`
  - `docs/specs/source-evidence-matrix.md`
  - `docs/specs/public-docs-sources.md`
  - `docs/specs/page-ownership.md`
  - `docs/specs/contradiction-inventory.md`
- repo-context docs read:
  - `PROGRESS.md`
  - `docs/issues/*`
  - `docs/context/*`
  - `docs/plans/*`
- repo health commands run on `2026-03-29`:
  - `git status --short`
  - `zig build`
  - `zig build test`
- repo health result:
  - worktree is dirty with docs/control changes plus Mintlify IA additions, removals, and renames
  - `zig build` fails first in `src/rpc/server.zig` because current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`
  - `zig build test` fails in `src/rpc/dispatcher_test.zig` and `src/rpc/server.zig` because current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`, and in `src/tx_processor.zig` because current `guillotine-mini` requires a wider `evm.init` signature
  - `src/main.zig` still only wires `src/rpc/server.zig.parseConfig`, and `parseConfig` still only accepts `--host` and `--port`
- independent review passes completed in this pass:
  - cold reread of the authority docs plus support-layer controls under the PRD-first hierarchy
  - traceability audit across page-local traceability blocks, `public-docs-sources.md`, `source-evidence-matrix.md`, `page-ownership.md`, `mintlify/mint.json`, and shared snippets
  - semantic authority audit covering light-mode `eth_blockNumber`, `--config` loader failures, and empty-batch `[]` behavior
  - public-reference audit covering managed-wallet self-containment, transport contradiction handling, and stale March 29 current-`HEAD` wording

## Current Gate Status

These gates measure documentation-control completeness, not runnable-product readiness. Current `HEAD` remains red under `C-002`.

- Gate A: `pass`
  - authority order is explicit, support docs do not silently override it, the `eth_getLogs` deferred-scope clarification remains explicit, and the former semantic blockers are now settled in the authority layer through `DEC-021`, `DEC-022`, and `DEC-023`
- Gate B: `pass`
  - page-local traceability blocks, `public-docs-sources.md`, `source-evidence-matrix.md`, and `page-ownership.md` are reconciled across the pages updated in this pass, including the shared public artifacts `mintlify/mint.json`, `mintlify/docs/_snippets/current-head-note.mdx`, and `mintlify/docs/_snippets/trusted-managed-wallet.mdx`
  - the earlier `BOOT-02` drift on `mintlify/docs/concepts/trusted-mode.mdx` is repaired in the matrix and the page-mapping tables
  - this is not a blanket guarantee about untouched future pages; it reflects the pages explicitly re-read and updated in this repair pass
- Gate C: `pass`
  - supported-surface public JSON-RPC reference pages are self-contained exact contracts where the repo authority settles semantics
  - `mintlify/docs/reference/json-rpc/core-reads.mdx` and `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx` now carry the exact managed-wallet contract locally through the shared snippet, and the former `Q-004` / `Q-005` / `Q-006` surfaces now publish the settled contract directly instead of blocker language
- Gate D: `pass`
  - the required Mintlify tree and required shared public artifacts are present on the repaired surfaces, canonical `zevm_*` naming is consistent there, deferred-filter wording explicitly excludes `eth_getLogs`, public config docs no longer freeze baked checkpoint hashes as contract literals, and the transport docs now state the `/` path contradiction plus the exact empty-batch invalid-request contract explicitly
- Gate E: `pass`
  - merged reconciliation reran on dates, source IDs, contradiction IDs, question IDs, affected-page lists, self-contained reference-page claims, and intended-vs-`HEAD` separation
  - the closed-question audit trail remains linked through `Q-001` / `DEC-010`, `Q-002` / `DEC-011`, `Q-003` / `DEC-019`, `Q-004` / `DEC-021`, `Q-005` / `DEC-022`, and `Q-006` / `DEC-023`, and the baked-checkpoint policy is recorded in `DEC-020`

## Highest-Risk Contradictions

1. `C-003` transport and notification semantics
   - impact: current transport code still drifts from the settled notification contract and from the intended server composition
2. `C-004` trusted-mode core reads
   - impact: current helper paths still contradict the intended core-read contract, including malformed `eth_getStorageAt` slot handling returning zero instead of `-32602` and synthetic `eth_feeHistory` output that ignores `newestBlock`
3. `C-007` canonical trusted queries
   - impact: current helper coverage does not make the canonical query surface release-ready; transaction, receipt, and log paths still carry stub or lossy behavior
4. `C-006` transaction submission and mining runtime
   - impact: phase-1 send and mine behavior is still disconnected from the executable path
5. `C-008` exact managed-account contract
   - impact: published managed-wallet defaults remain exact, but runtime and genesis helpers still disagree internally
6. `C-009` trusted-mode control runtime
   - impact: the canonical `zevm_*` control inventory and exact alias surface remain docs-first contract only on current `HEAD`
7. `C-011` light-mode startup contract
   - impact: light-mode startup, checkpoint selection, and network selection are still not exposed through the binary entrypoint
8. `C-012` light-mode status and verified reads
   - impact: there is still no public `zevm_lightSyncStatus` method, no proof-backed read bridge on the live RPC path, and no live retained-history numeric-selector implementation
9. `C-013` ownership drift
   - impact: duplicate transport and handler paths still blur the intended upstream and integration-shell boundary

## Open Questions

None. `Q-004`, `Q-005`, and `Q-006` were closed on `2026-03-29` by `DEC-021`, `DEC-022`, and `DEC-023`.

## Control-Layer Risks Addressed In This Pass

- authority order is explicit and consistent across `docs-first-process.md`, `prd.md`, `maintainer-decisions.md`, and the public docs
- `docs/specs/json-rpc-contract.md` now exists as the exact JSON-RPC backfill for phase 1 and the light-mode read surface without claiming silent override power over the PRD or process docs
- canonical nonstandard naming is consistently `zevm_*`, with the exact accepted `anvil_*`, `hardhat_*`, and `evm_*` alias inventory carried in authoritative repo-local specs
- the shared traceability layer is aligned across `source-evidence-matrix.md`, `public-docs-sources.md`, `page-ownership.md`, contradiction IDs, question IDs, `mintlify/mint.json`, and the shared snippet artifacts updated in this pass
- closed-question handling is explicit on the repaired control surfaces: the former light-mode numeric-selector blocker remains auditable through resolved `Q-003`, and the former March 29 semantic blockers now remain auditable through resolved `Q-004`, `Q-005`, and `Q-006`
- repaired public JSON-RPC pages now publish exact tuples, object shapes, field rules, return payloads, and method-level semantics directly
- public concept pages no longer tell readers to consult internal docs for exact method inventories, alias mappings, or JSON-RPC payload details
- startup/config exactness is explicit for CLI `--mode light` selection, `coinbaseIndex` `0..9`, `--fork-block-number` without `--fork-url`, default-startup vs config-file shape, and light-mode checkpoint startup behavior
- the light-mode checkpoint surface is now classified without overstating shipped readiness: helper code still matches the persisted-file format, but `LIGHT-02` no longer reads as product-level alignment while light-mode startup remains a prototype gap under `C-011`
- `RPC-TAGS-LIGHT` is now classified as a contradiction rather than a generic prototype gap, and the bounded retained numeric-selector window plus the `-32011` versus `-32602` split are explicit in the control layer and public docs
- baked default checkpoints are now documented as precedence inputs without freezing their current literal hashes as public contract
- `PROC-01` is now evidenced by repaired public docs artifacts rather than by build or test output alone
- the `eth_getStorageAt` malformed-slot behavior and the synthetic `eth_feeHistory` helper output are now classified as live contradictions under `C-004` across the control layer, internal support docs, and repaired public docs
- internal support docs plus trusted canonical-query concept pages now carry `C-007` directly instead of implying that helper presence is equivalent to supported user-facing quality
- the transport contradiction inventory now records that the intended `/` path is settled while current `src/rpc/server.zig` still does not enforce it, and public transport docs carry the exact empty-batch contract instead of leaving it unresolved
- the March 29 current-`HEAD` baseline is refreshed to the exact rerun results from this workspace instead of preserving older March 27 or stale `blst` caveats

## Residual Risks

1. The current repo baseline remains red, so public docs still need dated current-`HEAD` caveats until code catches up.
2. No blocking semantic gap remains in the docs authority layer, but current `HEAD` still does not implement several of the now-settled contracts.
3. Residual implementation contradictions still span `C-001`, `C-003`, `C-004`, `C-005`, `C-006`, `C-007`, `C-008`, `C-009`, `C-010`, `C-011`, `C-012`, and `C-013`; see `docs/specs/contradiction-inventory.md` for the per-surface public-doc stance.
4. Public docs now reconcile the control layer on the pages updated in this pass, but the repo still depends on continued merged updates whenever source IDs, contradiction IDs, question IDs, affected-page lists, or page-local traceability change again.
5. Several public pages still necessarily describe intended-only behavior because the underlying surfaces are not live in `HEAD`, especially light-mode verified reads, light-mode startup, trusted canonical queries, and fork-backed startup.

## Readiness

- documentation state: reconciled for downstream review on the repaired surfaces in this pass, with no remaining open blocking semantic question in the current repo authority layer
- product state: not ready to describe current `HEAD` as runnable or contract-complete
- reason:
  - required shared control docs, shared public artifacts, and the required Mintlify tree are present and aligned on the repaired surfaces
  - repaired public pages now expose the intended contract directly instead of outsourcing exactness to internal docs, and the managed-wallet contract is locally available on the relevant trusted reference pages
  - formerly unsettled semantics are now closed and propagated rather than left ambiguous
  - current `HEAD` still fails to build and still carries multiple implementation contradictions

## Next Actions

1. Implement the settled `DEC-021`, `DEC-022`, and `DEC-023` contracts on current `HEAD` so light-mode `eth_blockNumber`, shared `--config` loader failures, and empty-batch transport behavior stop being docs-only commitments.
2. Use `C-003`, `C-004`, `C-006`, `C-007`, `C-011`, and `C-012` to drive the next implementation pass on transport, trusted core reads, canonical queries, startup, mining, and light-mode execution routing.
3. Re-run the same merged doc reconciliation whenever page-local traceability, shared public artifacts, method inventories, or deferred-surface scope changes again.
