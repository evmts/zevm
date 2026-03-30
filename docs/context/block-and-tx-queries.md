# Context: block-and-tx-queries

## Ticket Info
- Ticket ID: `block-and-tx-queries`
- Category: `cat-5-block-queries`
- Goal: implement read-only block/transaction/receipt/log JSON-RPC methods for historical chain queries.

## Methods In Scope
- `eth_getBlockByNumber(blockTag, fullTxs)`
- `eth_getBlockByHash(hash, fullTxs)`
- `eth_getTransactionByHash(hash)`
- `eth_getTransactionReceipt(hash)`
- `eth_getBlockReceipts(blockTagOrHash)`
- `eth_getLogs(filter)`
- `eth_getBlockTransactionCountByNumber(blockTag)`
- `eth_getBlockTransactionCountByHash(hash)`
- `eth_getTransactionByBlockHashAndIndex(hash, index)`
- `eth_getTransactionByBlockNumberAndIndex(blockTag, index)`

## Current ZEVM State (What Exists Today)

### `src/block_builder.zig`
- `buildBlock(...)` executes txs and returns:
  - `receipts: []primitives.Receipt.Receipt`
  - `total_gas_used`
  - `block_number`
- Receipts are produced, but there is no persistent receipt/query index in ZEVM yet.

### `src/database/database.zig`
- Current `Database` fields:
  - `state: state_manager.StateManager`
  - `accounts`
  - `contracts`
  - `block_hashes`
- No persisted block/tx/receipt/log query layer in this file yet.

### `src/database/block_hashes.zig`
- Number -> hash map used for EVM `BLOCKHASH` opcode behavior.
- Not a historical block query database.

### `src/tx_processor.zig`
- Produces `primitives.Receipt.Receipt` and event logs during execution.
- Good source of receipt/log data before persistence.

## Upstream Dependencies (Do Not Reinvent)

### Voltaire: Blockchain Storage and Primitives

#### `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`
- Core block storage:
  - `putBlock`
  - `getBlock`
  - `getBlockByNumber`
  - `getCanonicalHash`
  - `setCanonicalHead`
- Tracks canonical chain and orphan blocks.
- No dedicated receipt/log index in this module.

#### `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`
- Unified local store + optional fork cache:
  - `getBlockByHash`
  - `getBlockByNumber`
  - `getCanonicalHash`
  - `putBlock`
  - `setCanonicalHead`
  - `getBlockLocal`
  - `getBlockByNumberLocal`
- This is the right block-history substrate for ZEVM query methods.

#### `../voltaire/packages/voltaire-zig/src/primitives/Receipt/Receipt.zig`
- Receipt model already contains fields needed for RPC projection:
  - tx hash/index
  - block hash/number
  - sender/to/contract address
  - gas used/cumulative gas/effective gas price
  - logs/logs bloom
  - `status` or `root`
  - tx `type`
  - blob fields (`blob_gas_used`, `blob_gas_price`)

#### `../voltaire/packages/voltaire-zig/src/primitives/EventLog/EventLog.zig`
- Event log model includes:
  - `address`
  - `topics`
  - `data`
  - optional block/tx/log index metadata
  - `removed`

### Voltaire: JSON-RPC Type Layer Exists, But Is Minimal

Method files exist for all target endpoints under:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByNumber/eth_getBlockByNumber.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByHash/eth_getBlockByHash.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionReceipt/eth_getTransactionReceipt.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockReceipts/eth_getBlockReceipts.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getLogs/eth_getLogs.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockTransactionCountByNumber/eth_getBlockTransactionCountByNumber.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockTransactionCountByHash/eth_getBlockTransactionCountByHash.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockHashAndIndex/eth_getTransactionByBlockHashAndIndex.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockNumberAndIndex/eth_getTransactionByBlockNumberAndIndex.zig`

Important current limitation:
- The type system is mostly pass-through JSON wrappers today:
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig`
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockTag.zig`
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockSpec.zig`
- Many method `Result` models are still generic wrappers rather than rich RPC response structs.
- If strong typing is needed, add missing type richness upstream in voltaire first.

### Guillotine-mini Reality Check
- Prompt references `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/`.
- Those paths are not present in this workspace.
- Available upstream is `../guillotine-mini`, which includes EVM and `execution-apis` mirror content.
- For this ticket, required primitives/storage are already in voltaire + ZEVM integration code.

## Spec and Conformance Sources

### ZEVM Product Scope
- `docs/specs/prd.md`
  - Confirms this ticket is part of block/tx query feature set.
  - Reinforces "thin integration layer" and upstream-first rule.

### Execution API Definitions
- `execution-apis/src/eth/block.yaml`
- `execution-apis/src/eth/transaction.yaml`
- `execution-apis/src/eth/filter.yaml`

These define parameter/result schemas for:
- block lookups
- tx lookups
- receipts
- logs filtering

