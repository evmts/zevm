# Context: snapshots-rpc-layer-missing
## Ticket: Implement evm_snapshot and evm_revert JSON-RPC handlers in zevm

---

## 1. Problem Statement

Neither `evm_snapshot` nor `evm_revert` exist as callable RPC methods in zevm. The underlying state snapshot machinery **already exists** in voltaire's `StateManager`, but:

1. There is no `evm` namespace in voltaire's JSON-RPC types (`JsonRpc.zig` only has `eth`, `engine`, `debug`).
2. There are no `evm_snapshot` / `evm_revert` method modules in voltaire.
3. zevm has no HTTP JSON-RPC server or dispatch layer (main.zig just prints a string).
4. Block-level metadata (block number, timestamp, coinbase) must also be snapshotted and rolled back.

---

## 2. What Already Exists (Do Not Re-implement)

### voltaire StateManager — `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`

The `StateManager` struct **already has** full snapshot support:

```zig
pub const StateManager = struct {
    allocator: std.mem.Allocator,
    journaled_state: JournaledState.JournaledState,
    snapshot_counter: u64,
    snapshots: std.AutoHashMap(u64, usize), // snapshot_id → checkpoint depth

    /// Creates a checkpoint and returns a u64 snapshot ID (0, 1, 2, ...).
    pub fn snapshot(self: *StateManager) !u64 { ... }

    /// Reverts journaled state to the given snapshot, removing it and all
    /// newer snapshots (Ganache-compatible single-use semantics).
    /// Returns error.InvalidSnapshot if the ID does not exist.
    pub fn revertToSnapshot(self: *StateManager, snapshot_id: u64) !void { ... }
};
```

Key implementation details:
- `snapshot()` stores `checkpoint_depth` at the time of the call, pushes a new checkpoint, returns auto-incremented `u64` ID.
- `revertToSnapshot(id)` walks back checkpoints until the saved depth, then removes all snapshot entries `>= id`.
- Tests in `StateManager.zig` cover: basic revert, multiple snapshots, invalid snapshot, clearing newer snapshots.

### zevm Database — `src/database/database.zig`

```zig
pub const Database = struct {
    state: state_manager.StateManager,   // ← call .snapshot() / .revertToSnapshot() here
    accounts: Accounts,
    contracts: Contracts,
    block_hashes: BlockHashes,
};
```

The `state` field is the direct entry point. No changes to `Database` are needed for account-state snapshot/revert.

### voltaire JSON-RPC types — `../voltaire/packages/voltaire-zig/src/jsonrpc/`

Existing namespaces: `eth` (43 methods), `engine`, `debug`. **No `evm` namespace exists yet.**

Pattern for each namespace:
```
jsonrpc/
  JsonRpc.zig          ← root union: { engine, eth, debug }
  root.zig             ← re-exports
  types.zig            ← re-exports Address, Hash, Quantity, BlockTag, BlockSpec
  eth/
    methods.zig        ← EthMethod tagged union + StaticStringMap dispatch
    blockNumber/
      eth_blockNumber.zig   ← pub const method, Params, Result
```

Each method module exports exactly:
- `pub const method: []const u8` — the RPC method name string
- `pub const Params` — struct with `jsonStringify` + `jsonParseFromValue`
- `pub const Result` — struct with `jsonStringify` + `jsonParseFromValue`

### voltaire Quantity type — `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig`

Used for hex-encoded unsigned integers. `evm_snapshot` result is a `Quantity` (hex string like `"0x1"`).

---

## 3. Reference Implementations

### EDR (Hardhat) — `edr/crates/edr_provider/src/requests/eth/evm.rs`

```rust
// evm_snapshot: no params → returns U64 snapshot ID
pub fn handle_snapshot_request(...) -> Result<U64, ...> {
    let snapshot_id = data.make_snapshot();
    Ok(U64::from(snapshot_id))
}

// evm_revert: takes U64 snapshot ID → returns bool
pub fn handle_revert_request(..., snapshot_id: U64) -> Result<bool, ...> {
    Ok(data.revert_to_snapshot(snapshot_id.as_limbs()[0]))
}
```

### EDR Snapshot Struct — `edr/crates/edr_provider/src/snapshot.rs`

What EDR stores per snapshot (block-level metadata beyond account state):

