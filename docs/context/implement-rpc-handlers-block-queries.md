# Context: Implement RPC Handlers for Block Query Methods

> Historical archive note: this ticket context reflects a point-in-time implementation plan and can differ from the active ZEVM contract. For current normative payload and method-surface rules (including extension-field policy), use `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md`.

## Ticket Info
- **Ticket ID**: implement-rpc-handlers-block-queries
- **Category**: cat-5-block-queries
- **Goal**: Create RPC handlers for `eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_getBlockReceipts`, `eth_getLogs`. Use voltaire's jsonrpc types and guillotine-mini's RPC dispatch. Return proper response objects per execution-apis spec.

---

## Prerequisites / Dependencies

This ticket builds on:
1. **implement-block-storage-database** — expected dependency state: `Database` includes a `blockchain` field (adds `blockchain.Blockchain` to store blocks)
2. **tx-sending-and-mempool** or equivalent — expected dependency state: receipts are stored at block-commit time
3. **http-jsonrpc-server-and-dispatch** — expected dependency state: RPC dispatch infrastructure exists

---

## What Already Exists — Do Not Reinvent

### 1. voltaire jsonrpc Params types (complete and correct)

**Location:** `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/`

All 6 methods have correct **Params** types already:

```
eth/getBlockByNumber/eth_getBlockByNumber.zig    → Params: block (Quantity), hydrated_transactions (Quantity)
eth/getBlockByHash/eth_getBlockByHash.zig        → Params: block_hash (Hash), hydrated_transactions (Quantity)
eth/getTransactionByHash/eth_getTransactionByHash.zig → Params: transaction_hash (Hash)
eth/getTransactionReceipt/eth_getTransactionReceipt.zig → Params: transaction_hash (Hash)
eth/getBlockReceipts/eth_getBlockReceipts.zig    → Params: block (BlockSpec)
eth/getLogs/eth_getLogs.zig                       → Params: filter (Quantity — STUB placeholder; snapshot proposal uses a proper FilterObject)
```

**Current limitation:** ALL Result types are stubs using `types.Quantity`. The snapshot proposal was to replace them with real response types.

**Key shared types in `../voltaire/packages/voltaire-zig/src/jsonrpc/types/`:**
- `Hash` — 32-byte hex string with jsonStringify/jsonParseFromValue
- `Quantity` — pass-through `std.json.Value` (hex or number)
- `BlockSpec` — pass-through `std.json.Value` (can be tag string or hex number or 32-byte hash)
- `BlockTag` — pass-through `std.json.Value`

### 2. voltaire primitives (fully implemented)

All internal data structures used by this snapshot:

**`primitives.Block.Block`** — `../voltaire/.../primitives/Block/Block.zig`
```zig
pub const Block = struct {
    header: BlockHeader.BlockHeader,
    body:   BlockBody.BlockBody,
    hash:   Hash.Hash,
    size:   u64,
    total_difficulty: ?u256 = null,
};
```
- `Block.from(header, body, allocator) !Block`
- `Block.genesis(chain_id, allocator) !Block`

**`primitives.BlockHeader.BlockHeader`** — `../voltaire/.../primitives/BlockHeader/BlockHeader.zig`
```zig
pub const BlockHeader = struct {
    parent_hash: Hash.Hash,
    ommers_hash: Hash.Hash,
    beneficiary: Address.Address,
    state_root: Hash.Hash,
    transactions_root: Hash.Hash,
    receipts_root: Hash.Hash,
    logs_bloom: [256]u8,
    difficulty: u256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    mix_hash: Hash.Hash,
    nonce: [8]u8,
    base_fee_per_gas: ?u256 = null,        // EIP-1559 London+
    withdrawals_root: ?Hash.Hash = null,   // EIP-4895 Shanghai+
    blob_gas_used: ?u64 = null,            // EIP-4844 Cancun+
    excess_blob_gas: ?u64 = null,          // EIP-4844 Cancun+
    parent_beacon_block_root: ?Hash.Hash = null, // EIP-4844 Cancun+
};
```

**`primitives.BlockBody.BlockBody`** — `../voltaire/.../primitives/BlockBody/BlockBody.zig`
```zig
// Transactions are stored as raw RLP-encoded bytes
pub const TransactionData = struct { raw: []const u8 };
pub const BlockBody = struct {
    transactions: []const TransactionData,
    ommers: []const UncleHeader,
    withdrawals: ?[]const Withdrawal,
};
```
Note: BlockBody stores raw tx bytes — **NOT** decoded transaction structs. Transaction decoding is separate.

