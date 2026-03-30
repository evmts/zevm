# ZEVM Internal Support: Release Metadata And Installation

Last updated: 2026-03-30

This page is non-normative support for:

- `docs/specs/prd.md`

Use the PRD for exact source-build, release-metadata, and qualification contract details.

## 1. Page Routing Scope

This support doc exists to back the active Mintlify pages:

- `quickstart/installation`
- `reference/release-metadata-runbook`

Traceability authority remains `docs/specs/page-ownership.md`.

## 2. Installation Contract Summary (PRD 3.3)

Phase-1 installation is source-build only.

Core constraints:

- canonical build command: `zig build`
- minimum toolchain: `zig 0.15.2`
- required sibling repos: `../voltaire`, `../guillotine-mini`
- reproducibility tuple: `(zevmGitRevision, voltaireGitRevision, guillotineMiniGitRevision, zigVersion)`
- packaged installers and package-manager distribution guarantees are out of scope in phase 1

## 3. Release Metadata Contract Summary (PRD 3.4)

For published `releaseIdentifier` claims, the required immutable assets are:

- `release-tuple.json`
- `light-default-checkpoints.json`

Canonical asset URL pattern:

- `https://github.com/evmts/zevm/releases/download/<releaseIdentifier>/<asset-name>`

Operational summary:

- metadata-backed reproducibility applies only when both required assets are present exactly once and satisfy PRD schema/value invariants
- malformed, missing, duplicate, or mismatched metadata means that `releaseIdentifier` is metadata-invalid for reproducibility
- metadata-invalid published identifiers and unreleased commit builds both fall back to operator-recorded provenance rather than metadata-backed release provenance
- corrections are append-only: publish a new superseding `releaseIdentifier`; do not mutate prior release assets

## 4. Qualification Linkage (PRD 3.5)

Release/install docs must stay consistent with qualification constraints:

- clean checkout `zig build` and `zig build test` coverage for shipped phase-1 surfaces
- release-asset validation and provenance checks when metadata-backed release claims are made
- explicit supersession-note behavior when publishing correction identifiers

## 5. Maintenance Boundary

If this support summary differs from normative docs, `docs/specs/prd.md` wins.
