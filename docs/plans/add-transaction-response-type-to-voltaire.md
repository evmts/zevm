# TDD Plan: Add TransactionResponse Type to Voltaire

## Ticket Information
- **ID**: `add-transaction-response-type-to-voltaire`
- **Category**: `cat-5-block-queries`
- **Goal**: Create `TransactionResponse` type in voltaire's JSON-RPC layer that extends primitives.Transaction with block metadata (blockHash, blockNumber, transactionIndex, from), then update Result types for three RPC methods.

---

## Overview

This plan implements a `TransactionResponse` type for Ethereum JSON-RPC transaction queries. The type wraps primitives.Transaction with contextual block metadata required by the execution APIs specification.

### Key Design Decisions

1. **Location**: Add to `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` (or new file `types/TransactionResponse.zig`)
2. **Structure**: Union type representing all 5 transaction variants (legacy/2930/1559/4844/7702) with common metadata fields
3. **Nullability**: Result is `?TransactionResponse` - returns `null` when transaction not found
4. **Pending Semantics**: Block metadata fields (`blockHash`, `blockNumber`, `transactionIndex`) are optional for pending transactions
5. **Sender Recovery**: `from` field is derived from signature recovery (always present for valid signed transactions)

---

## TDD Step Order

### Phase 1: Foundation Types (TEST FIRST)

#### Step 1: Create TransactionResponse Type Test File
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionResponse.zig` (tests section)

**Tests to Write**:
```zig
// Test: TransactionResponse can represent legacy transaction
// Test: TransactionResponse can represent EIP-2930 transaction  
// Test: TransactionResponse can represent EIP-1559 transaction
// Test: TransactionResponse can represent EIP-4844 transaction
// Test: TransactionResponse can represent EIP-7702 transaction
// Test: TransactionResponse with block metadata (mined tx)
// Test: TransactionResponse without block metadata (pending tx)
// Test: TransactionResponse jsonStringify outputs correct RPC format for legacy
// Test: TransactionResponse jsonStringify outputs correct RPC format for EIP-1559
// Test: TransactionResponse jsonStringify outputs correct RPC format for EIP-4844
// Test: TransactionResponse jsonStringify outputs correct RPC format for EIP-7702
// Test: TransactionResponse jsonStringify includes accessList for typed txs
// Test: TransactionResponse jsonStringify includes blob fields for EIP-4844
// Test: TransactionResponse jsonStringify includes authorizationList for EIP-7702
```

**Acceptance**: Tests compile but fail (type doesn't exist yet).

---

#### Step 2: Implement TransactionResponse Type
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionResponse.zig`

**Implementation**:
```zig
const std = @import("std");
const primitives = @import("../../primitives/root.zig");
const types = @import("../types.zig");

/// TransactionResponse for JSON-RPC transaction queries.
/// Wraps primitives.Transaction with block context metadata.
pub const TransactionResponse = union(enum) {
    legacy: LegacyResponse,
    eip2930: Eip2930Response,
    eip1559: Eip1559Response,
    eip4844: Eip4844Response,
    eip7702: Eip7702Response,

    /// Common metadata fields present in all transaction responses
    pub const Metadata = struct {
        /// Block hash (null for pending)
        block_hash: ?types.Hash,
        /// Block number (null for pending)
        block_number: ?u64,
        /// Block timestamp (null for pending)
        block_timestamp: ?u64,
        /// Transaction index in block (null for pending)
        transaction_index: ?u64,
        /// Sender address (recovered from signature)
        from: types.Address,
        /// Transaction hash
        hash: types.Hash,
    };

    pub const LegacyResponse = struct {
        metadata: Metadata,
        nonce: u64,
        gas_price: u256,
        gas: u64,
        to: ?types.Address,
        value: u256,
        input: []const u8,
        v: u64,
        r: [32]u8,
        s: [32]u8,
        chain_id: ?u64,
    };

    pub const Eip2930Response = struct {
        metadata: Metadata,
        chain_id: u64,
        nonce: u64,
        gas_price: u256,
        gas: u64,
        to: ?types.Address,
        value: u256,
        input: []const u8,
        access_list: []const AccessListEntry,
        y_parity: u8,
        r: [32]u8,
        s: [32]u8,
    };

    pub const Eip1559Response = struct {
        metadata: Metadata,
        chain_id: u64,
        nonce: u64,
        max_priority_fee_per_gas: u256,
        max_fee_per_gas: u256,
        gas: u64,
        to: ?types.Address,
        value: u256,
        input: []const u8,
        access_list: []const AccessListEntry,
        max_fee_per_blob_gas: ?u256,
        blob_versioned_hashes: ?[]const [32]u8,
        y_parity: u8,
        r: [32]u8,
        s: [32]u8,
    };

    pub const Eip4844Response = struct {
        metadata: Metadata,
        chain_id: u64,
        nonce: u64,
        max_priority_fee_per_gas: u256,
        max_fee_per_gas: u256,
        gas: u64,
        to: types.Address,
        value: u256,
        input: []const u8,
        access_list: []const AccessListEntry,
        max_fee_per_blob_gas: u256,
        blob_versioned_hashes: []const [32]u8,
        y_parity: u8,
        r: [32]u8,
        s: [32]u8,
    };

    pub const Eip7702Response = struct {
        metadata: Metadata,
        chain_id: u64,
        nonce: u64,
        max_priority_fee_per_gas: u256,
        max_fee_per_gas: u256,
        gas: u64,
        to: ?types.Address,
        value: u256,
        input: []const u8,
        access_list: []const AccessListEntry,
        authorization_list: []const AuthorizationEntry,
        y_parity: u8,
        r: [32]u8,
        s: [32]u8,
    };

    pub const AccessListEntry = struct {
        address: types.Address,
        storage_keys: []const [32]u8,
    };

    pub const AuthorizationEntry = struct {
        chain_id: u64,
        address: types.Address,
        nonce: u64,
        y_parity: u8,
        r: [32]u8,
        s: [32]u8,
    };

    /// Serialize to JSON-RPC format per execution-apis spec
    pub fn jsonStringify(self: TransactionResponse, jws: *std.json.Stringify) !void {
        // Implementation outputs spec-compliant JSON
        // - type: "0x0" | "0x1" | "0x2" | "0x3" | "0x4"
        // - blockHash: null | "0x..."
        // - blockNumber: null | "0x..."
        // - blockTimestamp: null | "0x..."
        // - from: "0x..."
        // - hash: "0x..."
        // - transactionIndex: null | "0x..."
        // - All tx-type-specific fields
    }

    /// Create from primitive transaction + metadata
    pub fn fromPrimitive(
        allocator: std.mem.Allocator,
        tx: primitives.Transaction,
        metadata: Metadata,
    ) !TransactionResponse {
        // Implementation maps primitives.Transaction to TransactionResponse
        _ = allocator;
        _ = tx;
        _ = metadata;
        @panic("TODO: implement");
    }
};
```

