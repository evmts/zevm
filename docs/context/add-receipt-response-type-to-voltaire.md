# Research Context: Add Receipt Response Type to Voltaire

**Ticket:** add-receipt-response-type-to-voltaire  
**Category:** cat-5-block-queries  
**Date:** 2026-02-26

---

## Summary

Create a proper `ReceiptResponse` type in voltaire's JSON-RPC module to replace the placeholder `types.Quantity` currently used as the Result type for `eth_getTransactionReceipt` and `eth_getBlockReceipts`. This type must match the execution-apis specification for `ReceiptInfo`.

---

## Target Files to Modify

| File | Action |
|------|--------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types/ReceiptResponse.zig` | **CREATE** - New receipt response type |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` | **UPDATE** - Export ReceiptResponse |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionReceipt/eth_getTransactionReceipt.zig` | **UPDATE** - Change Result type to ReceiptResponse |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockReceipts/eth_getBlockReceipts.zig` | **UPDATE** - Change Result type to []ReceiptResponse |

---

## Execution-APIs Specification (Source of Truth)

### ReceiptInfo Schema

From `execution-apis/src/schemas/receipt.yaml`:

```yaml
ReceiptInfo:
  type: object
  title: Receipt information
  required:
    - blockHash
    - blockNumber
    - from
    - cumulativeGasUsed
    - gasUsed
    - logs
    - logsBloom
    - transactionHash
    - transactionIndex
    - effectiveGasPrice
  additionalProperties: false
  properties:
    type:                      # Transaction type (0x0, 0x1, 0x2, 0x3, 0x4)
      $ref: '#/components/schemas/byte'
    transactionHash:           # 32 bytes
      $ref: '#/components/schemas/hash32'
    transactionIndex:          # Position in block
      $ref: '#/components/schemas/uint'
    blockHash:                 # 32 bytes
      $ref: '#/components/schemas/hash32'
    blockNumber:               # Block number
      $ref: '#/components/schemas/uint'
    from:                      # Sender address (20 bytes)
      $ref: '#/components/schemas/address'
    to:                        # Recipient or null for contract creation
      oneOf:
        - title: Contract Creation (null)
          type: 'null'
        - $ref: '#/components/schemas/address'
    cumulativeGasUsed:         # Sum of gas used by this tx + all preceding in block
      $ref: '#/components/schemas/uint'
    gasUsed:                   # Gas used by this specific transaction
      $ref: '#/components/schemas/uint'
    blobGasUsed:               # EIP-4844 blob gas used (only for blob txs)
      $ref: '#/components/schemas/uint'
    contractAddress:           # Created contract address or null
      oneOf:
        - $ref: '#/components/schemas/address'
        - title: 'Null'
          type: 'null'
    logs:                      # Array of log entries
      type: array
      items:
        $ref: '#/components/schemas/Log'
    logsBloom:                 # 256-byte bloom filter
      $ref: '#/components/schemas/bytes256'
    root:                      # Pre-Byzantium state root (EIP-658)
      $ref: '#/components/schemas/hash32'
    status:                    # Post-Byzantium: 1 (success) or 0 (failure)
      $ref: '#/components/schemas/uint'
    effectiveGasPrice:         # Actual gas price paid
      $ref: '#/components/schemas/uint'
    blobGasPrice:              # EIP-4844 blob gas price (only for blob txs)
      $ref: '#/components/schemas/uint'
```

### Log Schema (Nested in ReceiptInfo)

From `execution-apis/src/schemas/receipt.yaml`:

```yaml
Log:
  title: log
  type: object
  required:
    - transactionHash
  additionalProperties: false
  properties:
    removed:                   # True if log was removed (reorg)
      type: boolean
    logIndex:                  # Position of log in block
      $ref: '#/components/schemas/uint'
    transactionIndex:          # Position of tx in block
      $ref: '#/components/schemas/uint'
    transactionHash:           # 32 bytes
      $ref: '#/components/schemas/hash32'
    blockHash:                 # 32 bytes
      $ref: '#/components/schemas/hash32'
    blockNumber:               # Block number
      $ref: '#/components/schemas/uint'
    blockTimestamp:            # Unix timestamp
      $ref: '#/components/schemas/uint'
    address:                   # Contract address that emitted log
      $ref: '#/components/schemas/address'
    data:                      # Log data (bytes)
      $ref: '#/components/schemas/bytes'
    topics:                    # Array of 32-byte topic hashes
      type: array
      items:
        $ref: '#/components/schemas/bytes32'
```

