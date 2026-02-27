# Context: Implement Block Storage in ZEVM Database

## Ticket Info
- **Ticket ID**: implement-block-storage-database
- **Category**: cat-5-block-queries
- **Goal**: Extend ZEVM's `Database` to store and index blocks using voltaire's `BlockStore`. Add block storage by hash, block lookup by number (canonical chain), and integration with voltaire `Blockchain.zig`. Prerequisite for `eth_getBlockByNumber`/`Hash`.

---

## What Already Exists — Do Not Reinvent

### voltaire `blockchain` module (we own it, already in zevm's build.zig)

**Location:** `../voltaire/packages/voltaire-zig/src/blockchain/`

This module is **already imported by zevm** as `blockchain` in `build.zig` and `src/root.zig`. All three types are ready to use:

#### `blockchain.BlockStore` — `BlockStore.zig`
- Stores blocks by hash: `Map<Hash, Block>`
- Canonical chain: `Map<u64, Hash>` (block number → hash)
- Orphan tracking: `Set<Hash>`
- Key API:
  - `BlockStore.init(allocator) !BlockStore`
  - `store.putBlock(block) !void` — validates parent linkage, marks orphans
  - `store.getBlock(hash) ?Block` — by hash (canonical + orphans)
  - `store.getBlockByNumber(number) ?Block` — canonical chain only
  - `store.getCanonicalHash(number) ?Hash`
  - `store.setCanonicalHead(hash) !void` — walks ancestors, marks canonical
  - `store.hasBlock(hash) bool`
  - `store.getHeadBlockNumber() ?u64`
  - `store.blockCount() usize`, `store.orphanCount() usize`, `store.canonicalChainLength() usize`

#### `blockchain.Blockchain` — `Blockchain.zig`
Unified orchestrator: local store + optional remote fork cache.
- `Blockchain.init(allocator, fork_cache: ?*ForkBlockCache) !Blockchain`
- `blockchain.getBlockByHash(hash) !?Block` — local first, then fork cache (async)
- `blockchain.getBlockByNumber(number) !?Block` — local first, then fork cache (async)
- `blockchain.getCanonicalHash(number) ?Hash` — local only
- `blockchain.putBlock(block) !void`
- `blockchain.setCanonicalHead(hash) !void`
- `blockchain.getHeadBlockNumber() ?u64`
- `blockchain.getBlockLocal(hash) ?Block` — no fork-cache fetch, no allocation
- `blockchain.getBlockByNumberLocal(number) ?Block` — no fork-cache fetch
- `blockchain.isCanonical(hash) bool`
- `blockchain.blockHashByNumberLocal(tip_hash, execution_block_number, number) ?Hash` — for EVM BLOCKHASH opcode
- `blockchain.last256BlockHashesLocal(tip_hash, out) ![]const Hash` — recent block hashes for BLOCKHASH

#### `blockchain.ForkBlockCache` — `ForkBlockCache.zig`
Async RPC bridge for fork mode. Optional. Not needed for basic dev-node block storage.

### voltaire `primitives.Block` — `primitives/Block/Block.zig`

```zig
pub const Block = struct {
    header: BlockHeader.BlockHeader,
    body:   BlockBody.BlockBody,
    hash:   Hash.Hash,           // keccak256(RLP(header))
    size:   u64,
    total_difficulty: ?u256 = null,
};
```

Constructors:
- `Block.from(header, body, allocator) !Block` — computes hash + size
- `Block.genesis(chain_id, allocator) !Block`
- `Block.fromHeader(header, allocator) !Block`
- `Block.preMerge(header, body, total_difficulty, allocator) !Block`
- `Block.postMerge(header, body, allocator) !Block`

### voltaire `primitives.BlockHeader` — `primitives/BlockHeader/BlockHeader.zig`

All fields per Ethereum hardfork:
```zig
pub const BlockHeader = struct {
    parent_hash, ommers_hash, beneficiary, state_root,
    transactions_root, receipts_root, logs_bloom, difficulty,
    number, gas_limit, gas_used, timestamp, extra_data,
    mix_hash, nonce,
    base_fee_per_gas: ?u256 = null,    // EIP-1559 (London+)
    withdrawals_root: ?Hash = null,    // EIP-4895 (Shanghai+)
    blob_gas_used: ?u64 = null,        // EIP-4844 (Cancun+)
    excess_blob_gas: ?u64 = null,      // EIP-4844 (Cancun+)
    parent_beacon_block_root: ?Hash = null, // EIP-4844 (Cancun+)
};
```

---

## ZEVM's Existing Database (`src/database/`)

### `database.zig` — Current `Database` struct
```zig
pub const Database = struct {
    state:       state_manager.StateManager,    // account state (balance/nonce/code/storage)
    accounts:    Accounts,                       // MPT for state root computation
    contracts:   Contracts,                      // code hash → bytecode
    block_hashes: BlockHashes,                   // u64 → Hash (for EVM BLOCKHASH opcode, recent 256)
    // MISSING: block storage (blocks by hash, canonical chain)
};
```

