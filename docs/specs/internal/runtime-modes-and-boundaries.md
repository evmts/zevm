# ZEVM Internal Support: Runtime Modes And Boundaries

Last updated: 2026-03-29

## Runtime Split

### Intended behavior

- ZEVM exposes exactly two runtime modes.
- Trusted mode is the writable local dev node.
- Light mode is the consensus-backed verified-read client.
- Forking is configuration inside trusted mode, not a third mode.
- The active runtime may be selected directly by CLI `--mode` or by the config-file `mode` branch. `--mode light` is a direct light-mode selection path, not merely a confirmation of config, and when both sources are present they must agree.
- Canonical nonstandard trusted-mode methods use the `zevm_*` namespace.
- Trusted mode also accepts a defined compatibility-alias set under `anvil_*`, the documented `hardhat_*` subset, and selected legacy `evm_*` names.
- The exact accepted alias inventory is enumerated in `docs/specs/json-rpc-contract.md`.
- `zevm_*` is an authoritative product-contract rule, not a docs convention.
- Trusted mode's canonical query surface includes `eth_getLogs`; only filter lifecycle APIs beyond `eth_getLogs` remain deferred.

### Observed code constraints

- On 2026-03-29, there is still no runtime selector in `src/main.zig`, and `src/rpc/server.zig::parseConfig` still only accepts `--host` and `--port`.
- On 2026-03-29, the executable path still only starts the newer transport shell with host and port.
- On 2026-03-29, current `HEAD` still does not expose mode selection in startup, so the public docs must keep the product split separate from the current executable path.

### Unresolved ambiguity

- None about the two-mode product split itself.
- The unresolved work is startup wiring, not the intended mode model.

### Affected public pages

- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`

### Source IDs

- `BOOT-01`
- `LIGHT-01`
- `ARCH-01`
- `TRUST-01`

### Contradiction IDs

- `C-001`
- `C-011`

## Mode-Gated Method Boundary

### Intended behavior

| Surface | Trusted mode | Light mode |
| --- | --- | --- |
| `eth_chainId`, `eth_blockNumber` | supported | supported; `eth_blockNumber` fails with `-32011` while `ready = false` and once ready reports the light-mode `latest` head number |
| account, code, storage, nonce reads | supported against local trusted state | supported only when backed by verified proofs |
| `eth_call`, `eth_estimateGas` | supported | unsupported |
| transaction submission and mining | supported | unsupported |
| canonical block/receipt/log queries | supported | unsupported in phase 2 |
| `zevm_*` controls for snapshots, revert, state mutation, impersonation, time controls, and mining controls | supported | unsupported |
| the exact accepted compatibility-alias set under `anvil_*`, the documented `hardhat_*` subset, and selected `evm_*` names | supported in trusted mode only | unsupported |
| `zevm_lightSyncStatus` | unsupported | supported |

- Unsupported methods fail deterministically by mode with the ZEVM mode-gating error contract rather than through partial runtime wiring.
- The nonstandard trusted-mode surface is documented as `zevm_*`; exact method, alias, payload, and error details live in `docs/specs/json-rpc-contract.md`.

### Observed code constraints

- On 2026-03-29, current transport and handler code still has not implemented complete mode-aware routing.
- On 2026-03-29, most method availability still depends on which prototype path is inspected.
- On 2026-03-29, the implementation is still split across partial helpers and disconnected runtime paths, so the mode boundary is not yet enforced end to end.

### Unresolved ambiguity

- None. The canonical namespace and alias policy are settled for public docs.

### Affected public pages

- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`

### Source IDs

- `RPC-04`
- `TRUST-05`
- `TRUST-06`
- `TRUST-07`
- `TRUST-08`
- `TRUST-11`
- `LIGHT-04`
- `LIGHT-05`
- `DEFER-01`

### Contradiction IDs

- `C-004`
- `C-005`
- `C-006`
- `C-007`
- `C-009`
- `C-012`

## Block-Tag Boundary

### Intended behavior

| Trusted-mode tag | Meaning |
| --- | --- |
| `latest` | current canonical local head |
| `pending` | compatibility alias of `latest` |
| `safe` | compatibility alias of `latest` |
| `finalized` | compatibility alias of `latest` |
| `earliest` | block `0` |
| numeric quantity | exact local block number |

| Light-mode tag | Meaning |
| --- | --- |
| `latest` | latest verified optimistic execution head |
| `safe` | consensus-backed safe head derived from the optimistic light-client head |
| `finalized` | consensus-finalized execution head |
| `earliest` | block `0` |
| numeric quantity | block `0`, or an exact block inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify that exact execution block and the requested proof-backed read against that block's state root |
| `pending` | unsupported |

- Trusted-mode `pending`, `safe`, and `finalized` are compatibility aliases only. They do not imply finality.
- Real `safe` and `finalized` semantics belong to light mode.
- `ready = true` only when `status = "synced"` and ZEVM can serve proof-backed reads.
- While `ready = false`, ZEVM serves no proof-backed reads and fails them with `-32011`.
- Once ready, numeric selectors are supported only for block `0` and for exact blocks inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify the exact execution block and the requested proof-backed read against that block's state root.
- If light mode is ready in general but the requested numeric block is outside that retained verified-history window, the request fails with `-32602`.
- Verification failures for otherwise-supported light-mode reads follow the proof-backed read error contract in `docs/specs/json-rpc-contract.md` rather than redefining the selector boundary.
- Light mode does not promise arbitrary checkpoint-to-head historical archive reads.

### Observed code constraints

- On 2026-03-29, helper code in `src/rpc/handlers/block_spec.zig` and `src/rpc/block_queries.zig` still aliases trusted-mode `pending`, `safe`, and `finalized` to the current head.
- On 2026-03-29, the light-mode query bridge is still missing, so the light-mode tag semantics are not yet wired into the executable path.
- On 2026-03-29, current `HEAD` also has no live retained-history numeric-selector implementation and therefore no executable `-32011` versus `-32602` split for proof-backed reads.
- On 2026-03-29, the public docs must keep the trusted-mode alias behavior separate from the real light-mode consensus tags.

### Unresolved ambiguity

- None about the intended tag meanings or the canonical alias split.
- The unresolved work is the light-mode execution and query bridge, not the meaning of the tags themselves.

### Affected public pages

- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`

### Source IDs

- `TRUST-04`
- `TRUST-08`
- `LIGHT-05`
- `RPC-TAGS-LIGHT`

### Contradiction IDs

- `C-012`

### Internal support docs

- `docs/specs/json-rpc-contract.md`
- `docs/specs/internal/rpc-support-matrix.md`
- `docs/specs/internal/transport-and-error-semantics.md`

### Notes

- Exact method inventories, alias mappings, block selectors, and error behavior are authoritative only in `docs/specs/json-rpc-contract.md`.
