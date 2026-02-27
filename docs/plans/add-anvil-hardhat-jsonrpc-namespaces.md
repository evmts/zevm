# Plan: Add anvil and hardhat Namespaces to voltaire-zig JSON-RPC Module

**Ticket:** add-anvil-hardhat-jsonrpc-namespaces
**Category:** cat-6-mining
**Upstream Repo:** voltaire (`../voltaire/packages/voltaire-zig/src/jsonrpc/`)
**Status:** Planning

---

## Overview

Add two new namespace directories (`anvil/` and `hardhat/`) to the voltaire-zig JSON-RPC type system, following the exact pattern established by `eth/`, `debug/`, and `engine/`. This is pure type infrastructure — Params/Result types with JSON serde — with no handler logic. zevm will later implement the actual mining handlers on top of these types.

### Methods in scope

| Method | Namespace file | Params | Result |
|--------|---------------|--------|--------|
| `evm_mine` | `anvil/mine/anvil_mine.zig` | `[timestamp?]` | `"0x0"` string |
| `evm_setAutomine` | `anvil/setAutomine/anvil_setAutomine.zig` | `[enabled: bool]` | `true` |
| `evm_setIntervalMining` | `anvil/setIntervalMining/anvil_setIntervalMining.zig` | `[interval: Quantity]` | `true` |
| `hardhat_mine` | `hardhat/mine/hardhat_mine.zig` | `[block_count?, interval?]` | `true` |

All work belongs in **voltaire**, not in zevm.

---

## TDD Step Order

### Phase 1 — Tests First (write failing tests before any implementation)

**Step 1.1** — Write tests for `evm_mine` Params/Result serde
**Step 1.2** — Write tests for `evm_setAutomine` Params/Result serde
**Step 1.3** — Write tests for `evm_setIntervalMining` Params/Result serde
**Step 1.4** — Write tests for `hardhat_mine` Params/Result serde
**Step 1.5** — Write tests for `AnvilMethod` union dispatch
**Step 1.6** — Write tests for `HardhatMethod` union dispatch

Run `zig build test` — all new tests should **fail to compile** at this point.

### Phase 2 — Implementation (make the tests pass)

**Step 2.1** — Create `anvil/mine/anvil_mine.zig`
**Step 2.2** — Create `anvil/setAutomine/anvil_setAutomine.zig`
**Step 2.3** — Create `anvil/setIntervalMining/anvil_setIntervalMining.zig`
**Step 2.4** — Create `anvil/methods.zig`
**Step 2.5** — Create `hardhat/mine/hardhat_mine.zig`
**Step 2.6** — Create `hardhat/methods.zig`
**Step 2.7** — Update `jsonrpc/root.zig` to export `anvil` and `hardhat`
**Step 2.8** — Update `jsonrpc/JsonRpc.zig` to add `anvil` and `hardhat` to the root union

Run `zig build test` — all tests should **pass**.

---

## Files to Create

### `voltaire/packages/voltaire-zig/src/jsonrpc/anvil/mine/anvil_mine.zig`

