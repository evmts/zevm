# TDD Plan: cat2-eth-accounts-type-fix — Fix eth_accounts Result Type in voltaire

## Overview

The `eth_accounts` JSON-RPC method in voltaire has its `Result.value` typed as `types.Quantity` (a hex-encoded integer wrapper). Per the Ethereum execution-APIs specification (`execution-apis/src/eth/client.yaml`), this is incorrect — `eth_accounts` must return a JSON array of 20-byte hex-encoded addresses.

This is a single-file fix in the upstream voltaire dependency we own.

**Target File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig`

---

## Current State (Bug)

```zig
pub const Result = struct {
    /// Accounts
    value: types.Quantity,  // ← WRONG: Quantity is for hex integers, not address arrays

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);  // Writes a single value, not an array
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return Result{
            .value = try std.json.innerParseFromValue(types.Quantity, allocator, source, options),
        };
    }
};
```

**Problem**: 
- `types.Quantity` wraps a `std.json.Value` for hex-encoded unsigned integers
- `eth_accounts` must return `[]const types.Address` — an array of addresses per spec

---

## Spec Reference

### execution-apis/src/eth/client.yaml (lines 43-68)

```yaml
- name: eth_accounts
  summary: Returns a list of addresses owned by client.
  params: []
  result:
    name: Accounts
    schema:
      title: Accounts
      type: array
      items:
        $ref: '#/components/schemas/address'
  examples:
    - name: eth_accounts example
      params: []
      result:
        name: Accounts
        value:
          - '0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0'
```

**Schema Requirements**:
- `type: array` — JSON array
- `items: $ref: '#/components/schemas/address'` — each item is a 20-byte hex address
- Example output: `["0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0"]`

### EIP-1474 Definition

```
eth_accounts

Returns a list of addresses owned by client.

Parameters: none

Returns: <Array> - Array of DATA, 20 Bytes - addresses owned by the client
```

---

## TDD Step Order (Tests FIRST)

### Step 1: Write Failing Tests

Add a test block at the bottom of `eth_accounts.zig` with four test cases:

**Test 1: `Result jsonStringify writes JSON array of addresses`**
```zig
test "Result jsonStringify writes JSON array of addresses" {
    const allocator = std.testing.allocator;
    
    // Create two test addresses
    const addr1 = types.Address{ .bytes = [20]u8{0xd1, 0xf5, 0x27, 0x9b, 0xe4, 0xb4, 0xdd, 0x94, 0x13, 0x3a, 0x23, 0xde, 0xe1, 0xb2, 0x3f, 0x5b, 0xfc, 0x0d, 0xb1, 0xd0} };
    const addr2 = types.Address{ .bytes = [20]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01} };
    
    const addresses = [_]types.Address{ addr1, addr2 };
    const result = Result{ .value = &addresses };
    
    const json = try std.json.stringifyAlloc(allocator, result, .{});
    defer allocator.free(json);
    
    // Expected: ["0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0","0x0000000000000000000000000000000000000001"]
    try std.testing.expectEqualStrings(
        "[\"0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0\",\"0x0000000000000000000000000000000000000001\"]",
        json
    );
}
```

**Test 2: `Result jsonStringify writes empty array`**
```zig
test "Result jsonStringify writes empty array" {
    const allocator = std.testing.allocator;
    
    const result = Result{ .value = &.{} };
    
    const json = try std.json.stringifyAlloc(allocator, result, .{});
    defer allocator.free(json);
    
    try std.testing.expectEqualStrings("[]", json);
}
```

**Test 3: `Result jsonParseFromValue round-trips`**
```zig
test "Result jsonParseFromValue round-trips" {
    const allocator = std.testing.allocator;
    
    // Build a JSON array of address strings
    var items = std.ArrayList(std.json.Value).init(allocator);
    defer items.deinit();
    
    try items.append(.{ .string = "0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0" });
    try items.append(.{ .string = "0x0000000000000000000000000000000000000001" });
    
    const source = std.json.Value{ .array = .{ .items = items.toOwnedSlice() catch unreachable } };
    defer allocator.free(source.array.items);
    
    const result = try Result.jsonParseFromValue(allocator, source, .{});
    defer allocator.free(result.value);
    
    try std.testing.expectEqual(@as(usize, 2), result.value.len);
    try std.testing.expectEqual([20]u8{0xd1, 0xf5, 0x27, 0x9b, 0xe4, 0xb4, 0xdd, 0x94, 0x13, 0x3a, 0x23, 0xde, 0xe1, 0xb2, 0x3f, 0x5b, 0xfc, 0x0d, 0xb1, 0xd0}, result.value[0].bytes);
    try std.testing.expectEqual([20]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01}, result.value[1].bytes);
}
```

**Test 4: `Result jsonParseFromValue rejects non-array`**
```zig
test "Result jsonParseFromValue rejects non-array" {
    const allocator = std.testing.allocator;
    
    const source = std.json.Value{ .string = "0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0" };
    
    const result = Result.jsonParseFromValue(allocator, source, .{});
    try std.testing.expectError(error.UnexpectedToken, result);
}
```

**Expected**: These tests will fail because `Result.value` is still `types.Quantity`.

**Run tests to confirm failure**:
```bash
cd ../voltaire && zig build test 2>&1 | grep -A5 "eth_accounts"
```

---

### Step 2: Change Result.value Type

**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig`

