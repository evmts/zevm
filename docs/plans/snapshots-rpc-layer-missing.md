# Plan: snapshots-rpc-layer-missing

Ticket: `snapshots-rpc-layer-missing`
Category: `cat-7-snapshots`

---

## Overview

Implement `evm_snapshot` and `evm_revert` as callable JSON-RPC methods.

**Scope of this ticket:**

1. Add an `evm` namespace to voltaire's JSON-RPC type system (`evm_snapshot` + `evm_revert`).
2. Add a `SnapshotManager` in zevm that pairs voltaire's existing `StateManager.snapshot()` / `StateManager.revertToSnapshot()` with block-level metadata capture/restore (block number, timestamp, coinbase, base_fee) per EDR's `snapshot.rs`.
3. Add thin RPC handler functions in zevm that do hex↔u64 conversion and delegate to `SnapshotManager`.
4. Register `anvil_snapshot` / `anvil_revert` aliases pointing to the same handlers.
5. Wire all test files into `src/root.zig`.

**Explicitly out of scope here:** HTTP JSON-RPC server and full dispatch infrastructure (covered by separate ticket `http-jsonrpc-server-and-dispatch`). The handlers and `SnapshotManager` are written as plain Zig functions that the future server layer will call.

**What already exists (do NOT rewrite):**
- `voltaire` `StateManager.snapshot()` → `!u64` and `StateManager.revertToSnapshot(id)` → `!void` with full Ganache single-use semantics (removes snapshot ID and all newer IDs on revert). Fully tested in voltaire.
- `voltaire` JSON-RPC type system pattern: `eth`, `debug`, `engine` namespaces each have `method.zig` files + a `methods.zig` union, wired into `JsonRpc.zig` and `root.zig`.

---

## Reference Behavior (EDR)

From `edr/crates/edr_provider/src/snapshot.rs` and `data.rs`:

```
Snapshot stores:
  state (via StateManager.snapshot)
  block_number
  timestamp
  coinbase
  next_block_base_fee_per_gas
```

`evm_snapshot` → captures all of the above, returns incrementing ID as hex Quantity.
`evm_revert` → restores all of the above, removes snapshot + all newer ones, returns `true`. Returns `false` if ID not found.

---

## TDD Step Order

All tests are written **before** the corresponding implementation. Each step is one function, one type, or one test.

---

### Phase A — Voltaire: `evm` namespace JSON-RPC types

#### Step 1 — TEST: `evm_snapshot` method module (serde round-trip)

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/snapshot/evm_snapshot.zig`

Add inline tests at bottom of file (this file doesn't exist yet, tests will fail at compile):

```zig
test "evm_snapshot Params parses empty array" {
    // parse [] -> Params{} succeeds
}
test "evm_snapshot Params parses null params" {
    // parse .null -> Params{} succeeds (some clients omit params)
}
test "evm_snapshot Result serializes as quantity hex string" {
    // Result{ .value = Quantity{ .value = .{ .string = "0x1" } } }
    // serializes to "0x1"
}
```

#### Step 2 — IMPL: `evm_snapshot.zig`

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/snapshot/evm_snapshot.zig`

```zig
pub const method = "evm_snapshot";

pub const Params = struct {
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void { ... }
    pub fn jsonParseFromValue(...) !Params { return Params{}; }
};

pub const Result = struct {
    value: types.Quantity,
    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void { ... }
    pub fn jsonParseFromValue(...) !Result { ... }
};
```

Follows the `eth_blockNumber` pattern exactly (no params, Quantity result).

---

#### Step 3 — TEST: `evm_revert` method module (serde round-trip)

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/revert/evm_revert.zig`

```zig
test "evm_revert Params parses [snapshotId]" {
    // parse ["0x1"] -> Params{ .snapshot_id = Quantity("0x1") }
}
test "evm_revert Params rejects empty array" {
    // parse [] -> error.InvalidParamCount
}
test "evm_revert Result serializes true" {
    // Result{ .value = true } serializes to `true`
}
test "evm_revert Result serializes false" {
    // Result{ .value = false } serializes to `false`
}
```

#### Step 4 — IMPL: `evm_revert.zig`

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/revert/evm_revert.zig`

```zig
pub const method = "evm_revert";

pub const Params = struct {
    snapshot_id: types.Quantity,
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        try jws.write(self.snapshot_id);
        try jws.endArray();
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        if (source != .array) return error.UnexpectedToken;
        if (source.array.items.len != 1) return error.InvalidParamCount;
        return .{
            .snapshot_id = try std.json.innerParseFromValue(types.Quantity, allocator, source.array.items[0], options),
        };
    }
};

pub const Result = struct {
    value: bool,
    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void { try jws.write(self.value); }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return .{ .value = try std.json.innerParseFromValue(bool, allocator, source, options) };
    }
};
```

