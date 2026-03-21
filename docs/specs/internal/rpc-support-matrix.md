# ZEVM Internal Support: RPC Support Matrix

Last updated: 2026-03-21

## Canonical Transport

| Surface | Intended contract | Current repo reality | Status |
| --- | --- | --- | --- |
| HTTP listener | one canonical HTTP JSON-RPC transport on `/`, configurable by `--host` and `--port` | the executable path points at `src/rpc/server.zig`, but the transport still depends on a broken upstream `jsonrpc.envelope` path | `contradiction` |
| notifications | requests with no `id` produce no response; notification-only batches return no response body | both in-tree transport paths currently serialize responses for notification-shaped requests | `contradiction` |
| standard JSON-RPC errors | `-32700`, `-32600`, `-32601`, `-32602`, `-32603` | current validation is shallow and downstream failures often collapse to `-32603` | `contradiction` |

- source IDs: `RPC-01`, `RPC-02`, `RPC-03`
- contradiction IDs: `C-002`, `C-010`

## Trusted-Mode Methods

| Method or group | Intended contract | Current repo reality | Status |
| --- | --- | --- | --- |
| `eth_chainId`, `eth_blockNumber` | supported in trusted mode | minimal helper coverage exists but not as a finished shipping runtime | `prototype gap` |
| `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount` | supported against trusted state | richer handlers exist but are unwired; `eth_getCode` is incorrect | `contradiction` |
| `eth_accounts`, `eth_coinbase`, `eth_gasPrice`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee`, `eth_feeHistory` | supported with trusted defaults | prototype support exists, but not on the executable path | `prototype gap` |
| `eth_call`, `eth_estimateGas` | supported with checkpoint-and-revert semantics | no implementation found | `contradiction` |
| `eth_sendTransaction`, `eth_sendRawTransaction` | supported with nonce-aware pending behavior | prototype exists but depends on runtime fields that do not exist | `contradiction` |
| automine/manual/interval mining | supported | config and coordinator prototypes are disconnected from startup/runtime | `contradiction` |
| `eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_getBlockReceipts`, `eth_getLogs` | supported against canonical trusted chain data | prototypes are unwired and still contain placeholders or stubs | `contradiction` |
| `evm_snapshot`, `evm_revert` | supported with the full PRD snapshot boundary | prototype exists but captures a narrower subset of state | `prototype gap` |
| Hardhat/Anvil state mutation methods | supported | a subset exists in `src/rpc/dev_handlers.zig`, but not in the executable path | `prototype gap` |
| impersonation and time controls | supported | not found in `src/` | `contradiction` |

- source IDs: `RPC-04`, `RPC-05`, `RPC-06`, `TRUST-01`, `TRUST-02`, `TRUST-03`, `TRUST-04`
- contradiction IDs: `C-003`, `C-004`, `C-005`, `C-006`, `C-007`, `C-008`, `C-009`

## Light-Mode Methods

| Method or group | Intended contract | Current repo reality | Status |
| --- | --- | --- | --- |
| `zevm_lightSyncStatus` | supported in light mode with the documented status payload | no public RPC method exists | `contradiction` |
| `eth_chainId`, `eth_blockNumber` | supported in light mode | no light-mode runtime is wired | `contradiction` |
| `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount` | supported only when backed by verified proofs | no proof-backed read bridge exists | `contradiction` |
| `safe` and `finalized` tags | consensus-derived in light mode | no light-mode query bridge exists | `contradiction` |

- source IDs: `LIGHT-04`, `LIGHT-05`
- contradiction IDs: `C-011`, `C-012`

## Deferred Surfaces

| Surface | Intended contract | Current repo reality | Status |
| --- | --- | --- | --- |
| `debug_traceCall`, `debug_traceTransaction` | deferred until core trusted-mode and light-mode surfaces stabilize | no shipping surface found | `deferred` |
| filter lifecycle APIs | deferred | no shipping surface found | `deferred` |
| subscriptions | deferred | no shipping surface found | `deferred` |
| WebSocket transport | deferred | no shipping surface found | `deferred` |

- source IDs: `RPC-07`
