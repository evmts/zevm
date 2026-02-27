# Context: `add-transaction-response-type-to-voltaire`

## Ticket
- **ID**: `add-transaction-response-type-to-voltaire`
- **Category**: `cat-5-block-queries`
- **Goal**: In `../voltaire/packages/voltaire-zig/src/jsonrpc/`, add a `TransactionResponse` type for `eth_getTransactionByHash` that extends the transaction payload with mined/pending metadata (`blockHash`, `blockNumber`, `transactionIndex`, `from`), then update these result types:
  - `eth_getTransactionByHash.zig`
  - `eth_getTransactionByBlockHashAndIndex.zig`
  - `eth_getTransactionByBlockNumberAndIndex.zig`

## Current Voltaire State (what exists now)

### JSON-RPC method files are placeholders
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockHashAndIndex/eth_getTransactionByBlockHashAndIndex.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockNumberAndIndex/eth_getTransactionByBlockNumberAndIndex.zig`

All three currently define:
- `pub const Result = struct { value: types.Quantity, ... }`

### Shared JSON-RPC types are minimal
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig`
- currently exports only:
  - `Address`
  - `Hash`
  - `Quantity`
  - `BlockTag`
  - `BlockSpec`

No transaction response object type exists yet.

### Primitive transaction/receipt context available upstream
- `../voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig`
  - has legacy/2930/1559/4844/7702 transaction structs + signing/hash helpers.
  - no ready-made JSON-RPC transaction response model.
- `../voltaire/packages/voltaire-zig/src/primitives/Receipt/Receipt.zig`
  - includes mined metadata that overlaps RPC response metadata:
    - `transaction_hash`
    - `transaction_index`
    - `block_hash`
    - `block_number`
    - `sender` (`from`)

### Blockchain storage implications
- `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`

These store/retrieve blocks by hash/number and canonical mapping, but there is no dedicated transaction-hash index type at this layer.

## Canonical RPC Shape (spec and tests)

### Execution API spec (primary source)
- `execution-apis/src/eth/transaction.yaml`
- `execution-apis/src/schemas/transaction.yaml`

Key points:
- `eth_getTransactionByHash`, `eth_getTransactionByBlockHashAndIndex`, and `eth_getTransactionByBlockNumberAndIndex` all return:
  - `oneOf: notFound | TransactionInfo`
- `TransactionInfo` = contextual metadata + signed transaction shape.
- contextual required fields in schema:
  - `blockHash`
  - `blockNumber`
  - `blockTimestamp`
  - `from`
  - `hash`
  - `transactionIndex`

### Execution API tests (direct vectors)
- `execution-apis/tests/eth_getTransactionByHash/get-legacy-tx.io`
- `execution-apis/tests/eth_getTransactionByHash/get-access-list.io`
- `execution-apis/tests/eth_getTransactionByHash/get-dynamic-fee.io`
- `execution-apis/tests/eth_getTransactionByHash/get-blob-tx.io`
- `execution-apis/tests/eth_getTransactionByHash/get-setcode-tx.io`
- `execution-apis/tests/eth_getTransactionByHash/get-notfound-tx.io`
- `execution-apis/tests/eth_getTransactionByBlockHashAndIndex/get-block-n.io`
- `execution-apis/tests/eth_getTransactionByBlockNumberAndIndex/get-block-n.io`

Observed behavior from vectors:
- Not found => `result: null`.
- Valid responses include typed transaction variants (`type` `0x0`/`0x1`/`0x2`/`0x3`/`0x4`) and include:
  - `blockHash`
  - `blockNumber`
  - `blockTimestamp`
  - `from`
  - `transactionIndex`
  - plus tx fields/signature fields (`v/r/s`, and where applicable `yParity`, fee fields, access list, blob fields, authorization list).

### EIP-1474 method semantics
- `EIPs/EIPS/eip-1474.md`

For all 3 methods:
- return type is `null|object`.
- transaction object includes `blockHash`, `blockNumber`, `from`, `transactionIndex`, and core tx fields.
- pending semantics: `blockHash`/`blockNumber`/`transactionIndex` can be `null` when pending.

## Reference client behavior

### Hardhat EDR (Rust) - strongest behavioral reference in this checkout
- `edr/crates/edr_provider/src/requests/eth/transactions.rs`
- `edr/crates/edr_provider/src/data.rs`
- `edr/crates/edr_chain_l1/src/rpc/transaction.rs`
- `edr/crates/edr_provider/src/requests/methods.rs`

Observed behavior:
- all three handlers return `Result<Option<RpcTransaction>>` (JSON `null` when not found).
- `transaction_by_hash` checks mempool first, then mined chain.
- RPC tx type includes optional block metadata for pending:
  - `block_hash: Option<_>`
  - `block_number: Option<_>`
  - `transaction_index: Option<_>`
- `from` is always present and derived from signer/caller.

### Foundry Anvil
- `foundry/crates/anvil/src/eth/api.rs`
- `foundry/crates/anvil/src/eth/backend/mem/mod.rs`

Observed behavior:
- `transaction_by_hash`, `transaction_by_block_hash_and_index`, `transaction_by_block_number_and_index` return `Option<AnyRpcTransaction>`.
- missing transaction => `None` => JSON `null`.
- pending tx path sets no block metadata (`None`), mined path sets `block_hash`, `block_number`, `transaction_index`.
- `from` comes from recovered signer / pending sender.

