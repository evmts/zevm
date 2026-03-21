# Block, Transaction, And Log Queries

## Verified Gap

- These handlers are not on the runnable node path.
- `eth_getTransactionByHash` is still a stub returning `null`.
- Block hydration is placeholder-backed: tx hashes, sender, nonce, gas, value, input, and related metadata are fabricated or zeroed.
- Receipt/log conversion drops payload data (`data`, `topics`) and substitutes zero hashes/defaults in nullable fields.
- Query helpers depend on `ReceiptIndex` and `LogIndex`, but production code never populates those indexes after mined blocks.
- Many parse/query failures are flattened into `null` or `[]`, and invalid filter quantities are silently widened via `catch null`.

## Evidence

- `src/rpc/handlers/block_query_handlers.zig`
- `src/rpc/block_queries.zig`
- `src/tx_processor.zig`
- `src/receipt_index.zig`
- `src/log_index.zig`

## Resolution Verification

- `eth_getBlockByNumber` / `eth_getBlockByHash` return canonical blocks with exact tx hydration.
- `eth_getTransactionByHash` returns mined txs with exact submitted fields.
- `eth_getTransactionReceipt` / `eth_getBlockReceipts` preserve exact status, gas, logs, topics, and data.
- `eth_getLogs` supports block range, `blockHash`, address arrays, topic ORs, and correct error mapping.
- Queries remain correct after multiple blocks, empty blocks, reverted executions, and snapshot/revert flows.