---

#### Step 5 — TEST: `EvmMethod` namespace union dispatch

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/methods.zig`

```zig
test "EvmMethod.fromMethodName resolves evm_snapshot" { ... }
test "EvmMethod.fromMethodName resolves evm_revert" { ... }
test "EvmMethod.fromMethodName rejects unknown method" { ... }
test "EvmMethod.methodName round-trips" { ... }
```

#### Step 6 — IMPL: `evm/methods.zig`

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/methods.zig`

```zig
const evm_snapshot = @import("snapshot/evm_snapshot.zig");
const evm_revert = @import("revert/evm_revert.zig");

pub const EvmMethod = union(enum) {
    evm_snapshot: struct { params: evm_snapshot.Params, result: evm_snapshot.Result },
    evm_revert: struct { params: evm_revert.Params, result: evm_revert.Result },

    pub fn methodName(self: EvmMethod) []const u8 {
        return switch (self) {
            .evm_snapshot => evm_snapshot.method,
            .evm_revert => evm_revert.method,
        };
    }

    pub fn fromMethodName(method_name: []const u8) !std.meta.Tag(EvmMethod) {
        const map = std.StaticStringMap(std.meta.Tag(EvmMethod)).initComptime(.{
            .{ "evm_snapshot", .evm_snapshot },
            .{ "evm_revert", .evm_revert },
        });
        return map.get(method_name) orelse error.UnknownMethod;
    }
};
```

---

#### Step 7 — TEST: `anvil_snapshot` / `anvil_revert` aliases in EvmMethod

The `anvil_` aliases share identical param/result shapes and map to the same handlers. Add them to the same `EvmMethod` union (not a separate namespace, to avoid code duplication).

```zig
test "EvmMethod.fromMethodName resolves anvil_snapshot" { ... }
test "EvmMethod.fromMethodName resolves anvil_revert" { ... }
```

#### Step 8 — IMPL: Add `anvil_snapshot` / `anvil_revert` to `EvmMethod`

Modify `evm/methods.zig` to add two extra tags in the union and two entries in the `StaticStringMap`:

```zig
anvil_snapshot: struct { params: evm_snapshot.Params, result: evm_snapshot.Result },
anvil_revert: struct { params: evm_revert.Params, result: evm_revert.Result },
```

```zig
.{ "anvil_snapshot", .anvil_snapshot },
.{ "anvil_revert", .anvil_revert },
```

The `methodName()` switch arms for `anvil_*` return `"anvil_snapshot"` / `"anvil_revert"` (their own method name strings). A separate `const anvil_snapshot_method = "anvil_snapshot"` constant in `evm_snapshot.zig` is not needed — inline the strings.

---

#### Step 9 — TEST: Root `JsonRpcMethod` includes `evm` namespace

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig` (test at bottom)

```zig
test "JsonRpcMethod includes evm namespace" {
    // Verify the .evm tag exists on JsonRpcMethod union
    // and methodName() works for evm_snapshot
}
```

#### Step 10 — IMPL: Wire `evm` into `JsonRpc.zig` and `root.zig`

**`JsonRpc.zig`** — add:
```zig
const evmMethods = @import("evm/methods.zig");

pub const JsonRpcMethod = union(enum) {
    engine: engineMethods.EngineMethod,
    eth: ethMethods.EthMethod,
    debug: debugMethods.DebugMethod,
    evm: evmMethods.EvmMethod,         // ← new

    pub fn methodName(self: JsonRpcMethod) []const u8 {
        return switch (self) {
            .engine => |m| m.methodName(),
            .eth => |m| m.methodName(),
            .debug => |m| m.methodName(),
            .evm => |m| m.methodName(),  // ← new
        };
    }
};
```

**`root.zig`** — add:
```zig
pub const evm = @import("evm/methods.zig");
```

---

### Phase B — Zevm: `SnapshotManager`

`SnapshotManager` captures block-level metadata alongside a voltaire `StateManager` snapshot ID. Each call to `takeSnapshot` calls `state.snapshot()` internally and records block metadata. Each call to `revertToSnapshot` calls `state.revertToSnapshot()` and writes block metadata back to caller-provided out-pointers.

**Design constraints (per CLAUDE.md):**
- No stored allocators → pass allocator to `init`, store it is acceptable only for the internal `HashMap`; alternatively use `AutoHashMapUnmanaged` and always pass allocator explicitly.
- No local type aliases → use fully qualified paths everywhere.

#### Step 11 — TEST: `SnapshotManager.takeSnapshot` stores metadata

**File:** `src/snapshot_manager_test.zig` (new)

```zig
const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const snapshot_manager = @import("snapshot_manager.zig");