**`primitives.Transaction`** — `../voltaire/.../primitives/Transaction/Transaction.zig`
```zig
pub const LegacyTransaction = struct {
    nonce: u64, gas_price: u256, gas_limit: u64,
    to: ?Address, value: u256, data: []const u8,
    v: u64, r: [32]u8, s: [32]u8,
};
pub const Eip1559Transaction = struct {
    chain_id: u64, nonce: u64,
    max_priority_fee_per_gas: u256, max_fee_per_gas: u256,
    gas_limit: u64, to: ?Address, value: u256, data: []const u8,
    access_list: []const AccessListItem, y_parity: u8, r: [32]u8, s: [32]u8,
};
pub const Eip4844Transaction = struct { ... };
pub const Eip7702Transaction = struct { ... };
pub const AccessListItem = struct { address: Address, storage_keys: []const [32]u8 };
```

**`primitives.Receipt.Receipt`** — `../voltaire/.../primitives/Receipt/Receipt.zig`
```zig
pub const TransactionType = enum { legacy, eip2930, eip1559, eip4844, eip7702 };
pub const TransactionStatus = struct { success: bool, gas_used: u256 };
pub const Receipt = struct {
    transaction_hash: Hash,
    transaction_index: u32,
    block_hash: Hash,
    block_number: u64,
    sender: Address,       // NOTE: field is named 'sender' in struct but referred to as 'from' in JSON
    to: ?Address,
    cumulative_gas_used: u256,
    gas_used: u256,
    contract_address: ?Address,
    logs: []const EventLog,
    logs_bloom: [256]u8,
    status: ?TransactionStatus,
    root: ?Hash,           // pre-Byzantium only
    effective_gas_price: u256,
    type: TransactionType,
    blob_gas_used: ?u256,
    blob_gas_price: ?u256,
};
```

**`primitives.EventLog.EventLog`** — `../voltaire/.../primitives/EventLog/EventLog.zig`
```zig
pub const EventLog = struct {
    address: Address,
    topics: []const Hash,
    data: []const u8,
    block_number: ?u64,
    transaction_hash: ?Hash,
    transaction_index: ?u32,
    log_index: ?u32,
    removed: bool,
};
```

### 3. voltaire Blockchain storage (complete API)

**Location:** `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`

```zig
// Read (local → fork cache)
pub fn getBlockByHash(self: *Blockchain, hash: Hash.Hash) !?Block.Block
pub fn getBlockByNumber(self: *Blockchain, number: u64) !?Block.Block
pub fn getCanonicalHash(self: *Blockchain, number: u64) ?Hash.Hash
pub fn getHeadBlockNumber(self: *Blockchain) ?u64

// Local-only (no async fork fetch)
pub fn getBlockLocal(self: *Blockchain, hash: Hash.Hash) ?Block.Block
pub fn getBlockByNumberLocal(self: *Blockchain, number: u64) ?Block.Block

// Write
pub fn putBlock(self: *Blockchain, block: Block.Block) !void
pub fn setCanonicalHead(self: *Blockchain, head_hash: Hash.Hash) !void
```

### 4. ZEVM's existing state

**`src/database/database.zig`** — Current `Database` struct:
```zig
pub const Database = struct {
    state: state_manager.StateManager,
    accounts: @import("accounts.zig").Accounts,
    contracts: @import("contracts.zig").Contracts,
    block_hashes: @import("block_hashes.zig").BlockHashes,
    // After implement-block-storage-database ticket:
    // blockchain: @import("blockchain").Blockchain,
};
```

**`src/block_builder.zig`** — `buildBlock` returns:
```zig
pub const BlockResult = struct {
    receipts: []primitives.Receipt.Receipt,
    total_gas_used: u64,
    block_number: u64,
};
```
Each `Receipt` from `processTransaction` has:
- `transaction_hash` (computed from tx)
- `transaction_index` (0-indexed within block)
- `block_hash = primitives.Hash.ZERO` (placeholder — planned to be updated after block hash is known)
- `block_number` (from block_ctx)
- `sender`, `to`, `gas_used`, `cumulative_gas_used`, etc.

