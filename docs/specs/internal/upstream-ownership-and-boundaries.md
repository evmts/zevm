# ZEVM Internal Support: Upstream Ownership And Boundaries

Last updated: 2026-03-27

## Ownership Boundary

### Intended behavior

ZEVM is the integration shell. Voltaire owns Ethereum primitives, JSON-RPC types, state manager, journal and snapshot support, fork backend, blockchain, crypto, and execution-layer foundations. `guillotine-mini` owns the EVM interpreter, tracing substrate, and execution host integration. ZEVM owns CLI and config parsing, mode selection, runtime composition, lifecycle, HTTP JSON-RPC transport, mode-aware routing, startup and shutdown, checkpoint wiring, readiness reporting, and the public naming of nonstandard trusted-mode controls under the canonical `zevm_*` namespace. The canonical shipping transport path is `src/rpc/server.zig` plus `src/rpc/dispatcher.zig`; the older `src/rpc/envelope.zig` plus `src/rpc/router.zig` stack is stale and non-shipping. Exact request, payload, alias, selector, and error detail lives in `docs/specs/json-rpc-contract.md`.

### Observed code constraints

The repo still carries a local transport, envelope, router, and handler stack alongside the shipping path, and runtime-critical pieces are not consistently wired through the shipping startup path. That is duplicate-stack drift, not a change in ownership.

### Unresolved ambiguity

None on ownership roles. The remaining issue is implementation alignment, including the docs-first rule that compatibility aliases do not replace the canonical `zevm_*` surface in public docs.

### Affected public pages

`mintlify/docs/concepts/architecture-and-upstream-ownership.mdx`, `mintlify/docs/index.mdx`, `mintlify/docs/concepts/runtime-modes.mdx`, `mintlify/docs/reference/json-rpc/overview.mdx`.

## Traceability

- Source IDs: `ARCH-01`, `PROC-01`
- Contradiction IDs: `C-002`, `C-013`
- Question IDs: `-`
- Internal support docs: `phase-1-product-shape.md`
- Notes: Namespace policy is a product-contract rule, not a docs preference.

## Repo-Path Drift

### Intended behavior

repository references should identify the upstream checkout path consistently when docs explain ownership or integration boundaries.

### Observed code constraints

the PRD Architecture section names `guillotine-mini` as `../guillotine-mini`; preserve that exact checkout path here and do not repeat the stale `../bench/guillotine-mini` variant.

### Unresolved ambiguity

None on the local path spelling.

### Affected public pages

`mintlify/docs/concepts/architecture-and-upstream-ownership.mdx`.

## Traceability

- Source IDs: `ARCH-01`
- Contradiction IDs: `-`
- Question IDs: `-`
- Internal support docs: `phase-1-product-shape.md`
- Notes: The local workspace path is `../guillotine-mini`; exact RPC details are delegated to `docs/specs/json-rpc-contract.md`.
