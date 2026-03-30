# Debug, Tracing, Filters, And Subscriptions

> **Archived / non-normative:** This issue is historical context only. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md).


## Gap At Time Of Filing

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

## Historical Resolution Criteria

The items below were closure criteria for this issue and are not assertions about current implementation status.

- Tracing APIs would return geth-style struct logs for success, revert, and out-of-gas cases.
- Filter lifecycle would work across logs, blocks, and pending txs with incremental polling semantics.
- WebSocket subscriptions would work for heads, logs, and pending transactions.
- Snapshot/revert and local reorgs would propagate correct `removed` semantics to filters and subscriptions.
- `eth_getLogs` would reject malformed filters instead of silently broadening them or returning `[]`.