**`src/root.zig`** — Current exports:
```zig
pub const database = @import("database/root.zig");
pub const blockchain = @import("blockchain");
pub const host_adapter = @import("host_adapter.zig");
pub const tx_processor = @import("tx_processor.zig");
pub const block_builder = @import("block_builder.zig");
// ... consensus/beacon modules
```

---

## Snapshot Build Scope

### Phase 1: Storage Additions (zevm)

The snapshot proposal added receipt and transaction-index storage to `Database`:

```zig
// src/database/database.zig additions
pub const TxLocation = struct {
    block_hash: primitives.Hash.Hash,
    transaction_index: u32,
};

pub const Database = struct {
    state: state_manager.StateManager,
    accounts: @import("accounts.zig").Accounts,
    contracts: @import("contracts.zig").Contracts,
    block_hashes: @import("block_hashes.zig").BlockHashes,
    blockchain: @import("blockchain").Blockchain,   // from prerequisite ticket

    // New storage for receipt queries:
    receipts_by_tx_hash: std.AutoHashMapUnmanaged(primitives.Hash.Hash, primitives.Receipt.Receipt),
    receipts_by_block_hash: std.AutoHashMapUnmanaged(primitives.Hash.Hash, std.ArrayListUnmanaged(primitives.Receipt.Receipt)),
    tx_index: std.AutoHashMapUnmanaged(primitives.Hash.Hash, TxLocation),
};
```

In the snapshot plan, these were populated at block-commit time:
```zig
// After block is built and stored:
for (block_result.receipts, 0..) |receipt, i| {
    // Fix placeholder block_hash in receipt
    var r = receipt;
    r.block_hash = block.hash;
    r.transaction_index = @intCast(i);
    try db.receipts_by_tx_hash.put(allocator, r.transaction_hash, r);
    // Also build tx_index for getTransactionByHash
    try db.tx_index.put(allocator, r.transaction_hash, .{
        .block_hash = block.hash,
        .transaction_index = @intCast(i),
    });
}
// Index receipts by block hash for getBlockReceipts + getLogs
try db.receipts_by_block_hash.put(allocator, block.hash, receipts_list);
```

### Phase 2: JSON-RPC Response Types (voltaire)

The snapshot proposal was to add these types to voltaire (we own it) and then use them as Result types in the method files.

**Add to voltaire:** `../voltaire/packages/voltaire-zig/src/jsonrpc/types/`

#### `RpcBlock.zig` — JSON-RPC block response
Per execution-apis, a block response includes:
```json
{
  "number": "0x2d",
  "hash": "0xe27a3e81...",
  "parentHash": "0x4b9d85c6...",
  "sha3Uncles": "0x1dcc4de8...",
  "miner": "0x0000...0000",
  "stateRoot": "0xf618...",
  "transactionsRoot": "0xc541...",
  "receiptsRoot": "0x2c86...",
  "logsBloom": "0x0000...",
  "difficulty": "0x0",
  "totalDifficulty": "0x0",
  "extraData": "0x",
  "size": "0x633",
  "gasLimit": "0x47e7c40",
  "gasUsed": "0x54a92",
  "timestamp": "0x1c2",
  "mixHash": "0x0000...0000",
  "nonce": "0x0000000000000000",
  "baseFeePerGas": "0x5763d64",        // London+
  "withdrawalsRoot": "0x56e8...",      // Shanghai+
  "blobGasUsed": "0x0",               // Cancun+
  "excessBlobGas": "0x0",             // Cancun+
  "parentBeaconBlockRoot": "0x4b11...", // Cancun+
  "requestsHash": "0x57ca...",         // Prague+
  "transactions": [...],               // array of tx hashes OR hydrated tx objects
  "uncles": [],
  "withdrawals": []
}
```

Key observations from test vectors:
- `difficulty` is always `"0x0"` post-merge
- `totalDifficulty` is omitted in dev node (or `"0x0"`)
- `nonce` is always `"0x0000000000000000"` post-merge
- `mixHash` is `"0x0000...0000"` post-merge
- Missing optional fields (e.g. `baseFeePerGas` before London) are **omitted** entirely, not null
- `transactions` is either array of hash strings OR array of tx objects (based on `hydrated` param)
- Historical vector note: `blockTimestamp` appears in some transaction objects as a non-standard extension; this is not part of the current ZEVM contract