```zig
const std = @import("std");
const types = @import("../../types.zig");

/// Mines a single block, including as many transactions from the
/// transaction pool as possible.
pub const EvmMine = @This();

/// The JSON-RPC method name
pub const method = "evm_mine";

/// Parameters for `evm_mine`
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
        if (source != .array) return error.UnexpectedToken;
        if (source.array.items.len == 0) return Params{};
        return Params{
            .timestamp = try std.json.innerParseFromValue(types.Quantity, allocator, source.array.items[0], options),
        };
    }
};

/// Result for `evm_mine`
/// Returns "0x0" per Foundry convention (string)
pub const Result = struct {
    value: []const u8,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Result {
        switch (source) {
            .string => |s| return Result{ .value = s },
            else => return error.UnexpectedToken,
        }
    }
};

test "evm_mine Params: no timestamp parses from empty array" {
    const source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[]", .{});
    defer source.deinit();
    const params = try Params.jsonParseFromValue(std.testing.allocator, source.value, .{});
    try std.testing.expectEqual(@as(?types.Quantity, null), params.timestamp);
}

test "evm_mine Params: timestamp parses from single-element array" {
    const source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[\"0x64\"]", .{});
    defer source.deinit();
    const params = try Params.jsonParseFromValue(std.testing.allocator, source.value, .{});
    try std.testing.expect(params.timestamp != null);
}

test "evm_mine Params: non-array returns error" {
    const source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "null", .{});
    defer source.deinit();
    const result = Params.jsonParseFromValue(std.testing.allocator, source.value, .{});
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "evm_mine Result: parses string value" {
    const source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "\"0x0\"", .{});
    defer source.deinit();
    const result = try Result.jsonParseFromValue(std.testing.allocator, source.value, .{});
    try std.testing.expectEqualStrings("0x0", result.value);
}

test "evm_mine Result: non-string returns error" {
    const source = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "0", .{});
    defer source.deinit();
    const result = Result.jsonParseFromValue(std.testing.allocator, source.value, .{});
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "evm_mine: method name constant" {
    try std.testing.expectEqualStrings("evm_mine", method);
}
```

### `voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setAutomine/anvil_setAutomine.zig`

```zig
const std = @import("std");

/// Enables or disables automatic mining of new blocks with each new
/// transaction submitted to the provider.
pub const EvmSetAutomine = @This();

/// The JSON-RPC method name
pub const method = "evm_setAutomine";

/// Parameters for `evm_setAutomine`
pub const Params = struct {
    /// true to enable automining, false to disable
    enabled: bool,

    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        try jws.write(self.enabled);
        try jws.endArray();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params {
        if (source != .array) return error.UnexpectedToken;
        if (source.array.items.len != 1) return error.InvalidParamCount;
        return Params{
            .enabled = try std.json.innerParseFromValue(bool, allocator, source.array.items[0], options),
        };
    }
};

/// Result for `evm_setAutomine` — always returns true
pub const Result = struct {
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

test "evm_setAutomine Params: true parses correctly" { ... }
test "evm_setAutomine Params: false parses correctly" { ... }
test "evm_setAutomine Params: non-array returns error" { ... }
test "evm_setAutomine Params: wrong param count returns error" { ... }
test "evm_setAutomine Result: true parses correctly" { ... }
test "evm_setAutomine: method name constant" { ... }
```

### `voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setIntervalMining/anvil_setIntervalMining.zig`

```zig
const std = @import("std");
const types = @import("../../types.zig");

/// Enables, disables, or re-configures mining of blocks at a fixed interval.
/// Interval of 0 disables interval mining.
pub const EvmSetIntervalMining = @This();

pub const method = "evm_setIntervalMining";

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

pub const Result = struct {
    value: bool,
    // jsonStringify + jsonParseFromValue (same as setAutomine)
};

test "evm_setIntervalMining Params: numeric interval parses" { ... }
test "evm_setIntervalMining Params: hex interval parses" { ... }
test "evm_setIntervalMining Params: non-array returns error" { ... }
test "evm_setIntervalMining Params: wrong param count returns error" { ... }
test "evm_setIntervalMining Result: true parses" { ... }
test "evm_setIntervalMining: method name constant" { ... }
```

### `voltaire/packages/voltaire-zig/src/jsonrpc/anvil/methods.zig`

