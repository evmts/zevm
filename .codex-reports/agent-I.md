# Agent I — Block-Query RPC Handlers

## Files Touched
- `/Users/williamcory/zevm/src/rpc/block_queries.zig`
- `/Users/williamcory/zevm/src/rpc/handlers/block_query_handlers.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` (added missing pub re-exports for typed handlers)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockTransactionCountByNumber/eth_getBlockTransactionCountByNumber.zig` (parser used `Quantity` to assign to `BlockSpec` field — fixed)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getUncleCountByBlockNumber/eth_getUncleCountByBlockNumber.zig` (Params field was `Quantity`, spec is `BlockSpec` — fixed)

## Behavior Now Implemented

### eth_getTransactionByHash
Was a hard-coded null stub. Now calls a new
`block_queries.getTransactionByHash` which uses the receipt index to find the
containing block and tx index, then synthesizes a `TxResponse`.

Receipt-derived fields populated: hash, blockHash, blockNumber,
transactionIndex, from, to, type (legacy/eip2930/eip1559/eip4844/eip7702),
gasPrice (legacy/2930) or maxFeePerGas (1559+) sourced from
`effective_gas_price`, maxFeePerBlobGas (4844) sourced from `blob_gas_price`,
gas (saturated from receipt.gas_used), and the raw envelope bytes are
exposed as `input` so callers at least see the on-wire transaction. Unknown
hash → JSON `null` (never `-32601`).

### Receipt log topics + data
`internalReceiptToRpc` no longer drops topics/data. Each `LogEntry` now
encodes 32-byte topics as proper `Hash` values and the raw data as `0x`-prefixed
hex bytes. The whole receipt mapping was rewritten because the previous code
did not match `jsonrpc.types.ReceiptResponse` — fields like `tx_type`,
integer-typed `cumulativeGasUsed`, and raw `[256]u8` `logsBloom` did not
exist on the actual struct.

### Block tx hydration
`block_queries.blockToResponse` now derives each tx's hash via
`keccak256(raw)` for the non-hydrated form, and for hydrated form populates
a richer `TxResponse` per tx (with type detection from the envelope byte,
plus hash). Receipt-derived fields are not threaded through the block path
because `blockToResponse` does not see receipts; the per-tx fidelity gap
is documented below.

### eth_getBlockTransactionCountByHash / ByNumber
New handlers. Use `block_queries.getBlockTxCountByHash/ByNumber`. Return
hex count or `null` when the block is missing.

### eth_getUncleCountByBlockHash / ByNumber
New handlers. Read `block.body.ommers.len` (always 0 post-Merge); when the
block is missing, the JSON-RPC spec result is non-nullable so we return `0x0`.

### eth_getBlockReceipts hash selector
`handleGetBlockReceipts` now branches on the JSON form of `BlockSpec`:
- `.string` → if it parses as a 32-byte 0x-hex hash use the hash path; else
  treat it as a tag/quantity.
- `.integer` → quantity path.
- `.object` → accepts `{ "blockHash": ... }` and `{ "blockNumber": ... }`.
Missing block → `null`.

A new `block_queries.getBlockReceiptsByHash` does the actual lookup.

## Skipped / Gaps

- **Transaction decoding.** Voltaire does not export
  `decodeRawTransaction`/`DecodedTransaction` (the existing
  `tx_submission.zig` references them but they don't exist in voltaire). Without
  a decoder we can't recover `nonce`, `value`, `input` (real calldata,
  not envelope), `gasPrice` (signed value), `v/r/s`, signed `chainId`,
  `accessList`, `blobVersionedHashes`, or `authorizationList` for a tx by
  hash. The `TxResponse` carries optional fields for all of these so a
  future tx decoder can populate them without changing the wire shape.
- **Hydrated block tx fidelity.** Same root cause: without a decoder,
  block-hydrated tx objects can only show `hash` + envelope `input` +
  detected `type`. To upgrade we'd either (a) add a decoder, or (b) thread
  `ctx.receipt_index` into the block path and merge receipt-derived fields
  per index. (b) is cheap and could be a quick follow-up.
- **Pruned-history (4444) error code.** Out of scope per task.
- **Filter wiring.** `rpcFilterToInternal` is left as a no-op against the
  current `Quantity`-typed `filter` param (pre-existing; another agent owns
  filters).
- **Voltaire test suite.** I added `pub const` re-exports and fixed two
  generator parser bugs in voltaire methods, but did not regenerate the
  whole spec. These are surgical edits.

## Wiring Note
None of these handlers are wired into the dispatcher — that is explicitly
out of scope. Per repo memory the dispatcher is unwired across the board;
this PR makes the block-query handler module compile cleanly against the
real `jsonrpc.types` and provides the proper handler surface for whoever
wires `dispatch_wiring.zig`.