#### `RpcTransaction.zig` — JSON-RPC transaction response
From test vectors (`get-legacy-tx.io`):
```json
{
  "blockHash": "0x558340...",
  "blockNumber": "0x2",
  "blockTimestamp": "0x14",
  "from": "0x7435ed...",
  "gas": "0x5208",
  "gasPrice": "0x1",
  "hash": "0x0d6999...",
  "input": "0x",
  "nonce": "0x7",
  "to": "0xeda864...",
  "transactionIndex": "0x3",
  "value": "0x1",
  "type": "0x0",
  "v": "0x1b",
  "r": "0xfad01b...",
  "s": "0x60b08e..."
}
```

For EIP-1559 tx (type=0x2):
- `maxFeePerGas`, `maxPriorityFeePerGas` instead of `gasPrice`
- `accessList: []`
- `yParity` instead of `v`

For EIP-4844 tx (type=0x3):
- All EIP-1559 fields + `maxFeePerBlobGas`, `blobVersionedHashes`

For EIP-7702 tx (type=0x4):
- All EIP-1559 fields + `authorizationList`

For pending transactions (not in a block):
- `blockHash: null`, `blockNumber: null`, `transactionIndex: null`

#### `RpcReceipt.zig` — JSON-RPC receipt response
From test vectors (`get-legacy-receipt.io`):
```json
{
  "blockHash": "0x558340...",
  "blockNumber": "0x2",
  "contractAddress": null,
  "cumulativeGasUsed": "0x3d037",
  "effectiveGasPrice": "0x1",
  "from": "0x7435ed...",
  "gasUsed": "0x5208",
  "logs": [],
  "logsBloom": "0x0000...",
  "root": "0x7e099d...",  // OR "status": "0x1" (never both)
  "to": "0xeda864...",
  "transactionHash": "0x0d6999...",
  "transactionIndex": "0x3",
  "type": "0x0"
}
```

For EIP-4844 receipts:
- Adds `blobGasUsed` and `blobGasPrice`

**Key rules:**
- `status` field: `"0x1"` for success, `"0x0"` for failure (post-Byzantium)
- `root` field: 32-byte hex state root (pre-Byzantium only)
- `contractAddress`: non-null only for contract creation
- `logs`: array of log objects

#### `RpcLog.zig` — JSON-RPC log response
From test vectors (`filter-with-blockHash.io`):
```json
{
  "address": "0x7dcd17...",
  "topics": ["0x000000...656d6974", "0x4238ac..."],
  "data": "0x0000...0001",
  "blockNumber": "0x4",
  "transactionHash": "0xf047c5...",
  "transactionIndex": "0x0",
  "blockHash": "0x29cc6f...",
  "blockTimestamp": "0x28",
  "logIndex": "0x0",
  "removed": false
}
```

Note: `blockTimestamp` is an extension (not in base spec but present in all test vectors).

### Phase 3: Update voltaire Result Types

Update each voltaire method file to use real types instead of `types.Quantity` stub:

**`eth_getBlockByNumber.zig`** and **`eth_getBlockByHash.zig`** Result:
```zig
pub const Result = struct {
    block: ?RpcBlock,  // null if not found

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        if (self.block) |b| {
            try jws.write(b);
        } else {
            try jws.write(null);
        }
    }
};
```

**`eth_getTransactionByHash.zig`** Result:
```zig
pub const Result = struct {
    tx: ?RpcTransaction,  // null if not found
};
```

**`eth_getTransactionReceipt.zig`** Result:
```zig
pub const Result = struct {
    receipt: ?RpcReceipt,  // null if not found
};
```

**`eth_getBlockReceipts.zig`** Result:
```zig
pub const Result = struct {
    receipts: ?[]const RpcReceipt,  // null if block not found
};
```

**`eth_getLogs.zig`** Params update:
```zig
pub const FilterObject = struct {
    from_block: ?std.json.Value = null,  // BlockSpec
    to_block: ?std.json.Value = null,    // BlockSpec
    address: ?std.json.Value = null,     // address or array of addresses
    topics: ?[]const ?[]const ?[32]u8 = null,  // topic filter array
    block_hash: ?[32]u8 = null,          // alternative to from/to range
    // snapshot note: jsonParseFromValue implementation omitted here
};
pub const Result = struct {
    logs: []const RpcLog,
};
```

### Phase 4: ZEVM RPC Handlers

**Location:** `src/rpc_handlers/` (new directory)

#### `block_spec.zig` — Block spec resolution utility

