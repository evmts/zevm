# ZEVM Page Ownership

Last updated: 2026-03-29

## Write-Scope Rules

1. Control docs under `docs/specs/` are main-thread-owned and must be updated atomically when IDs change.
2. `mintlify/mint.json` and all files under `mintlify/docs/_snippets/` are main-thread-owned shared files.
3. Worker scopes are frozen by exact file path. Workers may edit only the files assigned to their slice.
4. No page may cite a source ID, contradiction ID, or question ID that is absent from the corresponding control doc.
5. No public page may hide a contradiction or depend on a blocking question without saying so explicitly.

## Shared Files

| Exact file path | Purpose | Owner |
| --- | --- | --- |
| `docs/specs/prd.md` | authoritative product definition | `main-thread` |
| `docs/specs/docs-first-process.md` | authoritative process constraint | `main-thread` |
| `docs/specs/json-rpc-contract.md` | exact JSON-RPC detail backfill and contradiction-sensitive support doc | `main-thread` |
| `docs/specs/mintlify-docs-plan.md` | phase plan and gate status | `main-thread` |
| `docs/specs/source-evidence-matrix.md` | claim-to-evidence map | `main-thread` |
| `docs/specs/contradiction-inventory.md` | mismatch inventory | `main-thread` |
| `docs/specs/open-questions.md` | unresolved semantic questions | `main-thread` |
| `docs/specs/public-docs-sources.md` | public page traceability map | `main-thread` |
| `docs/specs/page-ownership.md` | write-scope freeze | `main-thread` |
| `docs/specs/maintainer-decisions.md` | resolved decisions and explicit contradiction/public-doc stance records | `main-thread` |
| `docs/specs/final-risk-report.md` | residual-risk report | `main-thread` |
| `mintlify/mint.json` | Mintlify navigation | `main-thread` |
| `mintlify/docs/_snippets/current-head-note.mdx` | shared dated repo-baseline caveat | `main-thread` |
| `mintlify/docs/_snippets/trusted-managed-wallet.mdx` | shared exact managed-wallet table | `main-thread` |

## Shared Public Artifacts

| Exact file path | Purpose | Source IDs | Contradiction IDs | Question IDs | Internal support docs | Owner |
| --- | --- | --- | --- | --- | --- | --- |
| `mintlify/mint.json` | Mintlify navigation for the required public tree | `AUTH-02`, `PROC-01` | `-` | `-` | `-` | `main-thread` |
| `mintlify/docs/_snippets/current-head-note.mdx` | shared dated current-`HEAD` caveat snippet | `HEAD-01` | `C-002` | `-` | `-` | `main-thread` |
| `mintlify/docs/_snippets/trusted-managed-wallet.mdx` | shared exact managed-wallet contract snippet | `TRUST-03` | `C-008` | `-` | `trusted-mode-semantics.md` | `main-thread` |

## Internal Support Docs

| Exact file path | Purpose | Owner |
| --- | --- | --- |
| `docs/specs/internal/phase-1-product-shape.md` | product boundary and docs-first framing | `contract-core-slice` |
| `docs/specs/internal/runtime-modes-and-boundaries.md` | mode split and tag semantics | `modes-slice` |
| `docs/specs/internal/startup-and-configuration.md` | startup and config contract support | `startup-config-slice` |
| `docs/specs/internal/trusted-mode-semantics.md` | trusted-mode semantics and defaults | `modes-slice` |
| `docs/specs/internal/light-mode-semantics.md` | light-mode semantics and readiness | `modes-slice` |
| `docs/specs/internal/rpc-support-matrix.md` | exact method-by-mode backing matrix | `rpc-slice` |
| `docs/specs/internal/state-fork-and-snapshot-semantics.md` | fork and snapshot boundary support | `modes-slice` |
| `docs/specs/internal/transport-and-error-semantics.md` | HTTP, notification, and error contract support | `rpc-slice` |
| `docs/specs/internal/upstream-ownership-and-boundaries.md` | repo-boundary and ownership support | `contract-core-slice` |

## Public Pages