---

## Method Signatures

### eth_getTransactionReceipt

From `execution-apis/src/eth/transaction.yaml`:

```yaml
- name: eth_getTransactionReceipt
  summary: Returns the receipt of a transaction by transaction hash.
  params:
    - name: Transaction hash
      required: true
      schema:
        $ref: '#/components/schemas/hash32'
  result:
    name: Receipt information
    schema:
      oneOf:
        - $ref: '#/components/schemas/notFound'   # null if not found
        - $ref: '#/components/schemas/ReceiptInfo'
```

### eth_getBlockReceipts

From `execution-apis/src/eth/block.yaml`:

```yaml
- name: eth_getBlockReceipts
  summary: Returns the receipts of a block by number or hash.
  params:
    - name: Block
      required: true
      schema:
        $ref: '#/components/schemas/BlockNumberOrTagOrHash'
  result:
    name: Receipts information
    schema:
      oneOf:
        - $ref: '#/components/schemas/notFound'
        - title: Receipts information
          type: array
          items:
            $ref: '#/components/schemas/ReceiptInfo'
```

---

## Reference Implementations

### EDR (Rust) - L1RpcTransactionReceipt

From `edr/crates/edr_chain_l1/src/rpc/receipt.rs`:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct L1RpcTransactionReceipt {
    pub block_hash: B256,
    pub block_number: u64,
    pub transaction_hash: B256,
    pub transaction_index: u64,
    pub transaction_type: Option<u8>,  // Only for Berlin+
    pub from: Address,
    pub to: Option<Address>,
    pub cumulative_gas_used: u64,
    pub gas_used: u64,
    pub contract_address: Option<Address>,
    pub logs: Vec<FilterLog>,
    pub logs_bloom: Bloom,
    pub state_root: Option<B256>,      // Pre-Byzantium only
    pub status: Option<bool>,          // Post-Byzantium only
    pub effective_gas_price: Option<u128>,
    pub authorization_list: Option<Vec<SignedAuthorization>>, // EIP-7702
}
```

Key observations:
- `state_root` and `status` are mutually exclusive (EIP-658)
- `transaction_type` is `None` for pre-Berlin blocks
- `effective_gas_price` is optional
- EIP-4844 adds `blob_gas_used` and `blob_gas_price` fields

### EIP-658: Status Code in Receipts

From `EIPs/EIPS/eip-658.md`:

> For blocks where block.number >= BYZANTIUM_FORK_BLKNUM, the intermediate state root is replaced by a status code, 0 indicating failure (due to any operation that can cause the transaction or top-level call to revert) and 1 indicating success.

**Important:**
- **Pre-Byzantium:** Receipts have `root` (state root) field
- **Post-Byzantium:** Receipts have `status` field (0 = failure, 1 = success)
- These two fields are mutually exclusive

---

## Test Examples from execution-apis

### Legacy Transaction Receipt (Pre-Byzantium)

From `execution-apis/tests/eth_getTransactionReceipt/get-legacy-receipt.io`:

```json
{
  "blockHash": "0x558340736256a3a431f7340546850dfd1451171a5c990308f86c47e4f41aed1a",
  "blockNumber": "0x2",
  "contractAddress": null,
  "cumulativeGasUsed": "0x3d037",
  "effectiveGasPrice": "0x1",
  "from": "0x7435ed30a8b4aeb0877cef0c6e8cffe834eb865f",
  "gasUsed": "0x5208",
  "logs": [],
  "logsBloom": "0x0000...",
  "root": "0x7e099d847594c44aed09000b17536bab7dbc64be4572474bae7b4dd04ce8c2df",
  "to": "0xeda8645ba6948855e3b3cd596bbb07596d59c603",
  "transactionHash": "0x0d6999c0e9e4bec347945593e97bdcdf7c25be08ca1a1efdc520dbe75be985f3",
  "transactionIndex": "0x3",
  "type": "0x0"
}
```

Note: Has `root` field (pre-Byzantium), no `status`.

### EIP-1559 Dynamic Fee Transaction

From `execution-apis/tests/eth_getTransactionReceipt/get-dynamic-fee.io`:

```json
{
  "blockHash": "0x155ed001f7571cb6fa37e5c9c2462b4704ce9cdf53fddc39e9d9f96f92a5233c",
  "blockNumber": "0x1b",
  "contractAddress": null,
  "cumulativeGasUsed": "0xca9c",
  "effectiveGasPrice": "0x3b9aca01",
  "from": "0x7435ed30a8b4aeb0877cef0c6e8cffe834eb865f",
  "gasUsed": "0xca9c",
  "logs": [
    {
      "address": "0x7dcd17433742f4c0ca53122ab541d0ba67fc27df",
      "topics": ["0x...", "0x..."],
      "data": "0x...",
      "blockNumber": "0x1b",
      "transactionHash": "0xc7dba25cdd5aee6ff7d27fe5422a4179f5913c664c3339c8e0440bd1c9cd8de9",
      "transactionIndex": "0x0",
      "blockHash": "0x155ed001f7571cb6fa37e5c9c2462b4704ce9cdf53fddc39e9d9f96f92a5233c",
      "blockTimestamp": "0x10e",
      "logIndex": "0x0",
      "removed": false
    }
  ],
  "logsBloom": "0x0000...",
  "status": "0x1",
  "to": "0x7dcd17433742f4c0ca53122ab541d0ba67fc27df",
  "transactionHash": "0xc7dba25cdd5aee6ff7d27fe5422a4179f5913c664c3339c8e0440bd1c9cd8de9",
  "transactionIndex": "0x0",
  "type": "0x2"
}
```

Note: Has `status` field (post-Byzantium), no `root`.

### EIP-4844 Blob Transaction

From `execution-apis/tests/eth_getTransactionReceipt/get-blob-tx.io`:

```json
{
  "blobGasPrice": "0x1",
  "blobGasUsed": "0x20000",
  "blockHash": "0x60d8d4c8d64367b4436e63f43addb9e3bd99a5a4176b84429fc4f22e27a7ee63",
  "blockNumber": "0x2a",
  "contractAddress": null,
  "cumulativeGasUsed": "0xca9c",
  "effectiveGasPrice": "0x822595c",
  "from": "0x7435ed30a8b4aeb0877cef0c6e8cffe834eb865f",
  "gasUsed": "0xca9c",
  "logs": [...],
  "logsBloom": "0x0000...",
  "status": "0x1",
  "to": "0x7dcd17433742f4c0ca53122ab541d0ba67fc27df",
  "transactionHash": "0x6bcea0da8e703d3283c8f1124377a63023290cd188de3274d12441e15dc14794",
  "transactionIndex": "0x0",
  "type": "0x3"
}
```

Note: Includes `blobGasPrice` and `blobGasUsed` fields.

---

## Voltaire Existing Type Patterns

### Hash Type (Reference Pattern)

From `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Hash.zig`:

```zig
const std = @import("std");