```zig
// Resolves a BlockSpec JSON value to a block number
// Returns null if block not found (tag "pending" → head, "latest" → head,
// "earliest" → 0, "finalized"/"safe" → head for dev node)
pub fn resolveBlockSpec(
    blockchain: *const @import("blockchain").Blockchain,
    spec: @import("jsonrpc").types.BlockSpec,
) !?u64
```

This is called by multiple handlers. Parse the `spec.value`:
- If string `"latest"`, `"safe"`, `"finalized"`, `"pending"` → return `getHeadBlockNumber()`
- If string `"earliest"` → return `0`
- If string starting with `"0x"` → parse hex number
- If string of length 66 → it's a block hash, resolve via `getCanonicalHash` pattern
- If number → use directly

#### `eth_getBlockByNumber.zig` handler
```zig
pub fn handle(
    allocator: std.mem.Allocator,
    db: *database.Database,
    params: @import("jsonrpc").eth.getBlockByNumber.EthGetBlockByNumber.Params,
) !@import("jsonrpc").eth.getBlockByNumber.EthGetBlockByNumber.Result {
    // 1. Resolve block spec to number
    // 2. Look up block in db.blockchain
    // 3. If not found, return Result{ .block = null }
    // 4. Check hydrated param
    // 5. Build RpcBlock from primitives.Block
    // 6. Return Result{ .block = rpc_block }
}
```

#### `eth_getBlockByHash.zig` handler
```zig
pub fn handle(
    allocator: std.mem.Allocator,
    db: *database.Database,
    params: @import("jsonrpc").eth.getBlockByHash.EthGetBlockByHash.Params,
) !@import("jsonrpc").eth.getBlockByHash.EthGetBlockByHash.Result {
    // 1. Convert params.block_hash (jsonrpc.Hash) to primitives.Hash.Hash
    // 2. db.blockchain.getBlockLocal(hash) or getBlockByHash
    // 3. Build RpcBlock or return null
}
```

#### `eth_getTransactionByHash.zig` handler
```zig
pub fn handle(
    allocator: std.mem.Allocator,
    db: *database.Database,
    params: ...,
) !... {
    // 1. Look up TxLocation from db.tx_index
    // 2. If not found, return null
    // 3. Get block from db.blockchain.getBlockLocal(location.block_hash)
    // 4. Get raw tx bytes from block.body.transactions[location.transaction_index]
    // 5. Decode raw bytes to RpcTransaction (with block context filled in)
    // 6. Return Result{ .tx = rpc_tx }
}
```

**Note on transaction decoding:** BlockBody stores raw bytes. The snapshot proposal used a decoder that handles:
- Type 0 (legacy): plain RLP list
- Type 1: `0x01` prefix + RLP
- Type 2: `0x02` prefix + RLP
- Type 3: `0x03` prefix + RLP
- Type 4: `0x04` prefix + RLP

The `from` address for a transaction requires recovering the signer from the signature — this path uses `crypto.secp256k1.recover` or equivalent from voltaire's crypto module.

**Alternative approach:** Store decoded transactions alongside receipts at block-commit time rather than decoding from raw bytes on every query. This avoids re-parsing RLP on every call.

#### `eth_getTransactionReceipt.zig` handler
```zig
pub fn handle(...) !... {
    // 1. Look up from db.receipts_by_tx_hash
    // 2. Convert primitives.Receipt to RpcReceipt
    // 3. Return null if not found
}
```

#### `eth_getBlockReceipts.zig` handler
```zig
pub fn handle(...) !... {
    // 1. Resolve BlockSpec to block hash
    // 2. Look up from db.receipts_by_block_hash
    // 3. Convert each receipt to RpcReceipt
    // 4. Return null if block not found
}
```

#### `eth_getLogs.zig` handler
```zig
pub fn handle(...) !... {
    // 1. Parse FilterObject from params.filter (std.json.Value)
    // 2. If blockHash specified: query only that block
    //    Else: resolve fromBlock/toBlock to numbers, iterate blocks
    // 3. For each block in range: get receipts from db.receipts_by_block_hash
    // 4. For each receipt: iterate logs
    // 5. Apply address filter (if any)
    // 6. Apply topic filter (if any)
    // 7. Collect matching RpcLog entries
    // 8. Return Result{ .logs = matching }
}
```

