# Context: cat2-eth-accounts-type-fix — Fix eth_accounts Result.value type in voltaire

## Ticket Info
- **Ticket ID**: cat2-eth-accounts-type-fix
- **Category**: cat-2-eth-read
- **Goal**: Change `eth_accounts.Result.value` from `types.Quantity` to `[]const types.Address` per execution-apis spec.

---

## Summary

The `eth_accounts` JSON-RPC method in voltaire has its `Result.value` typed as `types.Quantity` (a hex-encoded integer wrapper). Per the Ethereum execution-APIs specification, this is incorrect — `eth_accounts` must return a JSON array of 20-byte hex-encoded addresses.

This is a single-file fix in the upstream voltaire dependency.

---

## The Bug

**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig`

Current (wrong — line 33):
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
- `eth_accounts` must return `[]const types.Address` — an array of addresses

---

## Spec Evidence

### execution-apis/src/eth/client.yaml (lines 43-59)

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

The result schema is unambiguous:
- `type: array` — JSON array
- `items: $ref: '#/components/schemas/address'` — each item is a 20-byte hex address
- Example: `["0xd1f5279be4b4dd94133a23dee1b23f5bfc0db1d0"]`

### execution-apis/src/schemas/base-types.yaml

```yaml
address:
  title: hex encoded address
  type: string
  pattern: ^0x[0-9a-fA-F]{40}$

addresses:
  title: hex encoded address
  type: array
  items:
    $ref: '#/components/schemas/address'
