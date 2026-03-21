# ZEVM Mintlify Docs Plan

Last updated: 2026-03-21

## Scope

This plan covers the public Mintlify docs tree plus the supporting control docs that keep it auditable.

Authoritative order:

1. `docs/specs/prd.md`
2. `docs/specs/docs-first-process.md`
3. `src/` and tests
4. `docs/issues/*`, `docs/context/*`, `docs/plans/*`, `PROGRESS.md`

## Public Page Set

The public tree is the 16-page navigation listed in `mintlify/mint.json`:

- `mintlify/docs/index.mdx`
- `mintlify/docs/quickstart/run-trusted-mode.mdx`
- `mintlify/docs/quickstart/connect-json-rpc.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/state-forking-and-snapshots.mdx`
- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/reference/configuration/light-mode.mdx`
- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/reference/json-rpc/trusted-reads.mdx`
- `mintlify/docs/reference/json-rpc/execution-and-submission.mdx`
- `mintlify/docs/reference/json-rpc/canonical-queries.mdx`
- `mintlify/docs/reference/json-rpc/dev-controls.mdx`
- `mintlify/docs/reference/json-rpc/deferred-surfaces.mdx`

Shared public assets:

- `mintlify/mint.json`
- `mintlify/docs/_snippets/current-head-note.mdx`
- `mintlify/docs/_snippets/trusted-managed-wallet.mdx`

## Drafting Rules

- public docs describe the intended ZEVM contract exactly
- public docs keep intended behavior separate from current `HEAD`
- public docs do not silently narrow the contract just because `HEAD` is incomplete
- repeated dated current-state caveats live in shared snippets where possible

## Control-Doc Requirements

Every public-doc pass must keep these files in sync:

- `docs/specs/source-evidence-matrix.md`
- `docs/specs/public-docs-sources.md`
- `docs/specs/page-ownership.md`
- `docs/specs/contradiction-inventory.md`
- `docs/specs/open-questions.md`
- `docs/specs/maintainer-decisions.md`
- `docs/specs/final-risk-report.md`

## Gate Conditions

The documentation-control gate passes only if:

- every public page maps to source IDs
- every referenced contradiction ID exists
- every referenced question ID exists
- public docs use the same contract language as the PRD
- notification semantics are consistent across public, internal, and control docs
- trusted-mode tag semantics are consistent across public, internal, and control docs
- light-mode status and checkpoint precedence are consistent across public, internal, and control docs
- shared snippets are actually used for repeated dated caveats unless there is a documented reason not to

## Current Gate Result

- documentation-control gate on 2026-03-21: pass
- shipment gate on 2026-03-21: fail, because current `HEAD` does not yet satisfy the documented contract