**Log filtering algorithm:**
- Address filter: if set, `log.address` is expected to match (case-insensitive)
- Topic filter: array of up to 4 positions, each can be null (wildcard), a hash, or array of hashes (OR match)
  - `topics[i] == null` → match any topic at position i
  - `topics[i] == hash` → exact match at position i
  - `topics[i] == [hash1, hash2]` → position i is expected to match hash1 OR hash2
- Block range validation: `fromBlock <= toBlock`, max range limit (e.g. 10,000 blocks for dev node)

---

## Execution-APIs Test Vectors

Located in `execution-apis/tests/` — these are the canonical conformance tests.

### `eth_getBlockByNumber/`
- `get-genesis.io` — block 0 by number "0x0"
- `get-latest.io` — block by tag "latest", hydrated=true (full tx objects)
- `get-finalized.io` — tag "finalized"
- `get-safe.io` — tag "safe"
- `get-block-notfound.io` — returns `null`
- `get-block-london-fork.io` — has baseFeePerGas
- `get-block-merge-fork.io` — difficulty=0, nonce=0x0000000000000000
- `get-block-shanghai-fork.io` — has withdrawalsRoot
- `get-block-cancun-fork.io` — has blobGasUsed, excessBlobGas, parentBeaconBlockRoot
- `get-block-prague-fork.io` — has requestsHash

Historical note from `get-latest.io`: some full tx objects include `blockTimestamp` and
`chainId` extension fields. Treat these as vector-specific and non-contract; follow
`docs/specs/prd.md` and `docs/specs/json-rpc-contract.md` for current ZEVM behavior.

### `eth_getTransactionByHash/`
- `get-legacy-tx.io` — type=0x0, v/r/s
- `get-dynamic-fee.io` — type=0x2 (EIP-1559), maxFeePerGas etc
- `get-access-list.io` — type=0x1 (EIP-2930)
- `get-blob-tx.io` — type=0x3 (EIP-4844)
- `get-setcode-tx.io` — type=0x4 (EIP-7702)
- `get-notfound-tx.io` — returns `null`

### `eth_getTransactionReceipt/`
- `get-legacy-receipt.io` — pre-Byzantium uses `root` not `status`
- `get-legacy-contract.io` — contract creation, contractAddress non-null
- `get-dynamic-fee.io` — EIP-1559 receipt
- `get-blob-tx.io` — has blobGasUsed, blobGasPrice
- `get-notfound-tx.io` — returns `null`

**Important:** The test `get-legacy-receipt.io` has `"root": "0x7e099d..."` (not `"status"`). Dev node receipts are post-Byzantium so they use `"status": "0x1"` or `"0x0"`.

### `eth_getBlockReceipts/`
- 8 tests: by number/hash/tag, empty block, not found → `null`

### `eth_getLogs/`
- `no-topics.io` — range query, returns all logs
- `filter-with-blockHash.io` — query by blockHash
- `filter-with-blockHash-and-topics.io` — blockHash + topic filter
- `topic-exact-match.io` — specific topic at position 0
- `topic-wildcard.io` — null at position 0 (any topic)
- `contract-addr.io` — filter by contract address
- `filter-error-future-block-range.io` — fromBlock > latest → error
- `filter-error-reversed-block-range.io` — fromBlock > toBlock → error
- `filter-error-invalid-blockHash-and-range.io` — can't have blockHash + from/to → error

---

## JSON-RPC Response Format Details

### Block response field names (camelCase in JSON, snake_case in Zig)
| JSON field | Zig primitive field |
|---|---|
| `hash` | `block.hash` |
| `parentHash` | `block.header.parent_hash` |
| `sha3Uncles` | `block.header.ommers_hash` |
| `miner` | `block.header.beneficiary` |
| `stateRoot` | `block.header.state_root` |
| `transactionsRoot` | `block.header.transactions_root` |
| `receiptsRoot` | `block.header.receipts_root` |
| `logsBloom` | `block.header.logs_bloom` (256-byte hex) |
| `difficulty` | `block.header.difficulty` (hex) |
| `number` | `block.header.number` (hex) |
| `gasLimit` | `block.header.gas_limit` (hex) |
| `gasUsed` | `block.header.gas_used` (hex) |
| `timestamp` | `block.header.timestamp` (hex) |
| `extraData` | `block.header.extra_data` (hex bytes) |
| `mixHash` | `block.header.mix_hash` |
| `nonce` | `block.header.nonce` (8-byte hex: `"0x0000000000000000"`) |
| `baseFeePerGas` | `block.header.base_fee_per_gas` (London+) |
| `withdrawalsRoot` | `block.header.withdrawals_root` (Shanghai+) |
| `blobGasUsed` | `block.header.blob_gas_used` (Cancun+) |
| `excessBlobGas` | `block.header.excess_blob_gas` (Cancun+) |
| `parentBeaconBlockRoot` | `block.header.parent_beacon_block_root` (Cancun+) |
| `size` | `block.size` (hex) |
| `totalDifficulty` | `block.total_difficulty` (hex, or omit) |
| `transactions` | body txs (hashes or objects) |
| `uncles` | `block.body.ommers` (array of hashes) |
| `withdrawals` | `block.body.withdrawals` (Shanghai+) |

