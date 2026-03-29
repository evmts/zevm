# ZEVM Mintlify Docs Plan

Last updated: 2026-03-29

## Authority

Hard source hierarchy for this docs pass:

1. `docs/specs/prd.md`
2. `docs/specs/docs-first-process.md`
3. `src/` and tests as contradiction detector only
4. `docs/issues/*`, `docs/context/*`, `docs/plans/*`, `PROGRESS.md` as non-normative evidence only

This is docs-only work. Existing Mintlify pages and older review artifacts are audit inputs, not normative authority. Repo-local control docs such as `docs/specs/maintainer-decisions.md` and `docs/specs/json-rpc-contract.md` are support-layer inputs that may backfill exact detail or record an explicit contradiction plus public-doc stance, but they must not silently override the hierarchy above.

## Repo Baseline

- `git status --short` on `2026-03-29`: dirty worktree with docs/control changes plus Mintlify IA additions, removals, and renames
- `zig build` on `2026-03-29`: failed first in `src/rpc/server.zig` because current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`
- `zig build test` on `2026-03-29`: failed in `src/rpc/dispatcher_test.zig` and `src/rpc/server.zig` because current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`, and in `src/tx_processor.zig` because current `guillotine-mini` requires a wider `evm.init` signature
- dated failure themes:
  - current upstream `jsonrpc` no longer exposes `jsonrpc.envelope`, but ZEVM server and dispatcher tests still reference it
  - current `guillotine-mini` expects a wider `evm.init` signature than ZEVM currently passes from `src/tx_processor.zig`
  - `src/main.zig` still only wires `src/rpc/server.zig.parseConfig`, and `parseConfig` still only accepts `--host` and `--port`
- secondary evidence inspected: `docs/issues/*`, `docs/context/*`, `docs/plans/*`, `PROGRESS.md`

## Surface Classification

- docs governance and evidence hierarchy: `aligned`
- integration-shell or upstream-ownership boundary: `contradiction`
- startup, mode selection, and shared config contract: `prototype gap`
- exact `--config` loader failure behavior for missing file, unreadable file, and malformed JSON: `prototype gap`
- trusted-mode config JSON subshapes for non-auto mining and non-null fork config: `prototype gap`
- canonical HTTP JSON-RPC transport and notifications: `contradiction`
- exact empty-batch `[]` transport behavior: `contradiction`
- trusted core reads: `contradiction`
- trusted simulation: `prototype gap`
- transaction submission and mining runtime: `contradiction`
- canonical block, receipt, log, and tx queries: `contradiction`
- snapshot boundary and nonstandard dev controls: `contradiction`
- exact nonstandard dev-control method inventory and alias policy: `contradiction`
- light-mode startup, status, and verified reads: `prototype gap`
- exact light-mode `eth_blockNumber` meaning and while-not-ready behavior: `prototype gap`
- checkpoint file contract: `prototype gap`
- checkpoint-age equality boundary and light-mode selector semantics: `contradiction`
- tracing, filter lifecycle APIs beyond `eth_getLogs`, subscriptions, and WebSocket transport: `deferred`

See `docs/specs/source-evidence-matrix.md` for claim-by-claim evidence, `docs/specs/contradiction-inventory.md` for mismatches, and `docs/specs/open-questions.md` for the March 29 closed-question record.

## Target Public Tree

Required Mintlify tree for this pass:

- `mintlify/mint.json`
- `mintlify/docs/index.mdx`
- `mintlify/docs/quickstart/installation.mdx`
- `mintlify/docs/quickstart/run-trusted-mode.mdx`
- `mintlify/docs/quickstart/forked-dev-node.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/concepts/architecture-and-upstream-ownership.mdx`
- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/reference/configuration/light-mode.mdx`
- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/reference/json-rpc/simulation.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
- `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx`
- `mintlify/docs/reference/json-rpc/dev-controls.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`
- `mintlify/docs/reference/json-rpc/unsupported-and-deferred.mdx`
- `mintlify/docs/_snippets/*`

## IA Migration From The Legacy Tree

- retire `mintlify/docs/quickstart/connect-json-rpc.mdx`; move transport semantics into `mintlify/docs/reference/json-rpc/overview.mdx`
- split `mintlify/docs/reference/json-rpc/trusted-reads.mdx` into `core-reads.mdx` plus `concepts/method-support-by-mode.mdx`
- split `mintlify/docs/reference/json-rpc/execution-and-submission.mdx` into `simulation.mdx` plus `transactions-and-mining.mdx`
- rename `mintlify/docs/reference/json-rpc/canonical-queries.mdx` to `blocks-receipts-and-logs.mdx`
- rename `mintlify/docs/reference/json-rpc/deferred-surfaces.mdx` to `unsupported-and-deferred.mdx`
- add new required pages:
  - `mintlify/docs/quickstart/installation.mdx`
  - `mintlify/docs/quickstart/forked-dev-node.mdx`
  - `mintlify/docs/concepts/method-support-by-mode.mdx`
  - `mintlify/docs/concepts/architecture-and-upstream-ownership.mdx`
  - `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`

## Worker Slices

- `contract-core-slice`
  - `docs/specs/internal/phase-1-product-shape.md`
  - `docs/specs/internal/upstream-ownership-and-boundaries.md`
  - `mintlify/docs/index.mdx`
  - `mintlify/docs/concepts/architecture-and-upstream-ownership.mdx`
- `startup-config-slice`
  - `docs/specs/internal/startup-and-configuration.md`
  - `mintlify/docs/quickstart/installation.mdx`
  - `mintlify/docs/quickstart/run-trusted-mode.mdx`
  - `mintlify/docs/quickstart/forked-dev-node.mdx`
  - `mintlify/docs/reference/configuration/overview.mdx`
  - `mintlify/docs/reference/configuration/trusted-mode.mdx`
  - `mintlify/docs/reference/configuration/light-mode.mdx`
- `modes-slice`
  - `docs/specs/internal/runtime-modes-and-boundaries.md`
  - `docs/specs/internal/trusted-mode-semantics.md`
  - `docs/specs/internal/light-mode-semantics.md`
  - `docs/specs/internal/state-fork-and-snapshot-semantics.md`
  - `mintlify/docs/concepts/runtime-modes.mdx`
  - `mintlify/docs/concepts/trusted-mode.mdx`
  - `mintlify/docs/concepts/light-mode.mdx`
  - `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
  - `mintlify/docs/concepts/method-support-by-mode.mdx`
- `rpc-slice`
  - `docs/specs/internal/rpc-support-matrix.md`
  - `docs/specs/internal/transport-and-error-semantics.md`
  - `mintlify/docs/reference/json-rpc/overview.mdx`
  - `mintlify/docs/reference/json-rpc/core-reads.mdx`
  - `mintlify/docs/reference/json-rpc/simulation.mdx`
  - `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
  - `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx`
  - `mintlify/docs/reference/json-rpc/dev-controls.mdx`
  - `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`
  - `mintlify/docs/reference/json-rpc/unsupported-and-deferred.mdx`

Shared-file ownership stays in the main thread for all `docs/specs/*` control docs, `mintlify/mint.json`, and `mintlify/docs/_snippets/*`.

## Gate Status

These gates measure documentation-control completeness, not runnable-product readiness. Current `HEAD` remains red under `C-002`.

- Gate A: `pass`
  - authority order now matches the PRD-first audit hierarchy, support docs no longer claim silent override power, and the former semantic blockers are now settled in the authority layer through `DEC-021`, `DEC-022`, and `DEC-023`
  - the exact phase-1 JSON-RPC contract is backfilled in `docs/specs/json-rpc-contract.md` as a subordinate support artifact
- Gate B: `pass`
  - page ownership is frozen in `docs/specs/page-ownership.md`
  - shared traceability is aligned across the matrix, public source map, page ownership, contradiction inventory, open questions, shared public artifacts, and the page-local blocks updated in this pass, including the earlier `BOOT-02` drift on `mintlify/docs/concepts/trusted-mode.mdx`
- Gate C: `pass`
  - supported-surface public JSON-RPC reference pages are self-contained exact contracts where higher-order authority settles semantics
  - concept pages summarize directly and point to those public reference pages instead of outsourcing contract detail to internal docs, and the former `Q-004` / `Q-005` / `Q-006` surfaces now publish the settled contract directly
- Gate D: `pass`
  - the full required Mintlify tree is present
  - canonical nonstandard method naming is `zevm_*`
  - deferred-filter wording now explicitly excludes `eth_getLogs`, required shared artifacts are mapped, and the transport plus config surfaces now separate the exact settled contract from the remaining current-`HEAD` contradictions
- Gate E: `pass`
  - merged reconciliation reran on source IDs, contradiction IDs, question IDs, affected-page lists, dates, terminology, shared public artifacts, and self-contained reference-page claims
  - the closed-question audit trail is linked through `Q-001` / `DEC-010`, `Q-002` / `DEC-011`, `Q-003` / `DEC-019`, `Q-004` / `DEC-021`, `Q-005` / `DEC-022`, and `Q-006` / `DEC-023`, and the baked-checkpoint policy is recorded in `DEC-020`