pub const Hash = struct {
    bytes: [32]u8,

    pub fn jsonStringify(self: Hash, jws: *std.json.Stringify) !void {
        var buf: [66]u8 = undefined;
        buf[0] = '0';
        buf[1] = 'x';
        const hex = std.fmt.bytesToHex(&self.bytes, .lower);
        @memcpy(buf[2..], &hex);
        try jws.print("\"{s}\"", .{buf});
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Hash {
        switch (source) {
            .string => |s| {
                if (s.len != 66 or s[0] != '0' or (s[1] != 'x' and s[1] != 'X'))
                    return error.InvalidHash;
                var out: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&out, s[2..]) catch return error.InvalidHash;
                return .{ .bytes = out };
            },
            else => return error.InvalidHash,
        }
    }
};
```

### Address Type (Reference Pattern)

From `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig`:

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
    // ... jsonParseFromValue
};
```

### Quantity Type

From `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig`:

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

---

## Current Implementation (To Be Replaced)

### eth_getTransactionReceipt.zig

```zig
/// Result for `eth_getTransactionReceipt`
pub const Result = struct {
    value: types.Quantity,  // <-- PLACEHOLDER

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

### eth_getBlockReceipts.zig

```zig
/// Result for `eth_getBlockReceipts`
pub const Result = struct {
    value: types.Quantity,  // <-- PLACEHOLDER (should be []ReceiptResponse)

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }
    // ...
};
```

---

## Proposed ReceiptResponse Structure

Based on patterns from existing voltaire types and the execution-apis spec:

```zig
// types/ReceiptResponse.zig
const std = @import("std");

