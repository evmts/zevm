# ZEVM Internal Support: Runtime Modes And Boundaries

Last updated: 2026-03-21

## Runtime Split

- intended behavior: ZEVM exposes exactly two runtime modes. Trusted mode is the writable local dev node. Light mode is the consensus-backed verified-read client. Forking is configuration inside trusted mode, not a third mode.
- current repo reality: there is no runtime selector in `src/main.zig`; the executable path only starts the newer transport shell with host and port.
- documentation rule: public docs must describe both modes as real ZEVM product surfaces while calling out that current `HEAD` does not yet expose mode selection in startup.
- source IDs: `BOOT-01`, `LIGHT-01`, `ARCH-01`
- contradiction IDs: `C-001`, `C-011`

## Mode-Gated Method Boundary

| Surface | Trusted mode | Light mode |
| --- | --- | --- |
| `eth_chainId`, `eth_blockNumber` | supported | supported |
| account, code, storage, nonce reads | supported against local trusted state | supported only when backed by verified proofs |
| `eth_call`, `eth_estimateGas` | supported | unsupported |
| transaction submission and mining | supported | unsupported |
| canonical block/receipt/log queries | supported | unsupported in phase 2 |
| snapshots, revert, state mutation, impersonation, time controls | supported | unsupported |
| `zevm_lightSyncStatus` | unsupported | supported |

- intended behavior: unsupported methods fail deterministically by mode with the ZEVM mode-gating error contract rather than through partial runtime wiring.
- current repo reality: current transport/handler code has not implemented complete mode-aware routing; most method availability still depends on which prototype path is inspected.
- source IDs: `RPC-04`, `RPC-05`, `RPC-06`, `LIGHT-04`, `LIGHT-05`
- contradiction IDs: `C-003`, `C-004`, `C-005`, `C-006`, `C-008`, `C-012`

## Block-Tag Boundary

Trusted-mode tag semantics:

| Tag | Meaning |
| --- | --- |
| `latest` | current canonical local head |
| `pending` | compatibility alias of `latest` |
| `safe` | compatibility alias of `latest` |
| `finalized` | compatibility alias of `latest` |
| `earliest` | block `0` |
| numeric quantity | exact local block number |

Light-mode tag semantics:

| Tag | Meaning |
| --- | --- |
| `latest` | latest verified optimistic execution head |
| `safe` | consensus-backed safe head derived from the optimistic light-client head |
| `finalized` | consensus-finalized execution head |
| `earliest` | block `0` |
| numeric quantity | exact block number when ZEVM can map it to verified state |
| `pending` | unsupported |

- intended behavior: trusted-mode `pending`, `safe`, and `finalized` are compatibility aliases only. They do not imply finality. Real `safe` and `finalized` semantics belong to light mode.
- current repo reality: helper code in `src/rpc/handlers/block_spec.zig` and `src/rpc/block_queries.zig` already aliases trusted-mode `pending`, `safe`, and `finalized` to the current head, but the docs previously treated this as unresolved instead of documenting it as the intended trusted-mode contract.
- source IDs: `TRUST-02`, `LIGHT-05`
- contradiction IDs: `C-007`