### `block_hashes.zig` — `BlockHashes` (already exists)
```zig
pub const BlockHashes = struct {
    hashes: std.AutoHashMapUnmanaged(u64, Hash.Hash),
    pub fn get(number) ?Hash
    pub fn put(allocator, number, hash) !void
    pub fn remove(number) void
};
```
This is **only** for the EVM `BLOCKHASH` opcode (recent 256 blocks). It is **NOT** a full block store (no block headers/bodies, not searchable by hash).

### `accounts.zig` — Merkle Patricia Trie for state root computation
### `contracts.zig` — code hash deduplication

---

## What Needs to Be Done

### 1. Add `blockchain.Blockchain` field to `Database`

The `Database` struct needs a `Blockchain` field so block data lives alongside state:

```zig
// In src/database/database.zig
pub const Database = struct {
    state:        state_manager.StateManager,
    accounts:     @import("accounts.zig").Accounts,
    contracts:    @import("contracts.zig").Contracts,
    block_hashes: @import("block_hashes.zig").BlockHashes,
    blockchain:   @import("blockchain").Blockchain,   // ADD THIS
};
```

`init` / `deinit` must initialize/deinit the Blockchain too:
```zig
pub fn init(allocator: std.mem.Allocator) !Database {
    return .{
        .state        = try state_manager.StateManager.init(allocator, null),
        .accounts     = @import("accounts.zig").Accounts.init(allocator),
        .contracts    = @import("contracts.zig").Contracts.init(),
        .block_hashes = @import("block_hashes.zig").BlockHashes.init(),
        .blockchain   = try @import("blockchain").Blockchain.init(allocator, null),
    };
}

pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
    self.state.deinit();
    self.accounts.deinit();
    self.contracts.deinit(allocator);
    self.block_hashes.deinit(allocator);
    self.blockchain.deinit();
}
```