**Acceptance**: Tests from Step 1 pass.

---

#### Step 3: Update types.zig Export
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig`

**Change**:
```zig
pub const TransactionResponse = @import("types/TransactionResponse.zig").TransactionResponse;
```

---

### Phase 2: Update RPC Method Result Types (TEST FIRST)

#### Step 4: Write Tests for eth_getTransactionByHash Result
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash_test.zig`

**Tests to Write**:
```zig
// Test: Result type accepts TransactionResponse
// Test: Result type accepts null (not found)
// Test: jsonStringify serializes TransactionResponse correctly
// Test: jsonStringify serializes null correctly
// Test: jsonParseFromValue parses TransactionResponse correctly
// Test: jsonParseFromValue parses null correctly
```

**Acceptance**: Tests compile but fail.

---

#### Step 5: Implement eth_getTransactionByHash Result Type
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash.zig`

**Change**:
```zig
/// Result for `eth_getTransactionByHash`
/// Returns TransactionResponse for found transactions, null for not found.
pub const Result = struct {
    value: ?types.TransactionResponse,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        if (self.value) |tx| {
            try tx.jsonStringify(jws);
        } else {
            try jws.write(null);
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result {
        if (source == .null) {
            return Result{ .value = null };
        }
        // Parse TransactionResponse from JSON
        _ = allocator;
        _ = options;
        @panic("TODO: implement parsing");
    }
};
```

---

#### Step 6: Write Tests for eth_getTransactionByBlockHashAndIndex Result
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockHashAndIndex/eth_getTransactionByBlockHashAndIndex_test.zig`

**Tests to Write**: Same pattern as Step 4.

---

#### Step 7: Implement eth_getTransactionByBlockHashAndIndex Result Type
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockHashAndIndex/eth_getTransactionByBlockHashAndIndex.zig`

**Change**: Same Result structure as Step 5.

---

#### Step 8: Write Tests for eth_getTransactionByBlockNumberAndIndex Result
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockNumberAndIndex/eth_getTransactionByBlockNumberAndIndex_test.zig`

**Tests to Write**: Same pattern as Step 4.

---

#### Step 9: Implement eth_getTransactionByBlockNumberAndIndex Result Type
**File**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockNumberAndIndex/eth_getTransactionByBlockNumberAndIndex.zig`

**Change**: Same Result structure as Step 5.

---

### Phase 3: Integration Tests

#### Step 10: Create Execution-APIs Test Vectors
**File**: New test file or inline in existing tests

**Test Vectors from execution-apis** (already present in context):
- `get-legacy-tx.io` - Legacy transaction format
- `get-access-list.io` - EIP-2930 transaction format  
- `get-dynamic-fee.io` - EIP-1559 transaction format
- `get-blob-tx.io` - EIP-4844 transaction format
- `get-setcode-tx.io` - EIP-7702 transaction format
- `get-notfound-tx.io` - Null result for missing transaction

**Tests**:
```zig
// Test: Legacy transaction serializes matching execution-apis vector
// Test: EIP-2930 transaction serializes matching execution-apis vector
// Test: EIP-1559 transaction serializes matching execution-apis vector
// Test: EIP-4844 transaction serializes matching execution-apis vector
// Test: EIP-7702 transaction serializes matching execution-apis vector
// Test: Not found returns null (matching execution-apis vector)
```

---

## Files to Create/Modify

### New Files
1. `../voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionResponse.zig` - Main type
2. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash_test.zig` - Unit tests
3. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockHashAndIndex/eth_getTransactionByBlockHashAndIndex_test.zig` - Unit tests
4. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockNumberAndIndex/eth_getTransactionByBlockNumberAndIndex_test.zig` - Unit tests

### Modified Files
1. `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` - Add export
2. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash.zig` - Update Result
3. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockHashAndIndex/eth_getTransactionByBlockHashAndIndex.zig` - Update Result
4. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByBlockNumberAndIndex/eth_getTransactionByBlockNumberAndIndex.zig` - Update Result

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Circular import between primitives and jsonrpc types | High | TransactionResponse lives in jsonrpc layer, imports primitives. Never import jsonrpc from primitives. |
| Signature recovery for `from` field is complex | Medium | Document that `from` requires sender recovery. Add helper in crypto module if needed. |
| Optional block fields vs execution-apis spec | Medium | Spec includes `blockTimestamp` - decide if we include it (reference: EDR/Anvil include it). |
| JSON serialization of large optional unions | Low | Use explicit jsonStringify implementation, not auto-derived. |
| EIP-7702 authorization list serialization | Medium | Ensure AuthorizationEntry matches execution-apis schema exactly. |

---

## Verification Against Acceptance Criteria

### Criteria Checklist

- [ ] `TransactionResponse` type exists in voltaire JSON-RPC types
- [ ] Type includes `blockHash` field (nullable)
- [ ] Type includes `blockNumber` field (nullable)
- [ ] Type includes `transactionIndex` field (nullable)
- [ ] Type includes `from` field (required)
- [ ] Type supports all 5 transaction variants
- [ ] `eth_getTransactionByHash.zig` Result uses `?TransactionResponse`
- [ ] `eth_getTransactionByBlockHashAndIndex.zig` Result uses `?TransactionResponse`
- [ ] `eth_getTransactionByBlockNumberAndIndex.zig` Result uses `?TransactionResponse`
- [ ] All types have JSON serialization tests
- [ ] Execution-apis test vectors pass

### Test Execution

Run tests with:
```bash
cd ../voltaire/packages/voltaire-zig
zig build test --filter TransactionResponse
zig build test --filter eth_getTransactionByHash
zig build test --filter eth_getTransactionByBlockHashAndIndex
zig build test --filter eth_getTransactionByBlockNumberAndIndex
```

---

## Implementation Notes

### JSON Serialization Format

Per execution-apis spec, transaction responses must include:

**Common Fields (all types)**:
- `type`: "0x0" | "0x1" | "0x2" | "0x3" | "0x4"
- `blockHash`: null or "0x..." (32 bytes)
- `blockNumber`: null or hex number
- `blockTimestamp`: null or hex number (optional per ticket, but spec includes)
- `from`: "0x..." (20 bytes)
- `hash`: "0x..." (32 bytes)
- `transactionIndex`: null or hex number

**Legacy Fields**:
- `nonce`, `gasPrice`, `gas`, `to`, `value`, `input`, `v`, `r`, `s`, `chainId`

**EIP-2930 Fields**:
- `chainId`, `nonce`, `gasPrice`, `gas`, `to`, `value`, `input`, `accessList`
- `yParity`, `v`, `r`, `s` (v optional for backwards compat)

**EIP-1559 Fields**:
- All EIP-2930 fields + `maxFeePerGas`, `maxPriorityFeePerGas`

**EIP-4844 Fields**:
- All EIP-1559 fields + `maxFeePerBlobGas`, `blobVersionedHashes`

**EIP-7702 Fields**:
- All EIP-1559 fields + `authorizationList`

### Sender Recovery

The `from` field requires ECDSA signature recovery:
- For typed transactions (1-4): use `y_parity` (0 or 1)
- For legacy: use `v` (27, 28 for pre-EIP-155; chain_id * 2 + 35/36 for EIP-155)
- Recovery involves computing tx hash, recovering public key, deriving address

---

## Future Work (Out of Scope)

These are noted but NOT part of this ticket:

1. **Actual RPC handler implementation** - This ticket is only the types
2. **Blockchain integration** - Wiring to BlockStore for tx lookup
3. **Mempool integration** - Pending transaction support
4. **ZEVM integration tests** - Full end-to-end tests in zevm repo

These will be covered in follow-up tickets for the "block-queries" and "mempool" categories.
