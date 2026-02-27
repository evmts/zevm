# Research: add-anvil-hardhat-jsonrpc-namespaces

**Ticket:** Add anvil and hardhat namespaces to voltaire-zig jsonrpc module  
**Ticket ID:** add-anvil-hardhat-jsonrpc-namespaces  
**Category:** cat-6-mining  
**Upstream Dependency:** voltaire (../voltaire)

---

## Goal

Add `anvil/` and `hardhat/` directories to `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/` with method definitions for:
- `evm_mine` (anvil)
- `evm_setAutomine` (anvil)
- `evm_setIntervalMining` (anvil)
- `hardhat_mine` (hardhat)

Each method needs:
- `Params` type with JSON serde (`jsonStringify`, `jsonParseFromValue`)
- `Result` type with JSON serde
- `method` constant with the RPC method name

---

## Current voltaire-zig JSON-RPC Structure

### Existing Namespaces

```
/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/
├── JsonRpc.zig           # Root union combining all namespaces
├── root.zig              # Re-exports all namespaces
├── types.zig             # Shared types (Address, Hash, Quantity, BlockTag, BlockSpec)
├── types/
│   ├── Address.zig
│   ├── Hash.zig
│   ├── Quantity.zig
│   ├── BlockTag.zig
│   └── BlockSpec.zig
├── eth/
│   ├── methods.zig       # EthMethod union (43 methods)
│   ├── accounts/eth_accounts.zig
│   ├── blockNumber/eth_blockNumber.zig
│   └── ... (41 more methods)
├── debug/
│   ├── methods.zig       # DebugMethod union (5 methods)
│   └── ...
└── engine/
    ├── methods.zig       # EngineMethod union (19 methods)
    └── ...
```

### Pattern from Existing Methods

**File:** `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/blockNumber/eth_blockNumber.zig`

```zig
const std = @import("std");
const types = @import("../../types.zig");

pub const EthBlockNumber = @This();

pub const method = "eth_blockNumber";

pub const Params = struct {
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        _ = self;
        try jws.write(.{});
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        _ = allocator;
        _ = source;
        _ = options;
        return Params{};
    }
};

pub const Result = struct {
    value: types.Quantity,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return Result{
            .value = try std.json.innerParseFromValue(types.Quantity, allocator, source, options),
        };
    }
};
```

### Method Registry Pattern

**File:** `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig`

```zig
const std = @import("std");

const eth_blockNumber = @import("blockNumber/eth_blockNumber.zig");
// ... more imports

pub const EthMethod = union(enum) {
    eth_blockNumber: struct {
        params: eth_blockNumber.Params,
        result: eth_blockNumber.Result,
    },
    // ... more methods

    pub fn methodName(self: EthMethod) []const u8 {
        return switch (self) {
            .eth_blockNumber => eth_blockNumber.method,
            // ...
        };
    }

    pub fn fromMethodName(method_name: []const u8) !std.meta.Tag(EthMethod) {
        const map = std.StaticStringMap(std.meta.Tag(EthMethod)).initComptime(.{
            .{ "eth_blockNumber", .eth_blockNumber },
            // ...
        });
        return map.get(method_name) orelse error.UnknownMethod;
    }
};
```

---

## Method Specifications

### 1. evm_mine

**Purpose:** Mine a single block with optional timestamp

**Method Names:**
- `evm_mine` (primary)
- `anvil_mine_detailed` (variant returning block details - not in scope)

**Params:**
```zig
pub const Params = struct {
    /// Optional timestamp for the mined block
    timestamp: ?types.Quantity = null,
    
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        if (self.timestamp) |ts| {
            try jws.write(ts);
        }
        try jws.endArray();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        _ = allocator;
        if (source != .array) return error.UnexpectedToken;
        
        var params = Params{};
        if (source.array.items.len > 0) {
            params.timestamp = try std.json.innerParseFromValue(?types.Quantity, allocator, source.array.items[0], options);
        }
        return params;
    }
};
```

**Result:**
```zig
pub const Result = struct {
    /// Returns "0" (string) per EDR, or "0x0" (hex) per Foundry
    value: []const u8,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        _ = allocator;
        _ = options;
        switch (source) {
            .string => |s| return Result{ .value = s },
            else => return error.UnexpectedToken,
        }
    }
};
```

**Behavior Notes from References:**
- EDR returns `"0"` (string) - see `edr/crates/edr_provider/src/requests/methods.rs:1481`
- Foundry returns `"0x0"` (hex)
- Mines regardless of current mining mode
- Optional timestamp parameter sets the next block's timestamp

---

### 2. evm_setAutomine

**Purpose:** Enable or disable automatic mining on each transaction

**Method Names:**
- `evm_setAutomine` (primary)
- `anvil_setAutomine` (alias per Foundry)

