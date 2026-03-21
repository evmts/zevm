# Debug, Tracing, Filters, And Subscriptions

## Verified Gap

- `debug_traceCall` and `debug_traceTransaction` are absent.
- Filter lifecycle APIs (`eth_newFilter`, `eth_getFilterChanges`, `eth_getFilterLogs`, `eth_uninstallFilter`, `eth_newBlockFilter`, `eth_newPendingTransactionFilter`) are absent.
- WebSocket transport and `eth_subscribe` / `eth_unsubscribe` are absent; the server is HTTP POST only.
- The only related implementation is helper-level `eth_getLogs`, which is still unwired and has incomplete parsing, payload encoding, and error mapping.
- `LogIndex` is append-only; there is no filter manager, polling cursor, uninstall support, pending/head stream, or reorg/remove path.

## Evidence

- `src/rpc/server.zig`
- `src/rpc/dispatcher.zig`
- `src/rpc/handlers/block_query_handlers.zig`
- `src/log_index.zig`

## Resolution Verification

- Tracing APIs return geth-style struct logs for success, revert, and out-of-gas cases.
- Filter lifecycle works across logs, blocks, and pending txs with incremental polling semantics.
- WebSocket subscriptions work for heads, logs, and pending transactions.
- Snapshot/revert and local reorgs propagate correct `removed` semantics to filters and subscriptions.
- `eth_getLogs` rejects malformed filters instead of silently broadening them or returning `[]`.
