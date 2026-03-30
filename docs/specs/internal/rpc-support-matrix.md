# ZEVM Internal Support: RPC Support Matrix

Last updated: 2026-03-30

This page is non-normative support for:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

If this summary differs from normative wording, precedence is explicit:

1. `docs/specs/prd.md` defines product scope and mode boundaries.
2. `docs/specs/json-rpc-contract.md` defines exact method tuples, aliases, selectors, payloads, and error mapping.

## 1. Mode-Level Support Matrix

| Surface | Trusted mode | Light mode | Canonical source |
| --- | --- | --- | --- |
| Transport (`/`, `POST`, JSON-RPC over HTTP) | supported | supported | PRD section 6; JSON-RPC contract sections 3 and 4 |
| Standard core reads | supported | limited to phase-1 proof-backed subset; readiness-gated where defined | PRD sections 3.1, 4.2, 10; JSON-RPC contract sections 8.1 and 13 |
| Simulation (`eth_call`, `eth_estimateGas`) | supported | unsupported (`-32010`) in phase 1 | PRD sections 3.1 and 3.2; JSON-RPC contract sections 8.2, 13, 14 |
| Submission and dev-node controls | supported | unsupported (`-32010`) in phase 1 | JSON-RPC contract sections 8.3, 9.3, 13 |
| Canonical block/receipt/log queries | supported | unsupported (`-32010`) in phase 1 | PRD sections 3.1 and 10; JSON-RPC contract sections 8.4 and 13 |
| Light sync status surface (`zevm_lightSyncStatus`) | unsupported (`-32010`) | supported | PRD sections 4.2 and 10; JSON-RPC contract sections 7.10 and 13 |

## 2. Canonical Inventory Links

Use these canonical inventories directly:

- trusted standard methods: JSON-RPC contract section 8
- trusted canonical `zevm_*` methods and accepted aliases: JSON-RPC contract sections 9.1 and 9.3
- light-mode methods: JSON-RPC contract section 13
- deferred or unsupported public surface: PRD section 3.2 and JSON-RPC contract section 14

## 3. Error Boundary Summary

- mode-unsupported contract methods use `-32010` (JSON-RPC contract section 5.2)
- light readiness gating uses `-32011` where defined (PRD sections 4.2 and 10; JSON-RPC contract sections 5.2 and 13)
- supported selector with proof verification failure maps to `-32014` (JSON-RPC contract section 5.2)
- malformed upstream proof response maps to `-32015` (JSON-RPC contract section 5.2)
- deferred/out-of-contract method names map to `-32601` (JSON-RPC contract sections 5.1 and 14)

## 4. Drift Guardrail

This page intentionally avoids duplicating full method inventories and exact method-level tuples to reduce drift risk. Treat section 1 as a category-level matrix only.
