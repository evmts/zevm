# ZEVM Maintainer Decisions

Last updated: 2026-03-21

This file tracks the decisions the docs now treat as settled.

| Decision ID | Topic | Status | Contract used in docs | Related question |
| --- | --- | --- | --- | --- |
| `DEC-001` | Docs must specify the full product contract, not conceptual buckets | Resolved | The docs define exact flags, config fields, defaults, precedence, invalid combinations, and error behavior. | `-` |
| `DEC-002` | Startup/config contract must be explicit | Resolved | The PRD and config reference lock in exact shared, trusted, and light flags and config fields. | `-` |
| `DEC-003` | JSON-RPC notifications follow standard missing-`id` semantics | Resolved | Requests with no `id` produce no response; `"id": null` is not a notification. | `-` |
| `DEC-004` | Trusted-mode `pending`, `safe`, and `finalized` semantics | Resolved | In trusted mode all three are compatibility aliases of `latest` and provide no real finality. | `-` |
| `DEC-005` | Light-mode readiness and sync status are part of the public JSON-RPC contract | Resolved | `zevm_lightSyncStatus` is the documented light-mode status method. | `-` |
| `DEC-006` | Light-mode checkpoint precedence | Resolved | Explicit checkpoint, then persisted checkpoint, then baked network default. | `-` |
| `DEC-007` | Persisted checkpoint file contract | Resolved | Light mode uses `checkpointDir/checkpoint` with a 64-hex on-disk file. | `-` |
| `DEC-008` | Repo docs remain primary authority; upstream/external references are secondary | Resolved | Repo-local docs and code lead; external links may support but not replace repo evidence. | `-` |
| `DEC-009` | Canonical phase-1 transport implementation direction | Resolved | `src/rpc/server.zig` plus `src/rpc/dispatcher.zig` is the intended shipping path; `src/rpc/envelope.zig` plus `src/rpc/router.zig` is prototype-only. | `-` |
| `DEC-010` | Permanent public contract for the exact Hardhat-style mnemonic and private keys | Resolved | ZEVM publicly specifies mnemonic `test test test test test test test test test test test junk`, derivation path root `m/44'/60'/0'/0/`, indices `0..9`, and the exact address/private-key table. | `-` |