| Exact file path | Purpose | Target reader | Source IDs | Contradiction IDs | Question IDs | Internal support docs | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `mintlify/docs/index.mdx` | landing page, docs-first framing, and mode overview | evaluator deciding what ZEVM is | `AUTH-01`, `AUTH-02`, `PROC-01`, `HEAD-01`, `ARCH-01`, `BOOT-01`, `TRUST-01`, `LIGHT-01`, `LIGHT-04`, `LIGHT-05` | `C-001`, `C-002`, `C-011`, `C-012`, `C-013` | `-` | `phase-1-product-shape.md`, `runtime-modes-and-boundaries.md`, `upstream-ownership-and-boundaries.md` | `contract-core-slice` |
| `mintlify/docs/quickstart/installation.mdx` | source-build install path and current executable baseline | first-time repo user | `PROC-01`, `HEAD-01`, `BOOT-01`, `RPC-01` | `C-001`, `C-002`, `C-003` | `-` | `phase-1-product-shape.md`, `startup-and-configuration.md`, `transport-and-error-semantics.md` | `startup-config-slice` |
| `mintlify/docs/quickstart/run-trusted-mode.mdx` | exact trusted-mode startup path and first successful calls | user starting the local dev node contract | `HEAD-01`, `BOOT-01`, `BOOT-02`, `BOOT-07`, `TRUST-01`, `TRUST-02`, `TRUST-03`, `TRUST-04`, `TRUST-05`, `TRUST-09` | `C-001`, `C-002`, `C-004`, `C-008`, `C-010` | `-` | `startup-and-configuration.md`, `trusted-mode-semantics.md`, `rpc-support-matrix.md` | `startup-config-slice` |
| `mintlify/docs/quickstart/forked-dev-node.mdx` | trusted-mode fork startup and local-on-top-of-remote semantics | user evaluating fork-backed development | `HEAD-01`, `BOOT-02`, `BOOT-07`, `TRUST-09` | `C-001`, `C-002`, `C-010` | `-` | `startup-and-configuration.md`, `state-fork-and-snapshot-semantics.md` | `startup-config-slice` |
| `mintlify/docs/concepts/runtime-modes.mdx` | two-mode product boundary, tag differences, and live contradiction boundaries | reader comparing trusted vs light | `PROC-01`, `HEAD-01`, `BOOT-01`, `BOOT-03`, `BOOT-04`, `BOOT-07`, `RPC-04`, `RPC-ETH-BLOCKNUMBER`, `TRUST-01`, `TRUST-04`, `TRUST-08`, `TRUST-09`, `LIGHT-01`, `LIGHT-04`, `LIGHT-05`, `RPC-TAGS-LIGHT`, `DEFER-01` | `C-001`, `C-002`, `C-007`, `C-010`, `C-011`, `C-012` | `Q-003`, `Q-004` | `runtime-modes-and-boundaries.md`, `trusted-mode-semantics.md`, `light-mode-semantics.md` | `modes-slice` |
| `mintlify/docs/concepts/trusted-mode.mdx` | trusted-mode behavior, defaults, accounts, local-only boundaries, and canonical query scope | user reasoning about phase-1 dev-node semantics | `PROC-01`, `HEAD-01`, `BOOT-01`, `BOOT-02`, `BOOT-04`, `TRUST-01`, `TRUST-02`, `TRUST-03`, `TRUST-04`, `TRUST-07`, `TRUST-08`, `TRUST-09`, `TRUST-10`, `TRUST-11`, `DEFER-01` | `C-001`, `C-002`, `C-006`, `C-007`, `C-008`, `C-009`, `C-010` | `-` | `trusted-mode-semantics.md`, `state-fork-and-snapshot-semantics.md` | `modes-slice` |
| `mintlify/docs/concepts/light-mode.mdx` | light-mode purpose, readiness, verified-read boundary, and bounded numeric-selector semantics | user evaluating phase-2 read-only mode | `PROC-01`, `HEAD-01`, `LIGHT-01`, `LIGHT-02`, `LIGHT-03`, `LIGHT-04`, `LIGHT-05`, `LIGHT-06`, `RPC-TAGS-LIGHT`, `RPC-ETH-BLOCKNUMBER` | `C-002`, `C-011`, `C-012` | `Q-003`, `Q-004` | `light-mode-semantics.md`, `runtime-modes-and-boundaries.md` | `modes-slice` |
| `mintlify/docs/concepts/state-fork-and-snapshots.mdx` | local overlay, snapshot boundary, and fork-local semantics | user reasoning about reversible trusted local state | `HEAD-01`, `TRUST-09`, `TRUST-10`, `TRUST-11` | `C-002`, `C-009`, `C-010` | `-` | `state-fork-and-snapshot-semantics.md`, `trusted-mode-semantics.md` | `modes-slice` |
| `mintlify/docs/concepts/method-support-by-mode.mdx` | high-level method availability by trusted, light, and deferred scope | reader choosing the right mode for a method | `PROC-01`, `HEAD-01`, `RPC-04`, `RPC-ETH-BLOCKNUMBER`, `TRUST-05`, `TRUST-06`, `TRUST-07`, `TRUST-08`, `TRUST-11`, `LIGHT-05`, `RPC-TAGS-LIGHT`, `DEFER-01` | `C-002`, `C-004`, `C-005`, `C-006`, `C-007`, `C-009`, `C-012` | `Q-003`, `Q-004` | `rpc-support-matrix.md`, `runtime-modes-and-boundaries.md`, `trusted-mode-semantics.md`, `light-mode-semantics.md` | `modes-slice` |
| `mintlify/docs/concepts/architecture-and-upstream-ownership.mdx` | ownership boundaries between ZEVM, Voltaire, and `guillotine-mini` | maintainer or contributor mapping implementation ownership | `AUTH-01`, `HEAD-01`, `ARCH-01` | `C-002`, `C-013` | `-` | `phase-1-product-shape.md`, `upstream-ownership-and-boundaries.md` | `contract-core-slice` |
| `mintlify/docs/reference/configuration/overview.mdx` | shared startup contract, precedence, invalid-combination rules, exact `--config` loader failures, and current repo baseline caveat | user reading the top-level config contract | `PROC-01`, `HEAD-01`, `BOOT-01`, `BOOT-04`, `BOOT-05`, `BOOT-06`, `BOOT-07`, `BOOT-08`, `LIGHT-03` | `C-001`, `C-002`, `C-010`, `C-011` | `Q-005` | `startup-and-configuration.md` | `startup-config-slice` |
| `mintlify/docs/reference/configuration/trusted-mode.mdx` | exact trusted-mode fields, defaults, validation, fork notes, and current repo baseline caveat | user configuring trusted mode | `HEAD-01`, `BOOT-02`, `BOOT-04`, `BOOT-07`, `BOOT-08`, `TRUST-02`, `TRUST-03`, `TRUST-09` | `C-001`, `C-002`, `C-008`, `C-010` | `Q-005` | `startup-and-configuration.md`, `trusted-mode-semantics.md` | `startup-config-slice` |
| `mintlify/docs/reference/configuration/light-mode.mdx` | exact light-mode config fields, checkpoint file contract, age policy, baked-default precedence, and current repo baseline caveat | user configuring light mode | `PROC-01`, `HEAD-01`, `BOOT-03`, `BOOT-04`, `BOOT-05`, `BOOT-06`, `BOOT-08`, `LIGHT-01`, `LIGHT-02`, `LIGHT-03`, `LIGHT-06` | `C-001`, `C-002`, `C-011` | `Q-005` | `startup-and-configuration.md`, `light-mode-semantics.md` | `startup-config-slice` |
| `mintlify/docs/reference/json-rpc/overview.mdx` | canonical transport, batch, notification, error rules, exact empty-batch behavior, and JSON-RPC authority model | client integrator | `AUTH-01`, `AUTH-02`, `PROC-01`, `HEAD-01`, `RPC-01`, `RPC-02`, `RPC-03`, `RPC-04`, `RPC-05`, `RPC-ETH-BLOCKNUMBER`, `DEFER-01` | `C-002`, `C-003`, `C-004`, `C-005`, `C-006`, `C-007`, `C-009`, `C-012` | `Q-004`, `Q-006` | `transport-and-error-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/core-reads.mdx` | exact trusted-mode core read reference | client integrator using core trusted reads | `AUTH-02`, `PROC-01`, `HEAD-01`, `TRUST-03`, `TRUST-04`, `TRUST-05`, `RPC-ETH-FEEHISTORY` | `C-002`, `C-004`, `C-008` | `-` | `trusted-mode-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/simulation.mdx` | exact trusted-mode simulation contract | client integrator using `eth_call` or `eth_estimateGas` | `AUTH-02`, `PROC-01`, `HEAD-01`, `TRUST-06` | `C-002`, `C-005` | `-` | `trusted-mode-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx` | exact submission, pending-state, and mining contract | client integrator sending txs or controlling mining | `AUTH-02`, `PROC-01`, `HEAD-01`, `TRUST-03`, `TRUST-07`, `TRUST-11` | `C-002`, `C-006`, `C-008`, `C-009` | `-` | `trusted-mode-semantics.md`, `state-fork-and-snapshot-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx` | exact canonical query surface | client integrator querying canonical chain state | `AUTH-02`, `PROC-01`, `HEAD-01`, `TRUST-04`, `TRUST-08` | `C-002`, `C-007` | `-` | `trusted-mode-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/dev-controls.mdx` | exact nonstandard ZEVM-control contract | client integrator using state mutation, snapshots, or time controls | `AUTH-02`, `PROC-01`, `HEAD-01`, `TRUST-07`, `TRUST-10`, `TRUST-11` | `C-002`, `C-006`, `C-009` | `-` | `state-fork-and-snapshot-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx` | light-mode verified-read and status reference, including the readiness-gated `eth_blockNumber` rule | client integrator using proof-backed reads | `AUTH-02`, `PROC-01`, `HEAD-01`, `LIGHT-04`, `LIGHT-05`, `RPC-TAGS-LIGHT`, `RPC-ETH-BLOCKNUMBER` | `C-002`, `C-012` | `Q-003`, `Q-004` | `light-mode-semantics.md`, `rpc-support-matrix.md` | `rpc-slice` |
| `mintlify/docs/reference/json-rpc/unsupported-and-deferred.mdx` | deferred and intentionally unsupported surfaces | reader checking what is out of scope | `AUTH-02`, `PROC-01`, `HEAD-01`, `DEFER-01` | `C-002` | `-` | `rpc-support-matrix.md`, `phase-1-product-shape.md` | `rpc-slice` |