### Execution API Test Vectors (Primary Compatibility Target)
- `execution-apis/tests/eth_getBlockByNumber/`
- `execution-apis/tests/eth_getBlockByHash/`
- `execution-apis/tests/eth_getTransactionByHash/`
- `execution-apis/tests/eth_getTransactionReceipt/`
- `execution-apis/tests/eth_getBlockReceipts/`
- `execution-apis/tests/eth_getLogs/`
- `execution-apis/tests/eth_getBlockTransactionCountByNumber/`
- `execution-apis/tests/eth_getBlockTransactionCountByHash/`
- `execution-apis/tests/eth_getTransactionByBlockHashAndIndex/`
- `execution-apis/tests/eth_getTransactionByBlockNumberAndIndex/`

Observed expected behavior from vectors:
- Not found block/tx/receipt returns `null`.
- `eth_getBlockByNumber` supports tags including `latest`, `earliest`, `safe`, `finalized`.
- `eth_getTransactionByHash` returns typed tx objects for legacy/2930/1559/4844/7702 shapes.
- `eth_getTransactionReceipt` includes:
  - `root` on pre-Byzantium style receipts
  - `status` on post-Byzantium style receipts
  - blob fields on blob tx receipts
- `eth_getBlockReceipts`:
  - can return `[]` for existing empty blocks (e.g. genesis/earliest)
  - returns `null` when block is missing
- `eth_getLogs` filter validation:
  - `blockHash` with `fromBlock` or `toBlock` should error (`-32602`)
  - reversed ranges should error (`-32602`)
  - range extending past current head should error (`-32602`) in this suite
- Topic matching includes wildcard and positional matching behavior.

### EIPs (Normative Semantics)
- `https://eips.ethereum.org/EIPS/eip-1474`
  - Quantity/data encoding rules.
  - JSON-RPC error code conventions.
  - `eth_getLogs` note: `blockhash` mutually exclusive with range fields.
- `https://eips.ethereum.org/EIPS/eip-234`
  - `blockHash` filter option rationale and exclusivity with `fromBlock`/`toBlock`.
- `https://eips.ethereum.org/EIPS/eip-1898`
  - Canonical block selector object semantics (`blockHash` / `blockNumber` / `requireCanonical`) for block-spec patterns.
- `https://eips.ethereum.org/EIPS/eip-658`
  - Receipt status replacing intermediate state root post-Byzantium.
- Typed tx/receipt envelope implications:
  - `https://eips.ethereum.org/EIPS/eip-2718`
  - `https://eips.ethereum.org/EIPS/eip-2930`
  - `https://eips.ethereum.org/EIPS/eip-1559`
  - `https://eips.ethereum.org/EIPS/eip-4844`
  - `https://eips.ethereum.org/EIPS/eip-7702`

### Execution Specs (Data-Structure Grounding)
- `execution-specs/src/ethereum/`
  - Receipt construction and encoding by fork.
  - `logs_bloom` behavior.
  - Receipts trie commitments in block validity.

### Hive Compatibility Harness
- `hive/simulators/ethereum/rpc-compat/README.md`
  - RPC compatibility simulator uses execution-apis conformance vectors.
  - This is the black-box compatibility target after local tests.

## Reference Implementations (Behavioral Guidance)

### Hardhat EDR (Rust)
- `edr/crates/edr_provider/src/requests/eth/blocks.rs`
- `edr/crates/edr_provider/src/requests/eth/transactions.rs`
- `edr/crates/edr_provider/src/requests/eth/filter.rs`

Notable behavior patterns:
- `None` for not-found block/tx/receipt paths.
- Post-merge block-tag validation helper usage.
- Pending-block handling for block and tx-by-block methods.
- Log filter criteria normalization and blockHash exclusivity checks.

### Foundry Anvil (Rust)
- `foundry/crates/anvil/src/eth/api.rs`
- `foundry/crates/anvil/src/eth/backend/mem/mod.rs`
- `foundry/crates/anvil/src/eth/backend/fork.rs`

Notable behavior patterns:
- Methods map closely to ticket scope.
- Local-first then fork fallback for block/tx/receipt/log reads.
- `transaction_receipt` and `block_receipts` return `None` when absent.
- `logs` path distinguishes blockHash-specific queries vs range queries.
- Canonicality checks in receipt/block-receipt lookup flows.

### TEVM (TypeScript)
- `../tevm-monorepo/packages/actions/src/eth/ethGetBlockByNumberProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetBlockByHashProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionByHashProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionReceipt.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionReceiptProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetBlockReceiptsHandler.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetBlockReceiptsProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetLogsHandler.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetLogsProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetBlockTransactionCountByHashProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetBlockTransactionCountByNumberProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionByBlockHashAndIndexProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionByBlockNumberAndIndexProcedure.js`

Notable behavior patterns:
- Canonicality guard before returning locally derived receipts in some paths.
- Fork fallback for logs/receipts in hybrid mode.
- Topic wildcard and topic array matching behavior covered in specs/tests.

## Required Storage and Indexing for ZEVM

To satisfy all in-scope methods efficiently, ZEVM needs persistence beyond `block_hashes`:

### 1. Block persistence
- Reuse `blockchain.Blockchain` from voltaire for:
  - block by hash
  - canonical block by number
  - canonical hash by number