/// Log entry within a transaction receipt
pub const Log = struct {
    removed: bool = false,
    logIndex: ?u64 = null,
    transactionIndex: ?u64 = null,
    transactionHash: types.Hash,
    blockHash: ?types.Hash = null,
    blockNumber: ?u64 = null,
    blockTimestamp: ?u64 = null,
    address: ?types.Address = null,
    data: ?[]const u8 = null,  // May need allocator handling
    topics: ?[]const types.Hash = null,
    
    // jsonStringify/jsonParseFromValue implementations...
};

/// Transaction receipt response per execution-apis ReceiptInfo schema
pub const ReceiptResponse = struct {
    // Required fields
    transactionHash: types.Hash,
    transactionIndex: u64,
    blockHash: types.Hash,
    blockNumber: u64,
    from: types.Address,
    cumulativeGasUsed: u64,
    gasUsed: u64,
    logs: []Log,  // Will need allocator for deserialization
    logsBloom: [256]u8,  // bytes256
    effectiveGasPrice: u64,
    
    // Optional/nullable fields
    /// Transaction type: 0x0 (legacy), 0x1 (EIP-2930), 0x2 (EIP-1559), 0x3 (EIP-4844), 0x4 (EIP-7702)
    type: ?u8 = null,
    
    /// Recipient address, null for contract creation
    to: ?types.Address = null,
    
    /// Contract address created, null if not a deployment
    contractAddress: ?types.Address = null,
    
    /// EIP-4844: Blob gas used (only for blob transactions)
    blobGasUsed: ?u64 = null,
    
    /// EIP-4844: Blob gas price (only for blob transactions)
    blobGasPrice: ?u64 = null,
    
    /// Pre-Byzantium: State root (EIP-658)
    /// Mutually exclusive with `status`
    root: ?types.Hash = null,
    
    /// Post-Byzantium: 1 = success, 0 = failure (EIP-658)
    /// Mutually exclusive with `root`
    status: ?u8 = null,
    
    // jsonStringify implementation...
    // jsonParseFromValue implementation...
};
```

---

## Key Design Decisions

1. **Nullable vs Optional Fields**: Use optional types (`?T`) for fields that may be null or omitted
2. **Logs Array**: Will require allocator for deserialization since it's a variable-length array
3. **root vs status**: These are mutually exclusive per EIP-658
   - Pre-Byzantium: `root` is present, `status` is null
   - Post-Byzantium: `status` is present (0 or 1), `root` is null
4. **EIP-4844 Fields**: `blobGasUsed` and `blobGasPrice` only present for blob transactions
5. **EIP-7702**: Consider `authorizationList` field if supporting set-code transactions

---

## Files to Reference for Implementation Patterns

| File | Purpose |
|------|---------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Hash.zig` | Hex string serialization pattern |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig` | Address serialization pattern |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig` | Optional numeric handling |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockSpec.zig` | Nullable JSON value pattern |
| `edr/crates/edr_chain_l1/src/rpc/receipt.rs` | Full receipt implementation reference |
| `foundry/crates/primitives/src/network/receipt.rs` | Foundry receipt patterns |

---

## EIPs to Consider

| EIP | Description | Impact on ReceiptResponse |
|-----|-------------|---------------------------|
| [EIP-658](EIPs/EIPS/eip-658.md) | Status code in receipts | `status` field (post-Byzantium), replaces `root` |
| [EIP-4844](EIPs/EIPS/eip-4844.md) | Shard blob transactions | Adds `blobGasUsed`, `blobGasPrice` fields |
| [EIP-7702](EIPs/EIPS/eip-7702.md) | Set EOA account code | Adds `authorizationList` field |
| [EIP-1559](EIPs/EIPS/eip-1559.md) | Fee market change | Affects `effectiveGasPrice` calculation |
| [EIP-2718](EIPs/EIPS/eip-2718.md) | Typed transaction envelope | Affects `type` field values |