```

---

## Relevant Types in voltaire

### types.Address — ../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig

```zig
pub const Address = struct {
    bytes: [20]u8,

    pub fn jsonStringify(self: Address, jws: *std.json.Stringify) !void {
        var buf: [42]u8 = undefined;
        buf[0] = '0';
        buf[1] = 'x';
        const hex = std.fmt.bytesToHex(&self.bytes, .lower);
        @memcpy(buf[2..], &hex);
        try jws.print("\"{s}\"", .{buf});
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Address {
        _ = allocator;
        switch (source) {
            .string => |s| {
                var slice = s;
                if (slice.len != 42 or slice[0] != '0' or (slice[1] != 'x' and slice[1] != 'X'))
                    return error.InvalidAddress;
                var out: [20]u8 = undefined;
                _ = std.fmt.hexToBytes(&out, slice[2..]) catch return error.InvalidAddress;
                return .{ .bytes = out };
            },
            else => return error.InvalidAddress,
        }
    }
};
```

### types.Quantity — ../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig

```zig
pub const Quantity = struct {
    value: std.json.Value,

    pub fn jsonStringify(self: Quantity, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Quantity {
        return .{ .value = source };
    }
};
```

Quantity is a thin wrapper for JSON values representing hex-encoded unsigned integers (per EIP-1474). It is NOT appropriate for address arrays.

---

## Pattern: Single Address Result (correct reference)

### eth_coinbase — ../voltaire/packages/voltaire-zig/src/jsonrpc/eth/coinbase/eth_coinbase.zig

```zig
pub const Result = struct {
    /// hex encoded address
    value: types.Address,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        return Result{
            .value = try std.json.innerParseFromValue(types.Address, allocator, source, options),
        };
    }
};
```

`eth_accounts` follows the same pattern as `eth_coinbase`, but returns an **array** of addresses instead of a single address.

---

## Pattern: Array Serialization in voltaire

The `beginArray()`/`write()`/`endArray()` pattern is used extensively throughout voltaire for Params serialization:

Examples from grep results:
- `eth/getFilterLogs/eth_getFilterLogs.zig:22-24`
- `eth/getLogs/eth_getLogs.zig:22-24`
- `debug/getRawBlock/debug_getRawBlock.zig:22-24`
- `engine/getPayloadV3/engine_getPayloadV3.zig:22-24`

Standard pattern:
```zig
try jws.beginArray();
for (items) |item| {
    try jws.write(item);
}
try jws.endArray();
```

---

## Required Changes

**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig`

### 1. Change Result.value type (line 33)

FROM:
```zig
value: types.Quantity,
```

TO:
```zig
value: []const types.Address,
```

### 2. Update jsonStringify

FROM:
```zig
pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
    try jws.write(self.value);
}
```

TO:
```zig
pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
    try jws.beginArray();
    for (self.value) |addr| {
        try jws.write(addr);
    }
    try jws.endArray();
}
```

### 3. Update jsonParseFromValue

FROM:
```zig
pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
    return Result{
        .value = try std.json.innerParseFromValue(types.Quantity, allocator, source, options),
    };
}
```

TO:
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

### 4. Add test block

Add tests at the bottom of the file:
```zig
test "Result jsonStringify writes JSON array of addresses" {
    // Test with 2 addresses
}

test "Result jsonStringify writes empty array" {
    // Test with empty slice
}

test "Result jsonParseFromValue round-trips" {
    // Parse JSON array, verify addresses
}

test "Result jsonParseFromValue rejects non-array" {
    // Pass .string source, expect error.UnexpectedToken
}
```

---

## Reference Implementations

### Foundry Anvil (foundry/crates/anvil/src/eth/api.rs)

```rust
/// Handler for ETH RPC call: `eth_accounts`
pub fn accounts(&self) -> Result<Vec<Address>, Self::Error> {
    node_info!("eth_accounts");
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
/// # `eth_accounts`
/// 
/// Returns a list of addresses owned by the provider.
/// 
/// ## Arguments
/// 
/// None
/// 
/// ## Returns
/// 
/// `Array<DATA, 20 bytes>` - List of addresses owned by the provider.
/// 
/// ## Example
/// 
/// ```json
/// # Request
/// {
///     "id": 1,
///     "jsonrpc": "2.0",
///     "method": "eth_accounts",
///     "params": []
/// }
/// 
/// # Response
/// {
///     "id": 1,
///     "jsonrpc": "2.0",
///     "result": ["0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000001"]
/// }
/// ```
#[serde(rename = "eth_accounts", with = "edr_eth::serde::empty_params")]
Accounts(()),
```

### EIP-1474 (eth_accounts definition)

From https://eips.ethereum.org/EIPS/eip-1474:
```
#### eth_accounts

Returns a list of addresses owned by client.

##### Parameters

none

##### Returns

`<Array>` - Array of DATA, 20 Bytes - addresses owned by the client
```

---

## Impact Analysis

### Downstream in zevm
- No `.zig` files in zevm directly reference `eth_accounts.Result`
- The `methods.zig` union uses `eth_accounts.Result` structurally — type changes are transparent
- This is a safe fix with no expected downstream breakage

### Upstream in voltaire
- Single file change only
- The `methods.zig` union will automatically pick up the corrected type
- No changes needed to `JsonRpc.zig` or other infrastructure

---

## Files to Modify

| File | Action | Details |
|------|--------|---------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig` | Modify | Change `Result.value` type, update `jsonStringify`, update `jsonParseFromValue`, add tests |

---

## Zig Style Notes

- **No local type aliases**: Do NOT create `const Address = types.Address`. Use `types.Address` inline.
- **No stored allocators**: The allocator is passed to `jsonParseFromValue` only.
- **Use `[]const types.Address`**: The const slice convention matches read-only data returned from parsing.
- **Caller frees**: The slice is heap-allocated; callers must free `result.value` via the allocator.

---

## Related Files

- `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` — exports Address, Quantity
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig` — 20-byte address type
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig` — hex integer type
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` — method union (uses Result structurally)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/coinbase/eth_coinbase.zig` — single Address result pattern
- `execution-apis/src/eth/client.yaml` — spec definition
- `execution-apis/src/schemas/base-types.yaml` — address schema definition
- `docs/plans/cat2-001.md` — detailed implementation plan