```zig
const std = @import("std");

const anvil_mine = @import("mine/anvil_mine.zig");
const anvil_setAutomine = @import("setAutomine/anvil_setAutomine.zig");
const anvil_setIntervalMining = @import("setIntervalMining/anvil_setIntervalMining.zig");

pub const AnvilMethod = union(enum) {
    evm_mine: struct {
        params: anvil_mine.Params,
        result: anvil_mine.Result,
    },
    evm_setAutomine: struct {
        params: anvil_setAutomine.Params,
        result: anvil_setAutomine.Result,
    },
    evm_setIntervalMining: struct {
        params: anvil_setIntervalMining.Params,
        result: anvil_setIntervalMining.Result,
    },

    pub fn methodName(self: AnvilMethod) []const u8 {
        return switch (self) {
            .evm_mine => anvil_mine.method,
            .evm_setAutomine => anvil_setAutomine.method,
            .evm_setIntervalMining => anvil_setIntervalMining.method,
        };
    }

    pub fn fromMethodName(method_name: []const u8) !std.meta.Tag(AnvilMethod) {
        const map = std.StaticStringMap(std.meta.Tag(AnvilMethod)).initComptime(.{
            .{ "evm_mine", .evm_mine },
            .{ "evm_setAutomine", .evm_setAutomine },
            .{ "evm_setIntervalMining", .evm_setIntervalMining },
        });
        return map.get(method_name) orelse error.UnknownMethod;
    }
};
```

### `voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/mine/hardhat_mine.zig`

```zig
const std = @import("std");
const types = @import("../../types.zig");

/// Mines one or more blocks with an optional fixed time interval between them.
pub const HardhatMine = @This();

pub const method = "hardhat_mine";

pub const Params = struct {
    /// Number of blocks to mine. Defaults to 1 when null.
    block_count: ?types.Quantity = null,
    /// Interval in seconds between block timestamps. Defaults to 1 when null.
    interval: ?types.Quantity = null,

    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        if (self.block_count) |bc| {
            try jws.write(bc);
            if (self.interval) |iv| {
                try jws.write(iv);
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

pub const Result = struct {
    value: bool,
    // jsonStringify + jsonParseFromValue (same bool pattern)
};

test "hardhat_mine Params: empty array gives defaults" { ... }
test "hardhat_mine Params: block_count only" { ... }
test "hardhat_mine Params: block_count and interval" { ... }
test "hardhat_mine Params: non-array returns error" { ... }
test "hardhat_mine Result: true parses" { ... }
test "hardhat_mine: method name constant" { ... }
```

### `voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/methods.zig`

```zig
const std = @import("std");

const hardhat_mine = @import("mine/hardhat_mine.zig");

pub const HardhatMethod = union(enum) {
    hardhat_mine: struct {
        params: hardhat_mine.Params,
        result: hardhat_mine.Result,
    },

    pub fn methodName(self: HardhatMethod) []const u8 {
        return switch (self) {
            .hardhat_mine => hardhat_mine.method,
        };
    }

    pub fn fromMethodName(method_name: []const u8) !std.meta.Tag(HardhatMethod) {
        const map = std.StaticStringMap(std.meta.Tag(HardhatMethod)).initComptime(.{
            .{ "hardhat_mine", .hardhat_mine },
        });
        return map.get(method_name) orelse error.UnknownMethod;
    }
};
```

---

## Files to Modify

### `voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`

Add exports for the two new namespaces:

```zig
pub const anvil = @import("anvil/methods.zig");
pub const hardhat = @import("hardhat/methods.zig");
```

Also update the doc comment from "65 methods total" to "69 methods total".

### `voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`

Add imports and union variants:

```zig
const anvilMethods = @import("anvil/methods.zig");
const hardhatMethods = @import("hardhat/methods.zig");

// In JsonRpcMethod union:
anvil: anvilMethods.AnvilMethod,
hardhat: hardhatMethods.HardhatMethod,

// In methodName():
.anvil => |m| m.methodName(),
.hardhat => |m| m.methodName(),
```

---

## Tests to Write