### TEVM (TypeScript)
- `../tevm-monorepo/packages/actions/src/common/TransactionResult.ts`
- `../tevm-monorepo/packages/actions/src/utils/txToJsonRpcTx.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionByHashProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionByBlockHashAndIndexProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionByBlockNumberAndIndexProcedure.js`

Observed behavior:
- response shape includes `blockHash`, `blockNumber`, `from`, `transactionIndex` + tx fields.
- `eth_getTransactionByHash` returns `null` when not found.
- by-block methods currently return `-32602` on missing tx (diverges from execution-apis vectors that use `null`).

### Hive simulator artifacts
- `hive/simulators/ethereum/graphql/testcases/27_eth_getTransaction_byBlockHashAndIndex.json`
- `hive/simulators/ethereum/graphql/testcases/28_eth_getTransaction_byBlockNumberAndIndex.json`
- `hive/simulators/ethereum/graphql/testcases/29_eth_getTransaction_byBlockNumberAndInvalidIndex.json`
- `hive/simulators/ethereum/graphql/testcases/30_eth_getTransaction_byHash.json`
- `hive/simulators/ethereum/graphql/testcases/31_eth_getTransaction_byHashNull.json`

Observed behavior (GraphQL side):
- found transaction returns object.
- missing hash/index returns `null`.

## Sender (`from`) derivation references

### Execution specs reference implementation
- `execution-specs/src/ethereum/forks/amsterdam/transactions.py`

Key functions:
- `recover_sender(chain_id, tx)` covers legacy/2930/1559/4844/7702 signature recovery.
- `get_transaction_hash(tx)` defines tx hash derivation.

Use this as canonical behavior reference for sender recovery when only signed tx data is available.

### Yellow paper formal references
- `yellowpaper/Paper.tex`

Useful anchors for formal model:
- transaction signature fields and sender function `S(T)`
- ECDSA recovery definitions in signing appendix

## Execution-spec-tests usage expectations
- `execution-spec-tests/src/ethereum_test_rpc/rpc_types.py`
- `execution-spec-tests/src/ethereum_test_rpc/rpc.py`
- `execution-spec-tests/src/pytest_plugins/execute/rpc/chain_builder_eth_rpc.py`

Observed expectation:
- `eth_getTransactionByHash` may return pending transaction object where `block_number` is `null` until mined, then non-null.

## Path audit summary for requested reference roots

### Directly relevant and used
- `docs/specs/`
  - `docs/specs/prd.md` (project requirement context).
- `../voltaire/packages/voltaire-zig/src/jsonrpc/`
- `../voltaire/packages/voltaire-zig/src/state-manager/`
- `../voltaire/packages/voltaire-zig/src/blockchain/`
- `../voltaire/packages/voltaire-zig/src/evm/`
- `edr/crates/edr_provider/src/requests/`
- `foundry/`
- `hardhat/` (checked, no directly useful tx handler implementation in this checkout)
- `../tevm-monorepo/packages/actions/src/`
- `execution-apis/`
- `execution-specs/src/ethereum/`
- `execution-spec-tests/tests/` (plus `src/ethereum_test_rpc` for tx response models)
- `EIPs/EIPS/`
- `consensus-specs/specs/` (execution payload metadata context only)
- `yellowpaper/`
- `hive/simulators/ethereum/`

### Important path mismatch discovered
- Requested path: `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/`
- In this workspace, `../bench/guillotine-mini` does not exist.
- Existing repo is `../guillotine-mini`, but current checkout does not contain `client/rpc` or `client/engine` directories even though `../guillotine-mini/build.zig` references them.
- Result: no direct guillotine-mini RPC handler code was available for this ticket in current filesystem state.

## Implementation-critical takeaways for this ticket

1. Result type must support `null` (not found) for all three methods.
2. Metadata fields required by ticket (`blockHash`, `blockNumber`, `transactionIndex`, `from`) match canonical object shape.
3. Pending semantics matter:
- for pending txs, block metadata fields should be nullable.
4. Typed tx variants (legacy/2930/1559/4844/7702) must remain representable in the response shape.
5. `execution-apis` currently includes `blockTimestamp` in `TransactionInfo`; ticket text does not request it explicitly. This is a likely scope decision to confirm before implementation.

## Black-box tests to port/replicate for ZEVM integration
- `execution-apis/tests/eth_getTransactionByHash/get-notfound-tx.io`
- `execution-apis/tests/eth_getTransactionByHash/get-legacy-tx.io`
- `execution-apis/tests/eth_getTransactionByHash/get-access-list.io`
- `execution-apis/tests/eth_getTransactionByHash/get-dynamic-fee.io`
- `execution-apis/tests/eth_getTransactionByHash/get-blob-tx.io`
- `execution-apis/tests/eth_getTransactionByHash/get-setcode-tx.io`
- `execution-apis/tests/eth_getTransactionByBlockHashAndIndex/get-block-n.io`
- `execution-apis/tests/eth_getTransactionByBlockNumberAndIndex/get-block-n.io`

These vectors directly validate the response type shape this ticket is introducing.