**Note:** `Blockchain` currently stores an `allocator` field (violating zevm's "no stored allocators" style), but that's in voltaire — do not change that here. Just use it as-is. The `deinit` call takes no allocator because `Blockchain.deinit` uses its stored allocator.

### 2. Sync `block_hashes` from `Blockchain` after block commit

After `blockchain.setCanonicalHead(hash)`, populate `block_hashes` with the new block's hash for EVM BLOCKHASH opcode support:

```zig
// After committing a block:
const block = db.blockchain.getBlockLocal(block_hash).?;
try db.block_hashes.put(allocator, block.header.number, block_hash);
```

### 3. Update `Database.syncAccountToTrie` (no change needed)
The existing `syncAccountToTrie` and `syncCachedAccountsToTrie` methods are unchanged.

---

## Integration Points

### `block_builder.zig` → Database after block build
`buildBlock` produces a `BlockResult` (receipts, total_gas_used, block_number) but does NOT store the block. The caller must:
1. Build `primitives.Block.Block` from the header + body
2. Call `db.blockchain.putBlock(block)`
3. Call `db.blockchain.setCanonicalHead(block.hash)`
4. Call `db.block_hashes.put(allocator, block.header.number, block.hash)`

### `host_adapter.zig` → BLOCKHASH opcode
The host adapter reads `db.block_hashes.get(number)` for the EVM BLOCKHASH opcode. After this ticket, it could also use `db.blockchain.getCanonicalHash(number)` for a richer lookup. The existing `block_hashes` storage remains as the primary path for performance.

### Future RPC handlers (`eth_getBlockByNumber`, `eth_getBlockByHash`)
These will read directly from `db.blockchain`:
```zig
// eth_getBlockByNumber
const block = db.blockchain.getBlockByNumberLocal(number);  // or getBlockByNumber (async)

// eth_getBlockByHash
const block = db.blockchain.getBlockLocal(hash);
```

---

## Key Design Rules (from CLAUDE.md)

1. **No local type aliases** — Write `@import("blockchain").Blockchain` inline, not `const Blockchain = @import("blockchain").Blockchain`.
2. **No stored allocators** — `Blockchain` already stores one (voltaire's code), do not add another. `Database.deinit` calls `self.blockchain.deinit()` (no allocator arg).
3. **Pass allocator explicitly** — Any `put` operation on `block_hashes` or `accounts` takes an `allocator` parameter.

---

## Test Strategy

Tests go in `src/database/database_test.zig`. Following the existing pattern:

```zig
test "database stores and retrieves block by hash" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    const genesis = try primitives.Block.genesis(1, std.testing.allocator);
    try db.blockchain.putBlock(genesis);
    try db.blockchain.setCanonicalHead(genesis.hash);

    const retrieved = db.blockchain.getBlockLocal(genesis.hash);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 0), retrieved.?.header.number);
}

test "database retrieves block by number (canonical)" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    const genesis = try primitives.Block.genesis(1, std.testing.allocator);
    try db.blockchain.putBlock(genesis);
    try db.blockchain.setCanonicalHead(genesis.hash);

    const block = db.blockchain.getBlockByNumberLocal(0);
    try std.testing.expect(block != null);
}

test "database block not found returns null" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    try std.testing.expect(db.blockchain.getBlockLocal(primitives.Hash.ZERO) == null);
    try std.testing.expect(db.blockchain.getBlockByNumberLocal(999) == null);
}

test "database head block number tracks canonical chain" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    const genesis = try primitives.Block.genesis(1, std.testing.allocator);
    try db.blockchain.putBlock(genesis);
    try db.blockchain.setCanonicalHead(genesis.hash);

    const head = db.blockchain.getHeadBlockNumber();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u64, 0), head.?);
}
```

---

## Reference: execution-apis Test Vectors

### `eth_getBlockByNumber` test format (from `execution-apis/tests/eth_getBlockByNumber/`)

**get-genesis.io:**
```
>> {"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["0x0",true]}
<< {"jsonrpc":"2.0","id":1,"result":{
    "number":"0x0", "hash":"0x79e0f...", "parentHash":"0x0000...0000",
    "difficulty":"0x20000", "gasLimit":"0x23f3e20", "gasUsed":"0x0",
    "transactions":[], "uncles":[], ...}}
```

**get-block-notfound.io:**
```
>> {"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["0x3e8",true]}
<< {"jsonrpc":"2.0","id":1,"result":null}
```

**get-latest.io:**
```
>> {"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",true]}
<< {"jsonrpc":"2.0","id":1,"result":{"number":"0x2d","hash":"0xe27a3e81...", ...}}
```

### `eth_getBlockByHash` test format (from `execution-apis/tests/eth_getBlockByHash/`)

**get-block-by-hash.io:**
```
>> {"jsonrpc":"2.0","id":1,"method":"eth_getBlockByHash","params":["0x79ba...",true]}
<< {"jsonrpc":"2.0","id":1,"result":{"number":"0x1", "hash":"0x79ba...", ...}}
```

**get-block-by-notfound-hash.io / get-block-by-empty-hash.io:**
```
>> {"jsonrpc":"2.0","id":1,"method":"eth_getBlockByHash","params":["0x0000...deadbeef",true]}
<< {"jsonrpc":"2.0","id":1,"result":null}
```

Key observation: **missing block returns `null` result, not an error**.

### Block tags to support (for `eth_getBlockByNumber`):
- `"latest"` — canonical head
- `"earliest"` — block 0 (genesis)
- `"finalized"`, `"safe"` — same as `"latest"` in dev node
- `"pending"` — same as `"latest"` in automine mode
- `"0xNN"` — hex block number

---

## Reference: voltaire jsonrpc types for blocks

**`eth_getBlockByNumber.zig`** — `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByNumber/`
```zig
pub const Params = struct {
    block: types.Quantity,
    hydrated_transactions: types.Quantity,
};
pub const Result = struct { value: types.Quantity }; // placeholder, needs real block type
```

**`eth_getBlockByHash.zig`** — `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByHash/`
```zig
pub const Params = struct {
    block_hash: types.Hash,
    hydrated_transactions: types.Quantity,
};
pub const Result = struct { value: types.Quantity }; // placeholder
```

**Note:** Both `Result` types are stubs that return `types.Quantity`. To return proper block JSON, the RPC handler will need to serialize a `primitives.Block.Block` into the Ethereum JSON format. This conversion (block → JSON-RPC block object) is **not** currently in voltaire and will need to be implemented — either in voltaire's jsonrpc module or in zevm's RPC handler.

---

## File Map

| File | Role | Action |
|------|------|--------|
| `src/database/database.zig` | Core database struct | **Modify**: add `blockchain` field |
| `src/database/database_test.zig` | Database tests | **Modify**: add block storage tests |
| `src/database/root.zig` | Database module exports | No change needed (Blockchain accessible via `db.blockchain`) |
| `src/block_builder.zig` | Block building | No change needed for this ticket |
| `src/root.zig` | ZEVM root exports | No change needed (`blockchain` already exported) |
| `build.zig` | Build config | No change needed (`blockchain` already imported) |

### Upstream (voltaire) — no changes needed for this ticket
| File | Role |
|------|------|
| `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig` | Block storage engine |
| `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` | Unified block access |
| `../voltaire/packages/voltaire-zig/src/blockchain/ForkBlockCache.zig` | Fork mode (optional) |
| `../voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig` | Block struct |
| `../voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig` | Block header |

---

## Implementation Summary

The core change is minimal — add `blockchain: @import("blockchain").Blockchain` to the `Database` struct, initialize it in `init`, and deinit it in `deinit`. All the block storage logic already exists in voltaire's `Blockchain`/`BlockStore`. No new logic needed at the `Database` level.

The `block_hashes` field (existing) serves the EVM `BLOCKHASH` opcode and should be kept in sync with the canonical chain. After committing each new canonical block, add its number→hash mapping to `block_hashes`.

Tests should cover: store genesis, retrieve by hash, retrieve by number, missing → null, head block number tracking.