All tests live inline in each method file (following voltaire's existing pattern — no separate test files, tests are co-located with types). The `refAllDecls` in `root.zig` picks them up automatically.

### Unit tests per method file

#### `anvil_mine.zig`
- `evm_mine: method name constant` — `expectEqualStrings("evm_mine", method)`
- `evm_mine Params: no timestamp parses from empty array` — `[]` → `timestamp == null`
- `evm_mine Params: timestamp parses from single-element array` — `["0x64"]` → `timestamp != null`
- `evm_mine Params: non-array source returns UnexpectedToken` — `null` → error
- `evm_mine Params: jsonStringify emits empty array when no timestamp` — roundtrip check
- `evm_mine Params: jsonStringify emits array with one element when timestamp present`
- `evm_mine Result: parses string "0x0"` — `.string = "0x0"` → `value == "0x0"`
- `evm_mine Result: parses string "0"` — `.string = "0"` → `value == "0"`
- `evm_mine Result: non-string returns UnexpectedToken` — `.integer = 0` → error
- `evm_mine Result: jsonStringify emits string`

#### `anvil_setAutomine.zig`
- `evm_setAutomine: method name constant`
- `evm_setAutomine Params: true` — `[true]` → `enabled == true`
- `evm_setAutomine Params: false` — `[false]` → `enabled == false`
- `evm_setAutomine Params: non-array returns UnexpectedToken`
- `evm_setAutomine Params: empty array returns InvalidParamCount`
- `evm_setAutomine Params: two-element array returns InvalidParamCount`
- `evm_setAutomine Params: jsonStringify roundtrip`
- `evm_setAutomine Result: true parses`
- `evm_setAutomine Result: false parses`

#### `anvil_setIntervalMining.zig`
- `evm_setIntervalMining: method name constant`
- `evm_setIntervalMining Params: numeric interval` — `["0x5"]`
- `evm_setIntervalMining Params: zero disables` — `["0x0"]`
- `evm_setIntervalMining Params: non-array returns UnexpectedToken`
- `evm_setIntervalMining Params: wrong param count returns InvalidParamCount`
- `evm_setIntervalMining Params: jsonStringify roundtrip`
- `evm_setIntervalMining Result: true parses`

#### `hardhat_mine.zig`
- `hardhat_mine: method name constant`
- `hardhat_mine Params: empty array` — both null
- `hardhat_mine Params: block_count only` — `["0x5"]` → `block_count != null, interval == null`
- `hardhat_mine Params: both params` — `["0x5","0x1"]` → both non-null
- `hardhat_mine Params: non-array returns UnexpectedToken`
- `hardhat_mine Params: jsonStringify with no params emits []`
- `hardhat_mine Params: jsonStringify with block_count only emits one element`
- `hardhat_mine Params: jsonStringify with both emits two elements`
- `hardhat_mine Result: true parses`

### Integration tests in `methods.zig` files

#### `anvil/methods.zig`
- `AnvilMethod: fromMethodName("evm_mine") returns .evm_mine`
- `AnvilMethod: fromMethodName("evm_setAutomine") returns .evm_setAutomine`
- `AnvilMethod: fromMethodName("evm_setIntervalMining") returns .evm_setIntervalMining`
- `AnvilMethod: fromMethodName("unknown") returns UnknownMethod`
- `AnvilMethod: methodName round-trips through each variant`

#### `hardhat/methods.zig`
- `HardhatMethod: fromMethodName("hardhat_mine") returns .hardhat_mine`
- `HardhatMethod: fromMethodName("unknown") returns UnknownMethod`
- `HardhatMethod: methodName returns "hardhat_mine"`

---

## Full Directory Structure After Implementation

```
voltaire/packages/voltaire-zig/src/jsonrpc/
├── JsonRpc.zig           ← MODIFIED: add anvil/hardhat variants
├── root.zig              ← MODIFIED: add anvil/hardhat exports
├── anvil/
│   ├── methods.zig       ← NEW: AnvilMethod union (3 methods)
│   ├── mine/
│   │   └── anvil_mine.zig          ← NEW: evm_mine
│   ├── setAutomine/
│   │   └── anvil_setAutomine.zig   ← NEW: evm_setAutomine
│   └── setIntervalMining/
│       └── anvil_setIntervalMining.zig  ← NEW: evm_setIntervalMining
└── hardhat/
    ├── methods.zig       ← NEW: HardhatMethod union (1 method)
    └── mine/
        └── hardhat_mine.zig        ← NEW: hardhat_mine
```

Total: **7 new files**, **2 modified files**.

---

## Risks and Mitigations

### Risk 1: `evm_mine` result type — string vs Quantity
**Problem:** EDR returns `"0"` (decimal string), Foundry returns `"0x0"` (hex). The return type is documented as `[]const u8` (raw string), not `types.Quantity`.
**Mitigation:** Use `[]const u8` as the result value field. The handler in zevm will decide what string to return. The type just needs to round-trip whatever string it gets.

### Risk 2: `evm_setIntervalMining` EDR accepts `[min, max]` range
**Problem:** EDR's `IntervalConfig` can be a single number or a two-element array. Foundry uses a single `u64`.
**Mitigation:** For this ticket, use `types.Quantity` (single value) to match Foundry's simpler interface. A follow-up ticket can add range support if needed. Document this limitation in the file.

### Risk 3: Tests rely on `std.json.innerParseFromValue` API stability
**Problem:** voltaire-zig targets Zig 0.15 which may have API changes.
**Mitigation:** All existing method files already use this pattern — if it works for `eth/`, it will work here. Verify with `zig build test` after each file.

### Risk 4: `types.Quantity` wraps `std.json.Value`
**Problem:** Comparing `types.Quantity` in tests is awkward since the inner `std.json.Value` is the source value itself.
**Mitigation:** Tests for Quantity fields check non-null presence rather than deep value equality, or use `jsonStringify` roundtrip to verify the shape. See how existing tests work via `refAllDecls`.

### Risk 5: `JsonRpc.zig` union dispatch
**Problem:** Adding `anvil` and `hardhat` to `JsonRpcMethod` union makes it a breaking change for any zevm code that exhaustively switches on it.
**Mitigation:** Search zevm for `JsonRpcMethod` switch expressions before merging. Update them to handle the new variants. Since zevm doesn't have anvil/hardhat handlers yet, the cases can initially return `error.MethodNotFound`.

---

## Verification Against Acceptance Criteria

| Acceptance Criterion | Verification |
|---------------------|--------------|
| `anvil/` directory with method definitions | `ls voltaire/.../jsonrpc/anvil/` |
| `hardhat/` directory with method definitions | `ls voltaire/.../jsonrpc/hardhat/` |
| `evm_mine` implemented | file exists, `method == "evm_mine"`, tests pass |
| `evm_setAutomine` implemented | file exists, `method == "evm_setAutomine"`, tests pass |
| `evm_setIntervalMining` implemented | file exists, `method == "evm_setIntervalMining"`, tests pass |
| `hardhat_mine` implemented | file exists, `method == "hardhat_mine"`, tests pass |
| Follow existing pattern | each file mirrors `eth/blockNumber/eth_blockNumber.zig` structure |
| Params/Results with JSON serde | `jsonStringify` + `jsonParseFromValue` on every type |
| voltaire tests pass | `cd voltaire/packages/voltaire-zig && zig build test` |

---

## How to Run Tests

```bash
cd /Users/williamcory/voltaire/packages/voltaire-zig
zig build test
```

The `root.zig` uses `std.testing.refAllDecls(@This())` which transitively pulls in all inline tests from imported modules. No extra test file configuration needed.

---

## Implementation Order Summary

1. Write all inline tests in each new `.zig` file (red phase)
2. Implement method files one at a time (green phase per file):
   - `anvil_mine.zig`
   - `anvil_setAutomine.zig`
   - `anvil_setIntervalMining.zig`
   - `anvil/methods.zig`
   - `hardhat_mine.zig`
   - `hardhat/methods.zig`
3. Update `root.zig` and `JsonRpc.zig` (integration)
4. Run `zig build test` — all tests green
5. Check zevm for any exhaustive `JsonRpcMethod` switches to update
