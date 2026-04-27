# ZEVM Maintainer Decisions

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

| Decision ID | Topic | Normative anchor |
| --- | --- | --- |
| `DEC-001` | docs are full-spec artifacts, not conceptual sketches | `docs/specs/prd.md`; `docs/specs/json-rpc-contract.md` |
| `DEC-002` | one binary, two modes, and forking stays inside trusted mode | `docs/specs/prd.md` (purpose/scope/runtime modes) |
| `DEC-003` | transport contract location | `docs/specs/prd.md` (transport section); `docs/specs/json-rpc-contract.md` (envelope/transport tuples) |
| `DEC-004` | notification semantics | `docs/specs/json-rpc-contract.md` (notification and `id` semantics) |
| `DEC-005` | trusted-mode block tags | `docs/specs/prd.md` (trusted block tags); `docs/specs/json-rpc-contract.md` (mode-gated selector behavior) |
| `DEC-006` | exact managed dev-wallet contract | `docs/specs/prd.md` (managed dev-wallet contract) |
| `DEC-007` | light-mode checkpoint precedence | `docs/specs/prd.md` (startup precedence); `docs/specs/json-rpc-contract.md` (startup semantics) |
| `DEC-008` | light-mode checkpoint file contract | `docs/specs/prd.md` (persisted checkpoint file contract); `docs/specs/json-rpc-contract.md` (checkpoint input rules) |
| `DEC-009` | light-mode readiness surface | `docs/specs/prd.md` (light readiness rules); `docs/specs/json-rpc-contract.md` (`zevm_lightSyncStatus`, readiness-gated methods) |
| `DEC-010` | deferred surfaces | `docs/specs/prd.md` (in/out-of-scope); `docs/specs/json-rpc-contract.md` (supported/deferred methods) |
| `DEC-011` | installation distribution promise | `docs/specs/prd.md` (phase-1 source-build installation contract) |
| `DEC-012` | exact nonstandard trusted-mode method inventory and alias policy | `docs/specs/prd.md` (namespace policy); `docs/specs/json-rpc-contract.md` (canonical method/alias inventory) |
| `DEC-013` | exact trusted-mode config JSON subshapes for mining/fork objects | `docs/specs/prd.md` (config schema and trusted object sub-shapes) |
| `DEC-014` | decision-log role | this file header + `docs/specs/prd.md`/`docs/specs/json-rpc-contract.md` as sole normative sources |
| `DEC-015` | compatibility aliases share ZEVM semantics | `docs/specs/json-rpc-contract.md` (alias tuples and shared semantics) |
| `DEC-016` | light-mode checkpoint startup failures vs reserved RPC codes | `docs/specs/prd.md` (checkpoint age/startup failures); `docs/specs/json-rpc-contract.md` (error code table and mode gating) |
| `DEC-017` | authoritative trusted-mode runtime and config model | `docs/specs/prd.md` (startup/config/runtime mode contract) |
| `DEC-018` | light-mode checkpoint age boundary and non-strict branch | `docs/specs/prd.md` (checkpoint age policy); `docs/specs/json-rpc-contract.md` (startup checkpoint-age semantics) |
| `DEC-019` | light-mode numeric block-selector contract | `docs/specs/prd.md` (light block selectors/history semantics); `docs/specs/json-rpc-contract.md` (numeric selector/error tuples) |
| `DEC-020` | baked checkpoint defaults are precedence inputs, not frozen public hashes | `docs/specs/prd.md` (checkpoint precedence/default semantics); `docs/specs/json-rpc-contract.md` (`checkpointSource` semantics) |
| `DEC-021` | light-mode `eth_blockNumber` readiness and head meaning | `docs/specs/prd.md` (light readiness + `eth_blockNumber`); `docs/specs/json-rpc-contract.md` (`eth_blockNumber` tuple) |
| `DEC-022` | exact `--config` loader failure behavior | `docs/specs/prd.md` (startup failure behavior) |
| `DEC-023` | exact empty-batch `[]` transport behavior | `docs/specs/prd.md` (transport requirements); `docs/specs/json-rpc-contract.md` (empty-batch envelope tuple) |
| `DEC-024` | release-metadata/provenance contract is explicit and auditable, including correction-release supersession-note value requirements | `docs/specs/prd.md` (section 3.4 release metadata/provenance + supersession-note contract) |
| `DEC-025` | release qualification must be verifiable from default `zig build test` execution plus explicit shipped-surface coverage mapping | `docs/specs/prd.md` (section 3.5 release qualification criteria) |
| `DEC-026` | release qualification obligations include listener/socket smoke coverage for trusted and light modes plus canonical ZEVM transport/parser shipping path with notification-only request/batch HTTP `204` empty-body behavior | `docs/specs/prd.md` (section 3.5 listener/socket smoke and transport/parsing verification criteria) |
| `DEC-027` | phase-1 `releaseIdentifier` discovery is deliberately operator-provenance-only (no runtime/CLI reporting surface) | `docs/specs/prd.md` (section 3.4 release metadata/provenance boundary; section 3.5 qualification acceptance) |
