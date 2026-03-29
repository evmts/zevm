# ZEVM Internal Support: Phase 1 Product Shape

Last updated: 2026-03-27

## Product Boundary

### Intended behavior

Phase 1 is the runnable trusted-mode local dev node. Its public surface is one binary with startup and configuration, HTTP JSON-RPC transport, core reads, execution simulation, transaction submission, mining controls, canonical queries, snapshots, and fork-aware trusted-mode workflows. Nonstandard trusted-mode controls use the canonical `zevm_*` namespace, with exact compatibility aliases documented in `docs/specs/json-rpc-contract.md`. Light mode remains part of ZEVM's product contract, but its verified-read surface is phase 2. Forking stays configuration inside trusted mode, not a third mode.

### Observed code constraints

`src/main.zig` still only wires `src/rpc/server.zig` for `--host` and `--port`; current `HEAD` does not yet compose a runnable trusted runtime, and light-mode startup is not exposed through the executable path. The authoritative trusted-mode runtime/config model lives in `src/node/runtime.zig`; `src/rpc/dev_runtime.zig` is only a narrow snapshot helper prototype and not the product runtime contract.

### Unresolved ambiguity

None on the boundary itself; the control docs already freeze phase 1 as trusted-mode first and phase 2 as light mode.

### Affected public pages

`mintlify/docs/index.mdx`, `mintlify/docs/quickstart/installation.mdx`, `mintlify/docs/quickstart/run-trusted-mode.mdx`, `mintlify/docs/concepts/runtime-modes.mdx`, `mintlify/docs/reference/configuration/overview.mdx`.

## Traceability

- Source IDs: `PROC-01`, `ARCH-01`, `BOOT-01`, `TRUST-01`, `LIGHT-01`
- Contradiction IDs: `C-001`, `C-002`, `C-011`, `C-012`, `C-013`
- Question IDs: `-`
- Internal support docs: `upstream-ownership-and-boundaries.md`
- Notes: Phase 1 stays the trusted-mode local dev node contract; exact RPC method detail is delegated to `docs/specs/json-rpc-contract.md`.

## Docs-First And Phase Priorities

### Intended behavior

ZEVM docs are the contract. Public and internal docs must specify exact flags, config fields, defaults, precedence, invalid combinations, and mode-specific runtime behavior instead of staying conceptual while code catches up.

### Observed code constraints

the repo still has a current `HEAD` gap between intended phase-1 contract and executable reality, so the docs must keep intended behavior and current `HEAD` separate rather than merging them into one narrative.

### Unresolved ambiguity

None in the ordering of phases; phase 1 is trusted mode, phase 2 is light mode, and phase 3 remains deferred.

### Affected public pages

`mintlify/docs/index.mdx`, `mintlify/docs/concepts/runtime-modes.mdx`, `mintlify/docs/reference/json-rpc/overview.mdx`, `mintlify/docs/reference/configuration/overview.mdx`.

## Traceability

- Source IDs: `PROC-01`, `BOOT-01`, `BOOT-02`, `BOOT-03`, `DEFER-01`
- Contradiction IDs: `C-001`, `C-002`, `C-011`, `C-012`, `C-013`
- Question IDs: `-`
- Internal support docs: `upstream-ownership-and-boundaries.md`
- Notes: The phase ordering is settled in the product docs and the exact RPC surface is delegated to the JSON-RPC contract.