```rust
pub(crate) struct Snapshot<...> {
    pub block_number: u64,
    pub block_number_to_state_id: HashTrieMapSync<u64, StateId>,
    pub block_time_offset_seconds: i64,
    pub coinbase: Address,
    pub irregular_state: IrregularState,
    pub mem_pool: MemPool<...>,
    pub next_block_base_fee_per_gas: Option<u128>,
    pub next_block_timestamp: Option<u64>,
    pub parent_beacon_block_root_generator: RandomHashGenerator,
    pub prev_randao_generator: RandomHashGenerator,
    pub time: Instant,
}
```

**Block-level fields zevm must also snapshot/restore:**
- `block_number` — restored via `blockchain.revert_to_block(block_number)`
- `coinbase` / `beneficiary`
- `next_block_timestamp` override
- `next_block_base_fee_per_gas` override
- `block_time_offset_seconds` (adjusted for elapsed wall-clock time)

EDR revert logic:
1. Remove the snapshot entry and all newer ones (`BTreeMap::split_off`).
2. Call `blockchain.revert_to_block(block_number)` — removes blocks, receipts, tx mappings.
3. Restore all block-level fields from the snapshot struct.
4. Adjust `block_time_offset_seconds` += elapsed seconds since snapshot was taken.
5. Return `true`; return `false` if snapshot ID not found.

### Foundry Anvil — `foundry/crates/anvil/src/eth/api.rs`

```rust
pub async fn evm_snapshot(&self) -> Result<U256> {
    Ok(self.backend.create_state_snapshot().await)
}
pub async fn evm_revert(&self, id: U256) -> Result<bool> {
    self.backend.revert_state_snapshot(id).await
}
```

Foundry stores `(block_num, block_hash)` per snapshot ID and removes newer blocks on revert.

Both methods are aliased: `anvil_snapshot` = `evm_snapshot`, `anvil_revert` = `evm_revert`.

### tevm — `../tevm-monorepo/packages/actions/src/`

tevm snapshot: stores full state dump + state root keyed by hex ID string (`"0x1"`, `"0x2"`, …).
tevm revert: calls `deleteSnapshotsFrom(id)` — removes snapshot `id` and all with higher numeric value.

**JSON wire format (all implementations agree):**

`evm_snapshot` request:
```json
{ "jsonrpc": "2.0", "method": "evm_snapshot", "params": [], "id": 1 }
```
`evm_snapshot` response:
```json
{ "jsonrpc": "2.0", "result": "0x1", "id": 1 }
```

`evm_revert` request:
```json
{ "jsonrpc": "2.0", "method": "evm_revert", "params": ["0x1"], "id": 2 }
```
`evm_revert` response:
```json
{ "jsonrpc": "2.0", "result": true, "id": 2 }
```

---

## 4. zevm Current State

```
zevm/src/
  main.zig                        ← prints "zevm - Ethereum local node", no server
  root.zig                        ← re-exports database, host_adapter, tx_processor, etc.
  database/database.zig           ← Database { state: StateManager, accounts, contracts, block_hashes }
  block_builder.zig               ← builds blocks, enforces gas limits
  tx_processor.zig                ← executes transactions
  host_adapter.zig                ← vtable bridge between guillotine-mini EVM and voltaire state
  consensus_verifier.zig
  beacon_api.zig / consensus_sync.zig / checkpoint.zig
```

**There is no RPC server, no HTTP listener, no method dispatch in zevm.**

The HTTP JSON-RPC server is tracked in a separate ticket (`http-jsonrpc-server-and-dispatch.md`). This ticket assumes that server infrastructure either already exists or will be built concurrently, and focuses specifically on the snapshot/revert handlers.

---

## 5. Implementation Plan

### Step 1 — Add `evm` namespace to voltaire JSON-RPC types

**Location:** `../voltaire/packages/voltaire-zig/src/jsonrpc/`

Create directory `evm/` with:

**`evm/snapshot/evm_snapshot.zig`**
```zig
pub const method = "evm_snapshot";

/// No parameters
pub const Params = struct {
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void { _ = self; try jws.write(.{}); }
    pub fn jsonParseFromValue(...) !Params { return Params{}; }
};

/// Result: hex-encoded snapshot ID, e.g. "0x1"
pub const Result = struct {
    value: @import("../../types.zig").Quantity,
    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void { try jws.write(self.value); }
    pub fn jsonParseFromValue(...) !Result { ... }
};
```

