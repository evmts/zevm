# ZEVM Maintainer Decisions

Last updated: 2026-03-30

This file is a non-normative historical decision log.

Normative ZEVM contract sources are only:

1. `docs/specs/prd.md`
2. `docs/specs/json-rpc-contract.md`

Entries here record rationale/history and must not be treated as a third spec layer.

## Drift Control (Non-Normative Process Rules)

- update normative contract docs first when behavior changes
- keep this log at policy/rationale level and point to normative sources for exact tuples, hashes, method inventories, payloads, and errors
- if a prior decision is superseded, append a new decision rather than rewriting history to mirror every contract edit
- if wording here diverges from normative docs, normative docs win

| Decision ID | Topic | Status | Normative anchor | Question-tracker linkage |
| --- | --- | --- | --- | --- |
| `DEC-001` | docs are full-spec artifacts, not conceptual sketches | `resolved` | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` | none |
| `DEC-002` | one binary, two modes, and forking stays inside trusted mode | `resolved` | `docs/specs/prd.md` (purpose/scope/runtime modes) | none |
| `DEC-003` | transport contract location | `resolved` | `docs/specs/prd.md` (transport section); `docs/specs/json-rpc-contract.md` (envelope/transport tuples) | none |
| `DEC-004` | notification semantics | `resolved` | `docs/specs/json-rpc-contract.md` (notification and `id` semantics) | none |
| `DEC-005` | trusted-mode block tags | `resolved` | `docs/specs/prd.md` (trusted block tags); `docs/specs/json-rpc-contract.md` (mode-gated selector behavior) | none |
| `DEC-006` | exact managed dev-wallet contract | `resolved` | `docs/specs/prd.md` (managed dev-wallet contract) | none |
| `DEC-007` | light-mode checkpoint precedence | `resolved` | `docs/specs/prd.md` (startup precedence); `docs/specs/json-rpc-contract.md` (startup semantics) | none |
| `DEC-008` | light-mode checkpoint file contract | `resolved` | `docs/specs/prd.md` (persisted checkpoint file contract); `docs/specs/json-rpc-contract.md` (checkpoint input rules) | none |
| `DEC-009` | light-mode readiness surface | `resolved` | `docs/specs/prd.md` (light readiness rules); `docs/specs/json-rpc-contract.md` (`zevm_lightSyncStatus`, readiness-gated methods) | none |
| `DEC-010` | deferred surfaces | `resolved` | `docs/specs/prd.md` (in/out-of-scope); `docs/specs/json-rpc-contract.md` (supported/deferred methods) | historical tracker retired |
| `DEC-011` | installation distribution promise | `resolved` | `docs/specs/prd.md` (phase-1 source-build installation contract) | historical tracker retired |
| `DEC-012` | exact nonstandard trusted-mode method inventory and alias policy | `resolved` | `docs/specs/prd.md` (namespace policy); `docs/specs/json-rpc-contract.md` (canonical method/alias inventory) | none |
| `DEC-013` | exact trusted-mode config JSON subshapes for mining/fork objects | `resolved` | `docs/specs/prd.md` (config schema and trusted object sub-shapes) | none |
| `DEC-014` | decision-log role | `resolved` | this file header + `docs/specs/prd.md`/`docs/specs/json-rpc-contract.md` as sole normative sources | none |
| `DEC-015` | compatibility aliases share ZEVM semantics | `resolved` | `docs/specs/json-rpc-contract.md` (alias tuples and shared semantics) | none |
| `DEC-016` | light-mode checkpoint startup failures vs reserved RPC codes | `resolved` | `docs/specs/prd.md` (checkpoint age/startup failures); `docs/specs/json-rpc-contract.md` (error code table and mode gating) | none |
| `DEC-017` | authoritative trusted-mode runtime and config model | `resolved` | `docs/specs/prd.md` (startup/config/runtime mode contract) | none |
| `DEC-018` | light-mode checkpoint age boundary and non-strict branch | `resolved` | `docs/specs/prd.md` (checkpoint age policy); `docs/specs/json-rpc-contract.md` (startup checkpoint-age semantics) | none |
| `DEC-019` | light-mode numeric block-selector contract | `resolved` | `docs/specs/prd.md` (light block selectors/history semantics); `docs/specs/json-rpc-contract.md` (numeric selector/error tuples) | historical tracker retired |
| `DEC-020` | baked checkpoint defaults are precedence inputs, not frozen public hashes | `resolved` | `docs/specs/prd.md` (checkpoint precedence/default semantics); `docs/specs/json-rpc-contract.md` (`checkpointSource` semantics) | none |
| `DEC-021` | light-mode `eth_blockNumber` readiness and head meaning | `resolved` | `docs/specs/prd.md` (light readiness + `eth_blockNumber`); `docs/specs/json-rpc-contract.md` (`eth_blockNumber` tuple) | historical tracker retired |
| `DEC-022` | exact `--config` loader failure behavior | `resolved` | `docs/specs/prd.md` (startup failure behavior) | historical tracker retired |
| `DEC-023` | exact empty-batch `[]` transport behavior | `resolved` | `docs/specs/prd.md` (transport requirements); `docs/specs/json-rpc-contract.md` (empty-batch envelope tuple) | historical tracker retired |
| `DEC-024` | release-metadata/provenance contract is explicit and auditable, including correction-release supersession-note value requirements | `resolved` | `docs/specs/prd.md` (section 3.4 release metadata/provenance + supersession-note contract) | none |
| `DEC-025` | release qualification must be verifiable from default `zig build test` execution plus explicit shipped-surface coverage mapping | `resolved` | `docs/specs/prd.md` (section 3.5 release qualification criteria) | none |
| `DEC-026` | release qualification obligations include listener/socket smoke coverage for trusted and light modes plus canonical ZEVM transport/parser shipping path with notification-only request/batch HTTP `204` empty-body behavior | `resolved` | `docs/specs/prd.md` (section 3.5 listener/socket smoke and transport/parsing verification criteria) | none |
| `DEC-027` | phase-1 `releaseIdentifier` discovery is deliberately operator-provenance-only (no runtime/CLI reporting surface) | `resolved` | `docs/specs/prd.md` (section 3.4 release metadata/provenance boundary; section 3.5 qualification acceptance) | none |
