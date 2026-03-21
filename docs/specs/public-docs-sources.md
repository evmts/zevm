# ZEVM Public Docs Sources

Last updated: 2026-03-21

This file is the page-by-page traceability map for the public Mintlify tree.

It covers the 16 navigable public pages listed in `mintlify/mint.json`.

| Page | Source IDs | Contradiction IDs | Question IDs | Internal support docs | Notes |
| --- | --- | --- | --- | --- | --- |
| `mintlify/docs/index.mdx` | `DOCS-01`, `ARCH-01`, `BOOT-01`, `LIGHT-01` | `C-001`, `C-010`, `C-011`, `C-012` | `-` | `phase-1-product-shape.md`, `runtime-modes-and-boundaries.md`, `upstream-ownership-and-boundaries.md` | Imports the shared current-`HEAD` snippet and sets the docs-first contract framing. |
| `mintlify/docs/quickstart/run-trusted-mode.mdx` | `BOOT-01`, `BOOT-02`, `BOOT-03`, `TRUST-01` | `C-001`, `C-007`, `C-010` | `-` | `startup-and-configuration.md`, `trusted-mode-semantics.md` | Uses exact CLI examples and imports the canonical managed-wallet snippet. |
| `mintlify/docs/quickstart/connect-json-rpc.mdx` | `RPC-01`, `RPC-02`, `RPC-03` | `C-002`, `C-010` | `-` | `transport-and-error-semantics.md`, `rpc-support-matrix.md` | Defines the notification contract as settled behavior, not as an open choice. |
| `mintlify/docs/concepts/runtime-modes.mdx` | `ARCH-01`, `TRUST-02`, `LIGHT-01`, `LIGHT-04`, `LIGHT-05` | `C-001`, `C-011`, `C-012` | `-` | `runtime-modes-and-boundaries.md`, `light-mode-semantics.md` | Carries the exact trusted-vs-light block-tag and method boundary. |
| `mintlify/docs/concepts/trusted-mode.mdx` | `TRUST-01`, `TRUST-02`, `RPC-04`, `RPC-05`, `RPC-06` | `C-003`, `C-004`, `C-005`, `C-006`, `C-007` | `-` | `trusted-mode-semantics.md` | Keeps trusted aliases explicit and imports the canonical managed-wallet snippet. |
| `mintlify/docs/concepts/light-mode.mdx` | `LIGHT-01`, `LIGHT-03`, `LIGHT-04`, `LIGHT-05`, `RPC-03` | `C-011`, `C-012` | `-` | `light-mode-semantics.md`, `runtime-modes-and-boundaries.md` | Defines `zevm_lightSyncStatus`, readiness, and checkpoint precedence explicitly. |
| `mintlify/docs/concepts/state-forking-and-snapshots.mdx` | `TRUST-03`, `TRUST-04`, `RPC-05` | `C-005`, `C-008`, `C-009` | `-` | `state-fork-and-snapshot-semantics.md` | Enumerates the full snapshot boundary and fork-local overlay rules. |
| `mintlify/docs/reference/configuration/overview.mdx` | `DOCS-01`, `BOOT-01`, `BOOT-02`, `BOOT-03`, `LIGHT-03` | `C-001`, `C-011` | `-` | `startup-and-configuration.md` | Defines the shared startup contract and top-level precedence rules. |
| `mintlify/docs/reference/configuration/trusted-mode.mdx` | `BOOT-02`, `BOOT-03`, `TRUST-01`, `TRUST-03` | `C-001`, `C-007`, `C-009` | `-` | `startup-and-configuration.md`, `trusted-mode-semantics.md` | Uses exact fields, validation rules, and the canonical managed-wallet snippet. |
| `mintlify/docs/reference/configuration/light-mode.mdx` | `BOOT-02`, `BOOT-03`, `LIGHT-01`, `LIGHT-02`, `LIGHT-03` | `C-011` | `-` | `startup-and-configuration.md`, `light-mode-semantics.md` | Locks in checkpoint file and precedence behavior as part of the public contract. |
| `mintlify/docs/reference/json-rpc/overview.mdx` | `RPC-01`, `RPC-02`, `RPC-03`, `RPC-07`, `LIGHT-04`, `LIGHT-05` | `C-002`, `C-010`, `C-012` | `-` | `transport-and-error-semantics.md`, `rpc-support-matrix.md` | Central transport and error reference, including light-mode status method coverage. |
| `mintlify/docs/reference/json-rpc/trusted-reads.mdx` | `TRUST-01`, `TRUST-02`, `RPC-04` | `C-003`, `C-007` | `-` | `trusted-mode-semantics.md`, `rpc-support-matrix.md` | Documents the exact read set, trusted tag semantics, and `eth_accounts` ordering. |
| `mintlify/docs/reference/json-rpc/execution-and-submission.mdx` | `TRUST-01`, `RPC-05` | `C-004`, `C-005`, `C-007` | `-` | `trusted-mode-semantics.md`, `rpc-support-matrix.md` | Preserves checkpoint/revert and mining semantics and defines managed-account signing authority exactly. |
| `mintlify/docs/reference/json-rpc/canonical-queries.mdx` | `TRUST-02`, `RPC-06` | `C-006` | `-` | `trusted-mode-semantics.md`, `rpc-support-matrix.md` | Keeps canonical query behavior separate from placeholder prototype output. |
| `mintlify/docs/reference/json-rpc/dev-controls.mdx` | `TRUST-04`, `RPC-05` | `C-005`, `C-008` | `-` | `state-fork-and-snapshot-semantics.md`, `rpc-support-matrix.md` | Lists exact dev-control method names and full snapshot capture semantics. |
| `mintlify/docs/reference/json-rpc/deferred-surfaces.mdx` | `RPC-07` | `-` | `-` | `rpc-support-matrix.md` | Keeps deferred scope separate from unfinished phase-1 or phase-2 work. |