**`evm/revert/evm_revert.zig`**
```zig
pub const method = "evm_revert";

/// Single param: snapshot ID as hex string, e.g. ["0x1"]
pub const Params = struct {
    snapshot_id: @import("../../types.zig").Quantity,
    pub fn jsonStringify(...) !void { ... }
    pub fn jsonParseFromValue(...) !Params { ... }  // parse array [hex_id]
};

/// Result: bool (true = reverted, false = invalid snapshot ID)
pub const Result = struct {
    value: bool,
    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void { try jws.write(self.value); }
    pub fn jsonParseFromValue(...) !Result { ... }
};
```

**`evm/methods.zig`**
```zig
const evm_snapshot = @import("snapshot/evm_snapshot.zig");
const evm_revert   = @import("revert/evm_revert.zig");

pub const EvmMethod = union(enum) {
    evm_snapshot: struct { params: evm_snapshot.Params, result: evm_snapshot.Result },
    evm_revert:   struct { params: evm_revert.Params,   result: evm_revert.Result   },

    pub fn methodName(self: EvmMethod) []const u8 { ... }
    pub fn fromMethodName(name: []const u8) !std.meta.Tag(EvmMethod) { ... }  // StaticStringMap
};
```

**Update `JsonRpc.zig`** to add `.evm` variant:
```zig
pub const JsonRpcMethod = union(enum) {
    engine: engineMethods.EngineMethod,
    eth:    ethMethods.EthMethod,
    debug:  debugMethods.DebugMethod,
    evm:    evmMethods.EvmMethod,       // ← add this
    ...
};
```

### Step 2 — Add block-level snapshot metadata to zevm

zevm needs a struct to capture block-level state alongside the `StateManager` account-state snapshot. This belongs in zevm (not voltaire) because it's node-level state, not pure EVM state.

**`src/snapshot_manager.zig`** (new file in zevm):
```zig
pub const BlockSnapshot = struct {
    state_snapshot_id: u64,     // ID returned by StateManager.snapshot()
    block_number: u64,
    timestamp: u64,
    coinbase: primitives.Address,
    base_fee: ?u256,
    // Add next_block_timestamp_override, next_block_base_fee_override as needed
};

pub const SnapshotManager = struct {
    snapshots: std.AutoHashMap(u64, BlockSnapshot),
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) SnapshotManager { ... }
    pub fn deinit(self: *SnapshotManager) void { ... }

    /// Takes account-state snapshot + block metadata, returns combined snapshot ID.
    pub fn takeSnapshot(
        self: *SnapshotManager,
        allocator: std.mem.Allocator,
        state: *state_manager.StateManager,
        block_number: u64,
        timestamp: u64,
        coinbase: primitives.Address,
        base_fee: ?u256,
    ) !u64 { ... }

    /// Reverts account state and block metadata. Returns false if ID not found.
    pub fn revertToSnapshot(
        self: *SnapshotManager,
        state: *state_manager.StateManager,
        snapshot_id: u64,
    ) !bool { ... }
};
```

### Step 3 — Implement RPC handler functions in zevm

These are plain functions that take the `SnapshotManager` and relevant node state; they are called by the HTTP dispatch layer.

**`src/rpc/evm_handlers.zig`** (new file):
```zig
/// Handler for evm_snapshot.
/// Returns: hex-encoded snapshot ID string (caller owns memory).
pub fn handleEvmSnapshot(
    allocator: std.mem.Allocator,
    snapshot_mgr: *snapshot_manager.SnapshotManager,
    db: *database.Database,
    block_number: u64,
    timestamp: u64,
    coinbase: primitives.Address,
    base_fee: ?u256,
) ![]const u8 {
    const id = try snapshot_mgr.takeSnapshot(allocator, &db.state, block_number, timestamp, coinbase, base_fee);
    return std.fmt.allocPrint(allocator, "0x{x}", .{id});
}

/// Handler for evm_revert.
/// Returns: true if snapshot existed and state was restored, false otherwise.
pub fn handleEvmRevert(
    snapshot_mgr: *snapshot_manager.SnapshotManager,
    db: *database.Database,
    snapshot_id_hex: []const u8,
    // Output params for block-level state that callers must update:
    out_block_number: *u64,
    out_timestamp: *u64,
    out_coinbase: *primitives.Address,
    out_base_fee: *?u256,
) !bool {
    // Parse "0x1" → u64
    const hex = if (std.mem.startsWith(u8, snapshot_id_hex, "0x")) snapshot_id_hex[2..] else snapshot_id_hex;
    const id = std.fmt.parseInt(u64, hex, 16) catch return false;
    return snapshot_mgr.revertToSnapshot(&db.state, id, out_block_number, out_timestamp, out_coinbase, out_base_fee);
}
```