### Hex encoding rules (EIP-1474)
- Integers: `"0x"` + lowercase hex without leading zeros (except `"0x0"`)
- Hashes/addresses: always 32/20 bytes = 66/42 chars with `"0x"` prefix
- Byte arrays: `"0x"` + lowercase hex, can be empty (`"0x"`)
- `logsBloom`: fixed 256-byte field = 514-char string
- `nonce`: fixed 8-byte field = 18-char string

---

## Design Decisions

1. **Where to put RpcBlock/RpcTransaction/RpcReceipt/RpcLog types**: In voltaire's jsonrpc module (we own it). Add to `../voltaire/packages/voltaire-zig/src/jsonrpc/types/`. This keeps serialization logic out of zevm handlers and makes types reusable.

2. **Transaction decoding approach**: Store decoded transaction info at block-commit time alongside receipts. This avoids RLP re-parsing on every query. Store a `TxInfo` struct that has `from` address + decoded fields.

3. **`from` address recovery**: `eth_getTransactionByHash` requires the `from` field, which is not stored in the transaction itself (it's the signer). Options:
   - Store it at block-commit time (simplest for dev node — we know the sender)
   - Recover from ECDSA signature (complex, needs secp256k1)
   - For dev node: store sender alongside tx when building block (preferred)

4. **Receipt `block_hash` placeholder**: `processTransaction` in `tx_processor.zig` sets `block_hash = primitives.Hash.ZERO`. The snapshot plan was to fix this at block-commit time before storing.

5. **Missing data returns `null`**: Per spec, `eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getTransactionByHash`, `eth_getTransactionReceipt` all return JSON `null` result when not found (not an error).

6. **`eth_getLogs` errors**: Unlike the others, `eth_getLogs` CAN return errors:
   - `-32602` (invalid params) for invalid block ranges
   - `-32602` for `blockHash` combined with `fromBlock`/`toBlock`
   - Block range limit exceeded

7. **Block tags in dev node**: `"safe"`, `"finalized"` → same as `"latest"`. `"pending"` → same as `"latest"` (automine mode). This is acceptable per Hardhat/Anvil behavior.

---

## File Map

### Files to Create (zevm)
| File | Purpose |
|---|---|
| `src/rpc_handlers/block_spec.zig` | Block spec (tag/number/hash) → block number resolution |
| `src/rpc_handlers/eth_getBlockByNumber.zig` | Handler |
| `src/rpc_handlers/eth_getBlockByHash.zig` | Handler |
| `src/rpc_handlers/eth_getTransactionByHash.zig` | Handler |
| `src/rpc_handlers/eth_getTransactionReceipt.zig` | Handler |
| `src/rpc_handlers/eth_getBlockReceipts.zig` | Handler |
| `src/rpc_handlers/eth_getLogs.zig` | Handler |
| `src/rpc_handlers/root.zig` | Module exports |

### Files to Modify (zevm)
| File | Change |
|---|---|
| `src/database/database.zig` | Add `receipts_by_tx_hash`, `receipts_by_block_hash`, `tx_index` maps |
| `src/database/root.zig` | Export `TxLocation` type if needed |
| `src/root.zig` | Export `rpc_handlers` module |
| `src/block_builder.zig` | Return tx senders alongside receipts (for `from` field) |

### Files to Modify (voltaire — we own it)
| File | Change |
|---|---|
| `src/jsonrpc/types/` | Add `RpcBlock.zig`, `RpcTransaction.zig`, `RpcReceipt.zig`, `RpcLog.zig` |
| `src/jsonrpc/types.zig` | Export new types |
| `src/jsonrpc/eth/getBlockByNumber/eth_getBlockByNumber.zig` | Update Result type |
| `src/jsonrpc/eth/getBlockByHash/eth_getBlockByHash.zig` | Update Result type |
| `src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash.zig` | Update Result type |
| `src/jsonrpc/eth/getTransactionReceipt/eth_getTransactionReceipt.zig` | Update Result type |
| `src/jsonrpc/eth/getBlockReceipts/eth_getBlockReceipts.zig` | Update Result type + add FilterObject |
| `src/jsonrpc/eth/getLogs/eth_getLogs.zig` | Update Params (add FilterObject) + Result type |

---

## Test Strategy

Tests go in `src/rpc_handlers/` alongside handlers, or in dedicated `_test.zig` files.

### Unit tests for each handler

```zig
test "eth_getBlockByNumber returns null for unknown block" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);
    const params = .{ .block = .{ .value = .{ .string = "0x999" } }, .hydrated_transactions = ... };
    const result = try eth_getBlockByNumber.handle(std.testing.allocator, &db, params);
    try std.testing.expect(result.block == null);
}

test "eth_getBlockByNumber returns genesis block" {
    var db = try Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);
    // store genesis block
    const genesis = try primitives.Block.genesis(1, std.testing.allocator);
    try db.blockchain.putBlock(genesis);
    try db.blockchain.setCanonicalHead(genesis.hash);
    // query
    const params = .{ .block = .{ .value = .{ .string = "0x0" } }, ... };
    const result = try eth_getBlockByNumber.handle(std.testing.allocator, &db, params);
    try std.testing.expect(result.block != null);
    try std.testing.expectEqual(@as(u64, 0), result.block.?.number);
}

test "eth_getLogs filters by topic" { ... }
test "eth_getLogs returns error for reversed block range" { ... }
```

### Integration tests
- Build a block with transactions, store it, then verify all 6 handlers return correct data
- Verify `blockHash` in receipts is properly set (not ZERO)
- Verify `from` address is correctly reported

---

## Reference: Hardhat EDR Pattern (Rust)

From `edr/crates/edr_provider/src/requests/eth.rs`:
```rust
pub fn handle_get_block_by_number(data: &ProviderData, block_spec: BlockSpec, hydrate: bool)
    -> Result<Option<Block>, ProviderError> {
    let block = data.block_by_block_spec(&block_spec)?;
    match block {
        None => Ok(None),
        Some(b) => Ok(Some(Block::from_primitive(b, hydrate, data.chain_id())))
    }
}
```

Key pattern: resolve block spec → look up block → convert to RPC format → return null if not found.

---

## Reference: TEVM Pattern (TypeScript)

From `../tevm-monorepo/packages/actions/src/eth/`:
```typescript
// ethGetBlockByHashProcedure.ts
export const ethGetBlockByHashProcedure = (client) => async (request) => {
    const block = await client.getBlock({ blockHash: request.params[0] })
    if (!block) return { id: request.id, result: null }
    return { id: request.id, result: blockToRpc(block, request.params[1]) }
}
```

Key pattern: async lookup, null if not found, conversion to RPC format via helper.

---

## Important Notes

1. **`receipt.sender` vs `receipt.from`**: The `primitives.Receipt` struct uses `sender` as the field name, while JSON output is expected to use `from`.

2. **`logsBloom` hex encoding**: 256 bytes = 512 hex chars = 514 chars with `"0x"` prefix.

3. **`nonce` as 8-byte hex**: The block nonce is `[8]u8`; the snapshot examples serialize it as `"0x" + 16 hex chars` (e.g. `"0x0000000000000000"`).

4. **Block `transactions` field for non-hydrated**: array of 32-byte tx hash strings.

5. **`blockTimestamp` in tx objects**: Historical vectors may show this extension, but it is
   non-contract for ZEVM in this archive context. Treat `docs/specs/prd.md` and
   `docs/specs/json-rpc-contract.md` as the normative source.

6. **`chainId` in tx objects**: Historical vectors may include this extension in tx payloads.
   It is non-contract in this archive context; use `docs/specs/prd.md` and
   `docs/specs/json-rpc-contract.md` as normative.

7. **`eth_getBlockReceipts` returns `null` for missing blocks**: Unlike getLogs which returns an empty array for empty blocks, getBlockReceipts returns `null` if the block doesn't exist.
