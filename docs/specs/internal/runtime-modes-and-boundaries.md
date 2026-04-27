# ZEVM Internal Support: Runtime Modes And Boundaries

This page is non-normative support for:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

If this summary differs from normative wording, precedence is explicit:

1. `docs/specs/prd.md` defines product scope and runtime behavior boundaries.
2. `docs/specs/json-rpc-contract.md` defines exact JSON-RPC tuples, selectors, objects, aliases, and error mapping.

## 1. Runtime Split

ZEVM exposes exactly two runtime modes:

- trusted mode: writable local dev chain
- light mode: read-only proof-backed client

Forking is trusted-mode configuration, not a third runtime mode.

Canonical references: PRD sections 4.1 and 4.2; JSON-RPC contract section 6.

## 2. Mode Boundary Summary

| Surface family | Trusted mode | Light mode | Canonical source |
| --- | --- | --- | --- |
| Standard method inventory | supported | limited phase-1 subset | JSON-RPC contract sections 8 and 13; PRD section 3.1 |
| Nonstandard `zevm_*` controls + accepted aliases | supported | unsupported (`-32010`) except `zevm_lightSyncStatus` | JSON-RPC contract sections 9.1, 9.3, 13; PRD section 11 |
| Simulation/submission/query expansion | supported | phase-1 limited/deferred | PRD sections 3.1 and 3.2; JSON-RPC contract sections 13 and 14 |

## 3. Selector And Readiness Boundary

- Trusted and light selector rules are canonical in JSON-RPC contract sections 6.1 and 6.2 (with PRD sections 4.2 and 10).
- Light readiness gating behavior is canonical in PRD sections 4.2 and 10 and JSON-RPC contract sections 5.2 and 13.
- `zevm_lightSyncStatus` object fields/invariants are canonical in JSON-RPC contract section 7.10 and PRD section 10.

## 4. Startup Checkpoint Boundary

- Startup checkpoint source precedence is canonical in PRD section 5.5.
- Persisted checkpoint input contract is canonical in PRD section 5.6.
- Startup checkpoint-age derivation and policy is canonical in PRD section 5.7.
- Startup failure behavior for selected-source checkpoint failures is canonical in PRD section 5.8.

## 5. Drift Guardrail

This support page intentionally avoids duplicating full method inventories and exact payload/error tuples. Use JSON-RPC contract sections 8, 9.3, 13, and 14 for canonical inventories.