### Step 4 — Wire into HTTP dispatch

Once the HTTP JSON-RPC server (separate ticket) is in place:
- Route `"evm_snapshot"` → `handleEvmSnapshot`
- Route `"evm_revert"` → `handleEvmRevert`
- Both `"evm_snapshot"` and `"anvil_snapshot"` should map to the same handler (Foundry compatibility alias).
- Both `"evm_revert"` and `"anvil_revert"` should map to the same handler.

---

## 6. ID Format — Hex String

All reference implementations (`evm_snapshot` in tevm, EDR, Foundry) return the snapshot ID as a hex-encoded string:
- `"0x0"`, `"0x1"`, `"0x2"`, … (lower-case hex)
- `evm_revert` accepts the same hex string as its single array parameter.

Internally zevm/voltaire use `u64`. The conversion layer is `std.fmt.parseInt(u64, hex[2..], 16)` and `std.fmt.allocPrint("0x{x}", .{id})`.

---

## 7. Snapshot Invalidation Semantics

All implementations agree: **snapshots are single-use**. Reverting to snapshot `N` removes snapshot `N` **and all snapshots with ID > N**. This is "Ganache-compatible" behavior. Attempting to revert to an already-used or never-created snapshot ID returns `false`.

---

## 8. Key File Paths Summary

| What | Path |
|------|------|
| voltaire StateManager (has `snapshot()` / `revertToSnapshot()`) | `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` |
| voltaire JournaledState (checkpoint impl) | `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig` |
| voltaire JSON-RPC root union | `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig` |
| voltaire JSON-RPC root.zig | `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig` |
| voltaire eth methods (pattern reference) | `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` |
| voltaire eth_blockNumber (example method module) | `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/blockNumber/eth_blockNumber.zig` |
| voltaire Quantity type | `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig` |
| zevm Database (contains StateManager) | `src/database/database.zig` |
| zevm main.zig | `src/main.zig` |
| zevm root.zig | `src/root.zig` |
| zevm build.zig | `build.zig` |
| EDR evm handlers (snapshot/revert Rust reference) | `edr/crates/edr_provider/src/requests/eth/evm.rs` |
| EDR snapshot struct | `edr/crates/edr_provider/src/snapshot.rs` |
| EDR data.rs (make_snapshot / revert_to_snapshot) | `edr/crates/edr_provider/src/data.rs` |
| Foundry anvil eth API | `foundry/crates/anvil/src/eth/api.rs` |
| Foundry anvil backend mem | `foundry/crates/anvil/src/eth/backend/mem/mod.rs` |
| Foundry RPC method enum | `foundry/crates/anvil/core/src/eth/mod.rs` |
| tevm snapshot procedure | `../tevm-monorepo/packages/actions/src/anvil/anvilSnapshotProcedure.js` |
| tevm revert procedure | `../tevm-monorepo/packages/actions/src/anvil/anvilRevertProcedure.js` |

---

## 9. Testing Strategy

Following the CLAUDE.md directive to only test zevm's integration layer:

**`src/snapshot_manager_test.zig`** (new):
- `test "evm_snapshot returns incrementing hex IDs"` — call `handleEvmSnapshot` twice, verify `"0x0"` and `"0x1"`.
- `test "evm_revert restores account state"` — snapshot, mutate balance, revert, verify balance restored.
- `test "evm_revert restores block metadata"` — snapshot, change block number/timestamp, revert, verify.
- `test "evm_revert returns false for invalid ID"` — call with `"0x999"`, verify `false` returned.
- `test "evm_revert invalidates newer snapshots"` — take snap0, snap1, revert snap0, verify snap1 invalid.

Do **not** re-test `StateManager.snapshot()` / `StateManager.revertToSnapshot()` internals — those are covered by voltaire's own tests.

---

## 10. Zig Style Reminders (per CLAUDE.md)

- No local type aliases: use `state_manager.StateManager`, `primitives.Address`, etc. inline.
- No stored allocators: pass `allocator` explicitly to functions that need it.
- Minimize abstractions: `SnapshotManager` is high-leverage (centralizes ID counter + block metadata pairing). The RPC handler functions themselves should be thin and inline any trivial logic.