test "takeSnapshot returns incrementing IDs starting at 0" { ... }
test "takeSnapshot stores block_number" { ... }
test "takeSnapshot stores timestamp" { ... }
test "takeSnapshot stores coinbase" { ... }
test "takeSnapshot stores base_fee" { ... }
test "two snapshots have different IDs" { ... }
```

#### Step 12 — IMPL: `src/snapshot_manager.zig`

**File:** `src/snapshot_manager.zig` (new)

```zig
const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");

pub const BlockSnapshot = struct {
    state_snapshot_id: u64,
    block_number: u64,
    timestamp: u64,
    coinbase: primitives.Address,
    base_fee: u256,
};

pub const SnapshotManager = struct {
    snapshots: std.AutoHashMapUnmanaged(u64, BlockSnapshot),
    next_id: u64,

    pub fn init() SnapshotManager {
        return .{ .snapshots = .{}, .next_id = 0 };
    }

    pub fn deinit(self: *SnapshotManager, allocator: std.mem.Allocator) void {
        self.snapshots.deinit(allocator);
    }

    /// Capture account state + block metadata. Returns snapshot ID.
    pub fn takeSnapshot(
        self: *SnapshotManager,
        allocator: std.mem.Allocator,
        state: *state_manager.StateManager,
        block_number: u64,
        timestamp: u64,
        coinbase: primitives.Address,
        base_fee: u256,
    ) !u64 {
        const state_snap_id = try state.snapshot();
        const id = self.next_id;
        self.next_id += 1;
        try self.snapshots.put(allocator, id, .{
            .state_snapshot_id = state_snap_id,
            .block_number = block_number,
            .timestamp = timestamp,
            .coinbase = coinbase,
            .base_fee = base_fee,
        });
        return id;
    }

    /// Revert account state + block metadata. Returns false if ID not found.
    /// On success, removes this snapshot and all newer ones (Ganache single-use semantics).
    pub fn revertToSnapshot(
        self: *SnapshotManager,
        allocator: std.mem.Allocator,
        state: *state_manager.StateManager,
        snapshot_id: u64,
        out_block_number: *u64,
        out_timestamp: *u64,
        out_coinbase: *primitives.Address,
        out_base_fee: *u256,
    ) !bool {
        const snap = self.snapshots.get(snapshot_id) orelse return false;
        try state.revertToSnapshot(snap.state_snapshot_id);
        out_block_number.* = snap.block_number;
        out_timestamp.* = snap.timestamp;
        out_coinbase.* = snap.coinbase;
        out_base_fee.* = snap.base_fee;
        // Remove this snapshot and all newer ones
        var ids_to_remove = std.ArrayList(u64).init(allocator);
        defer ids_to_remove.deinit();
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* >= snapshot_id) {
                try ids_to_remove.append(entry.key_ptr.*);
            }
        }
        for (ids_to_remove.items) |id| {
            _ = self.snapshots.remove(id);
        }
        return true;
    }
};
```

---

#### Step 13 — TEST: `SnapshotManager.revertToSnapshot` restores state

**File:** `src/snapshot_manager_test.zig` (extend)

```zig
test "revertToSnapshot restores account balance" {
    // snapshot, mutate balance, revert, verify original balance
}
test "revertToSnapshot restores block_number" { ... }
test "revertToSnapshot restores timestamp" { ... }
test "revertToSnapshot restores coinbase" { ... }
test "revertToSnapshot restores base_fee" { ... }
test "revertToSnapshot returns false for unknown id" { ... }
test "revertToSnapshot invalidates newer snapshots (nested semantics)" {
    // snap0, snap1 -> revert snap0 -> snap1 no longer valid
}
test "revertToSnapshot single-use: second revert with same id returns false" { ... }
```

(No additional implementation needed — covered by Step 12.)

---

### Phase C — Zevm: RPC handler functions

These are pure functions — no HTTP server required. They take a `SnapshotManager`, `StateManager`, and block-context mutable pointers, and return typed results.

#### Step 14 — TEST: `evm_snapshot` handler returns hex-encoded ID

**File:** `src/rpc/evm_handlers_test.zig` (new)

```zig
const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const snapshot_manager = @import("snapshot_manager.zig");
const evm_handlers = @import("rpc/evm_handlers.zig");

