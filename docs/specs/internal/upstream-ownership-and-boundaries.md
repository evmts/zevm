# ZEVM Internal Support: Upstream Ownership And Boundaries

Last updated: 2026-03-30

This page is non-normative support for:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

This page is intentionally non-normative. Use those normative docs for exact API behavior and public contract details.

## 1. Ownership Boundary

ZEVM is the integration shell and product surface.

ZEVM owns:

- startup, configuration parsing, and runtime selection (`trusted` or `light`)
- runtime composition and lifecycle
- HTTP JSON-RPC transport and dispatch
- mode-aware method gating and public method namespace policy
- light-mode checkpoint ownership: startup checkpoint source precedence, selected-source failure behavior, persisted-checkpoint input contract, and startup checkpoint-age policy handling
- light-mode readiness ownership: `status`/`ready` derivation and lifecycle transitions, readiness gating decisions for proof-backed reads and `eth_blockNumber`, and exposure through `zevm_lightSyncStatus`
- light-mode proof-path surface ownership: mapping proof-path outcomes to ZEVM contract-visible runtime behavior and error codes
- publication of canonical nonstandard trusted controls under `zevm_*`, with accepted compatibility aliases only as listed in `docs/specs/json-rpc-contract.md`

Voltaire owns Ethereum execution foundations used by ZEVM integration, including:

- Ethereum primitives and JSON-RPC foundational types
- state manager, journal, and snapshot primitives
- fork backend integration and blockchain-level foundations
- core crypto and execution support layers consumed by ZEVM

`guillotine-mini` owns the EVM interpreter layer and tracing substrate integrated by ZEVM.

Proof/readiness boundary clarification:

- Voltaire and `guillotine-mini` expose primitives used in proof-backed execution flows.
- ZEVM owns how those primitives are composed into startup/runtime behavior and public JSON-RPC surface semantics.

## 2. Runtime Boundary Notes

- ZEVM has exactly two runtime modes: trusted mode and light mode.
- Forking is trusted-mode configuration, not a third runtime mode.
- Light-mode proof-backed behavior is defined by the PRD and JSON-RPC contract, not by this support page.
- For canonical light-mode checkpoint/readiness/proof behavior, use PRD sections 4.2, 5.5, 5.6, 5.7, 5.8, 10, and JSON-RPC contract sections 5, 6.2, 7.10, 13.

## 3. Repository Path Convention

When ownership docs reference the interpreter upstream checkout in local workspace examples, use:

- `../guillotine-mini`

## 4. Contract Precedence

If this support summary ever differs from normative wording:

1. `docs/specs/prd.md` defines product scope and behavior boundaries.
2. `docs/specs/json-rpc-contract.md` defines exact JSON-RPC tuples, payloads, aliases, selectors, and errors.

Canonical references for this page:

- PRD architecture boundary: section 12
- Light-mode runtime/checkpoint/readiness semantics: PRD sections 4.2, 5.5, 5.6, 5.7, 5.8, 10
- Exact light-mode API and error tuples: JSON-RPC contract sections 5, 6.2, 7.10, 13