**Line 33**: Change the type definition:

```zig
// FROM:
value: types.Quantity,

// TO:
value: []const types.Address,
```

---

### Step 3: Update jsonStringify

**Lines 35-37**: Replace the body to emit a JSON array:

```zig
pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
    try jws.beginArray();
    for (self.value) |addr| {
        try jws.write(addr);
    }
    try jws.endArray();
}
```

**Pattern justification**: This `beginArray`/`write`/`endArray` pattern is used extensively throughout voltaire for Params serialization (confirmed in 50+ files including `eth_getFilterLogs.zig`, `eth_getLogs.zig`, `debug_getRawBlock.zig`).

---

### Step 4: Update jsonParseFromValue

**Lines 39-43**: Replace the body to parse a JSON array:

```zig
pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
    if (source != .array) return error.UnexpectedToken;
    const items = source.array.items;
    const addrs = try allocator.alloc(types.Address, items.len);
    for (items, 0..) |item, i| {
        addrs[i] = try std.json.innerParseFromValue(types.Address, allocator, item, options);
    }
    return Result{ .value = addrs };
}
```

**Notes**:
- Returns `error.UnexpectedToken` for non-array sources (standard Zig JSON convention)
- Allocates the slice with the passed allocator — **caller must free** via `allocator.free(result.value)`
- Uses `[]const types.Address` to match Zig conventions for read-only data

---

### Step 5: Run Tests and Verify

```bash
cd ../voltaire && zig build test
```

**Expected**: All four tests from Step 1 should pass. Also verify no existing voltaire tests break.

---

### Step 6: Verify zevm Integration

```bash
cd ../zevm && zig build test
```

**Expected**: zevm builds cleanly and all existing tests pass. No downstream breakage is expected because:
- No zevm `.zig` files directly reference `eth_accounts.Result`
- The `methods.zig` union uses `eth_accounts.Result` structurally — type changes are transparent

---

## Files to Create/Modify