**Params:**
```zig
pub const Params = struct {
    /// true to enable automining, false to disable
    enabled: bool,

    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        try jws.write(self.enabled);
        try jws.endArray();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        _ = allocator;
        if (source != .array) return error.UnexpectedToken;
        if (source.array.items.len != 1) return error.InvalidParamCount;
        
        return Params{
            .enabled = try std.json.innerParseFromValue(bool, allocator, source.array.items[0], options),
        };
    }
};
```

**Result:**
```zig
pub const Result = struct {
    /// Always returns true
    value: bool,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return Result{
            .value = try std.json.innerParseFromValue(bool, allocator, source, options),
        };
    }
};
```

**Behavior Notes from References:**
- EDR returns `true` on success - see `edr/crates/edr_provider/src/requests/methods.rs:1541`
- When enabled, each transaction triggers a block mine
- When disabled, transactions accumulate in mempool until manual mine
- Default state in most dev nodes: enabled

---

### 3. evm_setIntervalMining

**Purpose:** Enable mining at a fixed time interval

**Method Names:**
- `evm_setIntervalMining` (primary)
- `anvil_setIntervalMining` (alias per Foundry)

**Params:**
```zig
pub const Params = struct {
    /// Interval in seconds (0 to disable)
    interval: types.Quantity,

    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        try jws.write(self.interval);
        try jws.endArray();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        if (source != .array) return error.UnexpectedToken;
        if (source.array.items.len != 1) return error.InvalidParamCount;
        
        return Params{
            .interval = try std.json.innerParseFromValue(types.Quantity, allocator, source.array.items[0], options),
        };
    }
};
```

**Result:**
```zig
pub const Result = struct {
    /// Always returns true
    value: bool,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return Result{
            .value = try std.json.innerParseFromValue(bool, allocator, source, options),
        };
    }
};
```

**Behavior Notes from References:**
- EDR accepts interval in milliseconds or range `[min, max]` - see `edr/crates/edr_provider/src/requests/methods.rs:1595-1641`
- Foundry uses seconds - see `foundry/crates/anvil/core/src/eth/mod.rs:385-386`
- Interval of 0 disables interval mining
- Mutually exclusive with automine (enabling one should disable the other)

---

### 4. hardhat_mine

**Purpose:** Mine multiple blocks with optional interval between timestamps

**Method Names:**
- `hardhat_mine` (primary)
- `anvil_mine` (alias per Foundry)

**Params:**
```zig
pub const Params = struct {
    /// Number of blocks to mine (defaults to 1)
    block_count: ?types.Quantity = null,
    /// Interval in seconds between block timestamps (defaults to 1)
    interval: ?types.Quantity = null,

    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        if (self.block_count) |bc| {
            try jws.write(bc);
            if (self.interval) |int| {
                try jws.write(int);
            }
        }
        try jws.endArray();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        if (source != .array) return error.UnexpectedToken;
        
        var params = Params{};
        if (source.array.items.len > 0) {
            params.block_count = try std.json.innerParseFromValue(types.Quantity, allocator, source.array.items[0], options);
        }
        if (source.array.items.len > 1) {
            params.interval = try std.json.innerParseFromValue(types.Quantity, allocator, source.array.items[1], options);
        }
        return params;
    }
};
```

**Result:**
```zig
pub const Result = struct {
    /// Always returns true
    value: bool,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return Result{
            .value = try std.json.innerParseFromValue(bool, allocator, source, options),
        };
    }
};
```

**Behavior Notes from References:**
- EDR returns `true` - see `edr/crates/edr_provider/src/requests/methods.rs:1921`
- Both parameters are optional
- Default block count: 1
- Default interval: 1 second
- Interval applies to timestamp spacing, not mining delay (mines instantly)

---

## Files to Create in voltaire

### Directory Structure

```
/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/
├── anvil/
│   ├── methods.zig
│   ├── mine/
│   │   └── anvil_mine.zig          # evm_mine
│   ├── setAutomine/
│   │   └── anvil_setAutomine.zig   # evm_setAutomine
│   └── setIntervalMining/
│       └── anvil_setIntervalMining.zig  # evm_setIntervalMining
└── hardhat/
    ├── methods.zig
    └── mine/
        └── hardhat_mine.zig        # hardhat_mine
```

### Files to Modify

1. `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
   - Add exports for `anvil` and `hardhat` namespaces

2. `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
   - Add `anvil` and `hardhat` to the root union

---

## Reference Implementations

### Foundry Anvil (Rust)

**File:** `/Users/williamcory/zevm/foundry/crates/anvil/core/src/eth/mod.rs`