### 2. Transaction lookup indexes
- `tx_hash -> {block_hash, block_number, tx_index}`
- `(block_hash, tx_index) -> tx_hash` or direct tx reference
- `(block_number, tx_index)` resolved via canonical hash + block body

### 3. Receipt persistence
- `tx_hash -> receipt`
- `block_hash -> ordered receipts` or `block_hash -> ordered tx_hashes` + tx-hash receipt map

### 4. Log indexing
- Keep logs with full metadata needed by RPC projection.
- Maintain indexes to avoid full-chain scans for `eth_getLogs`:
  - block-number range index (`block -> [log_id_start, log_id_end]`)
  - address index (`address -> sorted log ids`)
  - topic index (`topic -> sorted log ids`, then verify positional constraints)
- Preserve deterministic output order:
  - `(blockNumber, transactionIndex, logIndex)`

### 5. Canonicality/reorg handling
- Query endpoints should return canonical data by default.
- If reorg support is added, indexes must support canonical rewrites for affected heights.

## Method-by-Method Query Plan

### `eth_getBlockByNumber(blockTag, fullTxs)`
1. Resolve block tag/number.
2. Read canonical block.
3. Return `null` if missing.
4. Return tx hashes or full tx objects based on `fullTxs`.

### `eth_getBlockByHash(hash, fullTxs)`
1. Read block by hash.
2. Return `null` if missing.
3. Same tx hydration toggle as above.

### `eth_getTransactionByHash(hash)`
1. Resolve tx location via tx-hash index.
2. Read containing block + tx at index.
3. Return `null` if not found.
4. Project typed tx fields (legacy/2930/1559/4844/7702).

### `eth_getTransactionReceipt(hash)`
1. Resolve receipt by tx hash.
2. Return `null` if not found.
3. Include logs and status/root semantics per fork.

### `eth_getBlockReceipts(blockTagOrHash)`
1. Resolve block hash from hash/number/tag.
2. Return `null` for missing block.
3. Return ordered receipt array (can be empty for existing block with zero txs).

### `eth_getLogs(filter)`
1. Validate filter:
  - `blockHash` must not be combined with `fromBlock`/`toBlock`.
  - reject reversed ranges.
  - reject range beyond current head if following execution-apis vectors.
2. Resolve candidate blocks:
  - single block from `blockHash`, or range from tags/numbers.
3. Use indexes to get candidate logs.
4. Apply address/topic predicates with positional semantics.
5. Return logs in canonical order, `removed: false`.

### `eth_getBlockTransactionCountByNumber/Hash`
1. Resolve block.
2. Return `null` when missing.
3. Return tx count as hex quantity.

### `eth_getTransactionByBlockHashAndIndex / ...ByBlockNumberAndIndex`
1. Resolve block by hash or tag/number.
2. Bounds-check index.
3. Return tx object or `null`.

## Conformance and Test Plan

Primary compatibility vectors to run:
- `execution-apis/tests/eth_getBlockByNumber/*`
- `execution-apis/tests/eth_getBlockByHash/*`
- `execution-apis/tests/eth_getTransactionByHash/*`
- `execution-apis/tests/eth_getTransactionReceipt/*`
- `execution-apis/tests/eth_getBlockReceipts/*`
- `execution-apis/tests/eth_getLogs/*`
- `execution-apis/tests/eth_getBlockTransactionCountByNumber/*`
- `execution-apis/tests/eth_getBlockTransactionCountByHash/*`
- `execution-apis/tests/eth_getTransactionByBlockHashAndIndex/*`
- `execution-apis/tests/eth_getTransactionByBlockNumberAndIndex/*`

Black-box compatibility target:
- `hive/simulators/ethereum/rpc-compat`

## Upstream-First Gaps To Address

If implementation needs richer compile-time RPC models:
- Add/expand strongly-typed RPC request/response structs in voltaire `jsonrpc` module for the in-scope methods.
- Keep ZEVM as orchestration/wiring layer, not a duplicate JSON-RPC type system.

If reusable receipt/log index logic becomes broadly useful:
- Consider adding a shared receipt/log index module upstream (voltaire), then consume it in ZEVM.

## Path Coverage Checklist

The following requested reference roots were covered during research:
- `docs/specs/`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/`
- `../voltaire/packages/voltaire-zig/src/state-manager/`
- `../voltaire/packages/voltaire-zig/src/blockchain/`
- `../voltaire/packages/voltaire-zig/src/evm/`
- `edr/crates/edr_provider/src/requests/`
- `foundry/`
- `hardhat/`
- `../tevm-monorepo/packages/actions/src/`
- `execution-apis/`
- `execution-specs/src/ethereum/`
- `ethereum-tests/`
- `execution-spec-tests/tests/`
- `EIPs/EIPS/`
- `consensus-specs/specs/`
- `yellowpaper/`
- `hive/simulators/ethereum/`

Requested but not present in this workspace:
- `../bench/guillotine-mini/client/rpc/`
- `../bench/guillotine-mini/client/engine/`

Closest available upstream path:
- `../guillotine-mini/`