| File | Action | Details |
|------|--------|---------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig` | Modify | Change `Result.value` type, update `jsonStringify`, update `jsonParseFromValue`, add test block |

No new files needed. No changes to `methods.zig` or any other file (the union references `eth_accounts.Result` structurally).

---

## Final Function Signatures

```zig
/// Result for `eth_accounts`
pub const Result = struct {
    /// Accounts (array of 20-byte addresses)
    value: []const types.Address,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.beginArray();
        for (self.value) |addr| {
            try jws.write(addr);
        }
        try jws.endArray();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        if (source != .array) return error.UnexpectedToken;
        const items = source.array.items;
        const addrs = try allocator.alloc(types.Address, items.len);
        for (items, 0..) |item, i| {
            addrs[i] = try std.json.innerParseFromValue(types.Address, allocator, item, options);
        }
        return Result{ .value = addrs };
    }
};
```

---

## Tests

### Unit Tests (in eth_accounts.zig)

| Test Name | Purpose |
|-----------|---------|
| `Result jsonStringify writes JSON array of addresses` | Serialization of 2 addresses produces `["0xaddr1","0xaddr2"]` |
| `Result jsonStringify writes empty array` | Empty slice produces `[]` |
| `Result jsonParseFromValue round-trips` | Parsing a JSON array returns correct `[]types.Address` |
| `Result jsonParseFromValue rejects non-array` | Non-array JSON returns `error.UnexpectedToken` |

### Integration Tests

No additional integration tests required. The `methods.zig` union uses `eth_accounts.Result` structurally, so it automatically picks up the corrected type. Once zevm implements the `eth_accounts` handler, e2e tests for that handler will exercise this type end-to-end.

---

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `std.json.Stringify.beginArray`/`endArray` API mismatch | Low | Already used extensively in voltaire Params serialization (50+ files) |
| `types.Address.jsonStringify` doesn't work inside `jws.write()` | Low | `eth_coinbase` already uses `jws.write(self.value)` with a single `types.Address` — same pattern, just in a loop |
| Breaking downstream zevm consumers | None | No zevm `.zig` file references `eth_accounts.Result` yet |
| Breaking `methods.zig` union | None | The union field `result: eth_accounts.Result` is structural — inner type changes are transparent |
| Memory leak from allocated slice | Low | Document that callers must free `result.value` via the allocator (standard Zig JSON parsing convention) |
| `[]const types.Address` vs `[]types.Address` | Low | Use `[]const types.Address` to match Zig slice conventions for read-only data |

---

## Verification Against Acceptance Criteria

| Criterion | How Verified |
|-----------|--------------|
| **Result holds `[]const types.Address`** | Step 2 changes the type |
| **`jsonStringify` writes JSON array** | Step 3 implements array serialization |
| **`jsonParseFromValue` parses JSON array of addresses** | Step 4 implements array parsing |
| **Spec compliance** | Output matches `execution-apis/src/eth/client.yaml` example: `["0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0"]` |
| **Tests pass** | Steps 1 and 5 verify all 4 tests pass |
| **No downstream breakage** | Step 6 confirms zevm builds cleanly |

---

## Reference Implementations

### Foundry Anvil (foundry/crates/anvil/src/eth/api.rs)

```rust
pub fn accounts(&self) -> Result<Vec<Address>, Self::Error> {
    let mut unique = HashSet::new();
    let mut accounts: Vec<Address> = Vec::new();
    for signer in self.signers.iter() {
        accounts.extend(signer.accounts().into_iter().filter(|acc| unique.insert(*acc)));
    }
    // Returns Vec<Address> — serialized as JSON array of hex strings
}
```

### EDR / Hardhat (edr/crates/edr_provider/src/requests/methods.rs)

```rust
/// Returns a list of addresses owned by the provider.
/// `Array<DATA, 20 bytes>` - List of addresses owned by the provider.
#[serde(rename = "eth_accounts", with = "edr_eth::serde::empty_params")]
Accounts(()),
```

---

## Related Files

- `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` — exports Address, Quantity
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig` — 20-byte address type with JSON serde
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig` — hex integer type (incorrectly used)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` — method union (uses Result structurally)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/coinbase/eth_coinbase.zig` — single Address result pattern
- `execution-apis/src/eth/client.yaml` — spec definition
- `execution-apis/src/schemas/base-types.yaml` — address schema definition