test "handleEvmSnapshot returns '0x0' for first snapshot" { ... }
test "handleEvmSnapshot returns '0x1' for second snapshot" { ... }
test "handleEvmSnapshot increments correctly across multiple calls" { ... }
```

#### Step 15 — IMPL: `src/rpc/evm_handlers.zig`

**File:** `src/rpc/evm_handlers.zig` (new)

```zig
const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const snapshot_manager = @import("../snapshot_manager.zig");

/// Handler for evm_snapshot / anvil_snapshot.
/// Returns owned hex string like "0x0", "0x1", etc. Caller must free.
pub fn handleEvmSnapshot(
    allocator: std.mem.Allocator,
    mgr: *snapshot_manager.SnapshotManager,
    state: *state_manager.StateManager,
    block_number: u64,
    timestamp: u64,
    coinbase: primitives.Address,
    base_fee: u256,
) ![]const u8 {
    const id = try mgr.takeSnapshot(allocator, state, block_number, timestamp, coinbase, base_fee);
    return std.fmt.allocPrint(allocator, "0x{x}", .{id});
}

/// Handler for evm_revert / anvil_revert.
/// Parses hex snapshot_id_hex, reverts state+metadata. Returns true on success.
pub fn handleEvmRevert(
    allocator: std.mem.Allocator,
    mgr: *snapshot_manager.SnapshotManager,
    state: *state_manager.StateManager,
    snapshot_id_hex: []const u8,
    out_block_number: *u64,
    out_timestamp: *u64,
    out_coinbase: *primitives.Address,
    out_base_fee: *u256,
) !bool {
    const hex = if (std.mem.startsWith(u8, snapshot_id_hex, "0x") or
                    std.mem.startsWith(u8, snapshot_id_hex, "0X"))
        snapshot_id_hex[2..]
    else
        snapshot_id_hex;
    const id = std.fmt.parseInt(u64, hex, 16) catch return false;
    return mgr.revertToSnapshot(allocator, state, id, out_block_number, out_timestamp, out_coinbase, out_base_fee);
}
```

---

#### Step 16 — TEST: `evm_revert` handler restores state and returns correct bool

**File:** `src/rpc/evm_handlers_test.zig` (extend)

```zig
test "handleEvmRevert returns true and restores balance on valid snapshot" {
    // snapshot, mutate balance via state, revert, verify balance and return==true
}
test "handleEvmRevert returns true and restores block_number" { ... }
test "handleEvmRevert returns false for hex id not found" { ... }
test "handleEvmRevert returns false for malformed hex" { ... }
test "handleEvmRevert anvil alias identical to evm alias" {
    // Both call same function — verified by shared test helper
}
```

(No additional implementation needed — covered by Step 15.)

---

### Phase D — Wire into `src/root.zig` and `build.zig`

#### Step 17 — IMPL: Export `snapshot_manager` from `src/root.zig`

**File:** `src/root.zig` (modify)

```zig
pub const snapshot_manager = @import("snapshot_manager.zig");
```

Add test import:
```zig
_ = @import("snapshot_manager_test.zig");
_ = @import("rpc/evm_handlers_test.zig");
```

#### Step 18 — IMPL: Add `jsonrpc` import to `build.zig`

**File:** `build.zig` (modify)

The `voltaire` dependency already exports a `jsonrpc` module. Add it to the `zevm` module's import list so handlers can use typed params/results:

```zig
const jsonrpc_mod = voltaire.module("jsonrpc");

// In the zevm module imports:
.{ .name = "jsonrpc", .module = jsonrpc_mod },
```

Check voltaire's `build.zig.zon` or module exports to confirm the module name. If not yet exported, add it upstream.

---

## Files to Create / Modify

### Voltaire (upstream — `../voltaire/packages/voltaire-zig/src/`)

| Action | Path |
|--------|------|
| Create | `jsonrpc/evm/snapshot/evm_snapshot.zig` |
| Create | `jsonrpc/evm/revert/evm_revert.zig` |
| Create | `jsonrpc/evm/methods.zig` |
| Modify | `jsonrpc/JsonRpc.zig` — add `.evm` variant + `methodName` arm |
| Modify | `jsonrpc/root.zig` — add `pub const evm = @import("evm/methods.zig");` |

### Zevm (`src/`)

| Action | Path |
|--------|------|
| Create | `src/snapshot_manager.zig` |
| Create | `src/snapshot_manager_test.zig` |
| Create | `src/rpc/evm_handlers.zig` |
| Create | `src/rpc/evm_handlers_test.zig` |
| Modify | `src/root.zig` — add `snapshot_manager` export + test imports |
| Modify | `build.zig` — add `jsonrpc` module import |

---

## Key Function Signatures

```zig
// src/snapshot_manager.zig
pub fn takeSnapshot(
    self: *SnapshotManager,
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    block_number: u64,
    timestamp: u64,
    coinbase: primitives.Address,
    base_fee: u256,
) !u64