```rust
/// Returns true if automatic mining is enabled, and false.
#[serde(rename = "anvil_getAutomine", alias = "hardhat_getAutomine", with = "empty_params")]
GetAutoMine(()),

/// Mines a series of blocks
#[serde(rename = "anvil_mine", alias = "hardhat_mine")]
Mine(
    /// Number of blocks to mine, if not set `1` block is mined
    #[serde(default, deserialize_with = "deserialize_number_opt")]
    Option<U256>,
    /// The time interval between each block in seconds, defaults to `1` seconds
    #[serde(default, deserialize_with = "deserialize_number_opt")]
    Option<U256>,
),

/// Enables or disables, based on the single boolean argument, the automatic mining of new
/// blocks with each new transaction submitted to the network.
#[serde(rename = "anvil_setAutomine", alias = "evm_setAutomine", with = "sequence")]
SetAutomine(bool),

/// Sets the mining behavior to interval with the given interval (seconds)
#[serde(rename = "anvil_setIntervalMining", alias = "evm_setIntervalMining", with = "sequence")]
SetIntervalMining(u64),

/// Mine a single block
#[serde(rename = "evm_mine")]
EvmMine(#[serde(default)] Option<Params<Option<MineOptions>>>),
```

### EDR (Rust)

**File:** `/Users/williamcory/zevm/edr/crates/edr_provider/src/requests/methods.rs`

```rust
/// # `evm_mine`
/// Mines a single block, including as many transactions from the
/// transaction pool as possible.
#[serde(
    rename = "evm_mine",
    serialize_with = "optional_single_to_sequence",
    deserialize_with = "sequence_to_optional_single"
)]
EvmMine(
    /// `QUANTITY` - Optional timestamp for the mined block.
    Option<Timestamp>,
),

/// # `evm_setAutomine`
/// Enables or disables automatic mining of new blocks with each new
/// transaction submitted to the provider.
#[serde(rename = "evm_setAutomine", with = "edr_eth::serde::sequence")]
EvmSetAutomine(
    /// `Boolean` - `true` to enable automining, `false` to disable.
    bool,
),

/// # `evm_setIntervalMining`
/// Enables, disables, or re-configures mining of blocks at a pre-configured
/// time interval.
#[serde(rename = "evm_setIntervalMining", with = "edr_eth::serde::sequence")]
EvmSetIntervalMining(
    /// `QUANTITY|Array` - The interval in milliseconds, or a
    /// two-element `[min, max]` array for a random range. Pass `0` to
    /// disable.
    IntervalConfig,
),

/// # `hardhat_mine`
/// Mines one or more blocks with an optional fixed time interval
/// between them.
#[serde(rename = "hardhat_mine")]
Mine(
    /// `QUANTITY` - Number of blocks to mine. Defaults to `1`.
    #[serde(default, with = "alloy_serde::quantity::opt")]
    Option<u64>,
    /// `QUANTITY` - Interval in seconds between each mined block.
    /// Defaults to `1`.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "alloy_serde::quantity::opt"
    )]
    Option<u64>,
),
```

### TEVM (TypeScript)

**File:** `/Users/williamcory/tevm-monorepo/packages/actions/src/Mine/MineParams.ts`

```typescript
export type MineParams<TThrowOnFail extends boolean = boolean> = BaseParams<TThrowOnFail> &
    MineEvents & {
        readonly tx?: Hex
        readonly blockCount?: number
        readonly interval?: number
    }
```

---

## Testing

After implementing in voltaire, run voltaire tests:

```bash
cd /Users/williamcory/voltaire/packages/voltaire-zig
zig build test
```

### Test Cases to Port (for zevm later)

**Foundry:**
- `foundry/crates/anvil/tests/it/anvil_api.rs`
  - `evm_mine` tests (lines 279-285, 1010-1030)
  - `anvil_mine` tests (lines 1032-1085)

**EDR:**
- `edr/hardhat-tests/test/internal/hardhat-network/provider/modules/evm.ts`
- `edr/hardhat-tests/test/internal/hardhat-network/provider/modules/hardhat.ts`

---

## Implementation Notes

1. **Upstream Location:** All types go in voltaire (`../voltaire`), not in zevm
2. **Follow Existing Pattern:** Match the file/directory structure of `eth/blockNumber/eth_blockNumber.zig`
3. **JSON Serde:** Each Params and Result needs `jsonStringify` and `jsonParseFromValue`
4. **Type Safety:** Use `types.Quantity` for numeric values, `?T` for optional params
5. **Method Aliases:** The type definitions don't need aliases - those are handled at dispatch level
6. **Zig Style:**
   - No local type aliases (use fully qualified paths)
   - No stored allocators
   - Pass allocator explicitly to parse functions

---

## Summary

This ticket adds 4 method definitions across 2 new namespaces (anvil, hardhat):

| Method | Namespace | Params | Result |
|--------|-----------|--------|--------|
| evm_mine | anvil | `[timestamp?]` | `"0"` or `"0x0"` |
| evm_setAutomine | anvil | `[enabled: bool]` | `true` |
| evm_setIntervalMining | anvil | `[interval: Quantity]` | `true` |
| hardhat_mine | hardhat | `[block_count?, interval?]` | `true` |

The implementation should mirror the existing eth/debug/engine patterns in voltaire-zig.