pub fn revertToSnapshot(
    self: *SnapshotManager,
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    snapshot_id: u64,
    out_block_number: *u64,
    out_timestamp: *u64,
    out_coinbase: *primitives.Address,
    out_base_fee: *u256,
) !bool

// src/rpc/evm_handlers.zig
pub fn handleEvmSnapshot(
    allocator: std.mem.Allocator,
    mgr: *snapshot_manager.SnapshotManager,
    state: *state_manager.StateManager,
    block_number: u64,
    timestamp: u64,
    coinbase: primitives.Address,
    base_fee: u256,
) ![]const u8   // owned hex string, caller frees

pub fn handleEvmRevert(
    allocator: std.mem.Allocator,
    mgr: *snapshot_manager.SnapshotManager,
    state: *state_manager.StateManager,
    snapshot_id_hex: []const u8,
    out_block_number: *u64,
    out_timestamp: *u64,
    out_coinbase: *primitives.Address,
    out_base_fee: *u256,
) !bool
```

---

## Tests to Write

### Unit tests (voltaire — `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/`)

| Test file | Test name |
|-----------|-----------|
| `snapshot/evm_snapshot.zig` | `evm_snapshot Params parses empty array` |
| `snapshot/evm_snapshot.zig` | `evm_snapshot Params parses null params` |
| `snapshot/evm_snapshot.zig` | `evm_snapshot Result serializes as quantity hex string` |
| `revert/evm_revert.zig` | `evm_revert Params parses [snapshotId]` |
| `revert/evm_revert.zig` | `evm_revert Params rejects empty array` |
| `revert/evm_revert.zig` | `evm_revert Result serializes true` |
| `revert/evm_revert.zig` | `evm_revert Result serializes false` |
| `methods.zig` | `EvmMethod.fromMethodName resolves evm_snapshot` |
| `methods.zig` | `EvmMethod.fromMethodName resolves evm_revert` |
| `methods.zig` | `EvmMethod.fromMethodName resolves anvil_snapshot` |
| `methods.zig` | `EvmMethod.fromMethodName resolves anvil_revert` |
| `methods.zig` | `EvmMethod.fromMethodName rejects unknown method` |
| `methods.zig` | `EvmMethod.methodName round-trips for all tags` |
| `JsonRpc.zig` | `JsonRpcMethod includes evm namespace` |

### Unit tests (zevm — `src/`)

| Test file | Test name |
|-----------|-----------|
| `snapshot_manager_test.zig` | `takeSnapshot returns incrementing IDs starting at 0` |
| `snapshot_manager_test.zig` | `takeSnapshot stores block_number` |
| `snapshot_manager_test.zig` | `takeSnapshot stores timestamp` |
| `snapshot_manager_test.zig` | `takeSnapshot stores coinbase` |
| `snapshot_manager_test.zig` | `takeSnapshot stores base_fee` |
| `snapshot_manager_test.zig` | `two snapshots have different IDs` |
| `snapshot_manager_test.zig` | `revertToSnapshot restores account balance` |
| `snapshot_manager_test.zig` | `revertToSnapshot restores block_number` |
| `snapshot_manager_test.zig` | `revertToSnapshot restores timestamp` |
| `snapshot_manager_test.zig` | `revertToSnapshot restores coinbase` |
| `snapshot_manager_test.zig` | `revertToSnapshot restores base_fee` |
| `snapshot_manager_test.zig` | `revertToSnapshot returns false for unknown id` |
| `snapshot_manager_test.zig` | `revertToSnapshot invalidates newer snapshots (nested semantics)` |
| `snapshot_manager_test.zig` | `revertToSnapshot single-use: second revert with same id returns false` |
| `rpc/evm_handlers_test.zig` | `handleEvmSnapshot returns '0x0' for first snapshot` |
| `rpc/evm_handlers_test.zig` | `handleEvmSnapshot returns '0x1' for second snapshot` |
| `rpc/evm_handlers_test.zig` | `handleEvmRevert returns true and restores balance on valid snapshot` |
| `rpc/evm_handlers_test.zig` | `handleEvmRevert returns true and restores block_number` |
| `rpc/evm_handlers_test.zig` | `handleEvmRevert returns false for hex id not found` |
| `rpc/evm_handlers_test.zig` | `handleEvmRevert returns false for malformed hex` |
| `rpc/evm_handlers_test.zig` | `handleEvmRevert anvil alias is same function as evm alias` |

---

## Risks and Mitigations

### Risk 1: `voltaire` build doesn't export a `jsonrpc` module yet

**Likelihood:** Medium — voltaire exposes `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles` but `jsonrpc` may not be a top-level module export.

**Mitigation:** Check voltaire's `build.zig.zon` exports. If missing, add the `jsonrpc` module export to voltaire's build before wiring zevm's `build.zig`.

---

### Risk 2: `StateManager.revertToSnapshot` invalidates snapshot IDs internally

**Likelihood:** Known — voltaire's `revertToSnapshot` already removes snapshot N and all IDs >= N.

**Impact:** `SnapshotManager.revertToSnapshot` must remove its own entries for the same ID range independently (the state manager removes its checkpoint entries; the snapshot manager removes its block-metadata entries).

**Mitigation:** The `SnapshotManager.revertToSnapshot` implementation already handles this. Tests explicitly verify that attempting to revert to a newer snapshot after reverting to an older one returns `false`.

---

### Risk 3: Hex format edge cases (`"0x0"` vs `"0X0"` vs `"1"`)

**Likelihood:** Low but possible from some clients.

**Mitigation:** `handleEvmRevert` strips both `"0x"` and `"0X"` prefixes and falls back to no prefix. Covered by `handleEvmRevert returns false for malformed hex` test.

---

### Risk 4: `anvil_snapshot` / `anvil_revert` param/result shape differs from `evm_*`

**Likelihood:** None — EDR, Foundry, and tevm all confirm identical shapes.

**Mitigation:** Both aliases use `evm_snapshot.Params`/`evm_snapshot.Result` and `evm_revert.Params`/`evm_revert.Result` types directly in `EvmMethod`. Handler layer routes both to the same `handleEvmSnapshot` / `handleEvmRevert` function.

---

### Risk 5: `SnapshotManager` initialized with zero IDs creates a ID mismatch with voltaire's auto-incrementing IDs

**Likelihood:** None as long as `SnapshotManager` stores the voltaire snapshot ID (returned by `state.snapshot()`) separately from its own sequential ID. The two ID sequences are independent.

**Mitigation:** `BlockSnapshot.state_snapshot_id` records the voltaire state snapshot ID; `SnapshotManager.next_id` produces the zevm-level ID returned to clients. These are never confused.

---

## Verification Against Acceptance Criteria

| Acceptance criterion | Verified by |
|----------------------|-------------|
| `evm_snapshot` exists as callable RPC method | `handleEvmSnapshot` function + handler test |
| `evm_snapshot` calls `StateManager.snapshot()` | `SnapshotManager.takeSnapshot` calls `state.snapshot()` — verified by `revertToSnapshot restores account balance` |
| `evm_snapshot` returns ID as hex string e.g. `"0x1"` | `handleEvmSnapshot returns '0x1' for second snapshot` |
| `evm_revert` exists as callable RPC method | `handleEvmRevert` function + handler test |
| `evm_revert` accepts hex snapshot ID | `handleEvmRevert` parses `snapshot_id_hex` — verified by revert tests |
| `evm_revert` calls `StateManager.revertToSnapshot()` | `SnapshotManager.revertToSnapshot` calls `state.revertToSnapshot()` — verified by balance restore test |
| `evm_revert` returns `true` on success | `handleEvmRevert returns true and restores balance on valid snapshot` |
| `evm_revert` returns `false` on invalid ID | `handleEvmRevert returns false for hex id not found` |
| Block-level metadata rolled back per EDR snapshot.rs | `revertToSnapshot restores block_number/timestamp/coinbase/base_fee` |
| `anvil_snapshot` / `anvil_revert` aliases | Tags in `EvmMethod` + `fromMethodName` tests |
| `zig build test` passes | All tests in `src/root.zig` test block |

---

## How to Run

```bash
# Voltaire upstream (run first)
cd ../voltaire
zig build test

# Zevm
cd /Users/williamcory/zevm
zig build test
```
