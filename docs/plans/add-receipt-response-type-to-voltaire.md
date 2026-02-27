# Implementation Plan: Add Receipt Response Type to Voltaire

## Overview
This plan details the steps required to implement the `ReceiptResponse` type in the voltaire JSON-RPC module, replacing the placeholder `types.Quantity` in `eth_getTransactionReceipt` and `eth_getBlockReceipts` results. The implementation strictly follows the execution-apis specification and adheres to a Test-Driven Development (TDD) methodology.

## TDD Step Order

We will follow strict TDD: Tests MUST be written before the corresponding implementation.

1. **Test `ReceiptResponse` Parsing & Serialization (Legacy)**
   - Write tests for a pre-Byzantium legacy transaction receipt with the `root` field (and no `status`).
2. **Implement `ReceiptResponse` Structure & Parsing (Legacy)**
   - Create `ReceiptResponse.zig` and implement the basic struct fields.
   - Implement `jsonStringify` and `jsonParseFromValue` capable of passing the legacy test.
3. **Test `ReceiptResponse` (Post-Byzantium / Dynamic Fee)**
   - Write tests for a post-Byzantium EIP-1559 receipt featuring a `status` field instead of `root`, and containing `logs`.
4. **Implement `ReceiptResponse` Updates (Post-Byzantium / Dynamic Fee)**
   - Update `ReceiptResponse` and implement `Log` struct logic to pass the new test.
5. **Test `ReceiptResponse` (EIP-4844 Blob Tx)**
   - Write tests for a blob transaction receipt with `blobGasUsed` and `blobGasPrice`.
6. **Implement `ReceiptResponse` Updates (EIP-4844 Blob Tx)**
   - Add nullable blob fields and handle them in serialization/deserialization to pass the blob test.
7. **Test Type Export**
   - Write a quick compilation test importing `ReceiptResponse` via `types.zig`.
8. **Implement Type Export**
   - Update `types.zig` to export `ReceiptResponse`.
9. **Test `eth_getTransactionReceipt` Schema Match**
   - Update `eth_getTransactionReceipt` test to assert the response maps correctly to `ReceiptResponse`.
10. **Implement `eth_getTransactionReceipt` Updates**
    - Change `Result` value type from `types.Quantity` to `ReceiptResponse` (or `?ReceiptResponse`).
11. **Test `eth_getBlockReceipts` Schema Match**
    - Update `eth_getBlockReceipts` tests to assert the response maps correctly to `[]ReceiptResponse`.
12. **Implement `eth_getBlockReceipts` Updates**
    - Change `Result` value type from `types.Quantity` to `[]ReceiptResponse` (or `?[]ReceiptResponse`).

## Files to Create/Modify

### 1. `../voltaire/packages/voltaire-zig/src/jsonrpc/types/ReceiptResponse.zig` (CREATE)
**Functions to Implement:**
- `pub fn jsonStringify(self: ReceiptResponse, jws: *std.json.Stringify) !void`
- `pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !ReceiptResponse`
- *Nested `Log` struct:*
  - `pub fn jsonStringify(self: Log, jws: *std.json.Stringify) !void`
  - `pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Log`

### 2. `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` (UPDATE)
**Changes:**
- Add `pub const ReceiptResponse = @import("types/ReceiptResponse.zig");`

### 3. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionReceipt/eth_getTransactionReceipt.zig` (UPDATE)
**Changes:**
- Update `pub const Result` struct:
  - `value: ?types.ReceiptResponse` (must handle null if transaction is not found)
- Update `jsonParseFromValue` and `jsonStringify` for the `Result` type.

### 4. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockReceipts/eth_getBlockReceipts.zig` (UPDATE)
**Changes:**
- Update `pub const Result` struct:
  - `value: ?[]types.ReceiptResponse`
- Update `jsonParseFromValue` and `jsonStringify` for the `Result` type.

## Tests to Write

### Unit Tests (in `ReceiptResponse.zig`)
1. `test "ReceiptResponse: Legacy (Pre-Byzantium)"`: Assert deserializing a raw JSON map containing a `root` successfully creates a `ReceiptResponse`. Assert re-serializing matches the expected JSON.
2. `test "ReceiptResponse: EIP-1559 (Post-Byzantium)"`: Assert deserializing a raw JSON map containing a `status`, `logs`, and `effectiveGasPrice` successfully creates a `ReceiptResponse`.
3. `test "ReceiptResponse: EIP-4844 Blob Tx"`: Assert deserializing JSON with `blobGasUsed` and `blobGasPrice` successfully creates a `ReceiptResponse`.
4. `test "ReceiptResponse: Validation Errors"`: Assert providing mutually exclusive fields (both `root` and `status`) yields an error `error.InvalidReceiptStatus`. Assert missing required fields yields an error.

### Integration Tests
- Verify the RPC layer successfully maps dummy backend output to JSON via `eth_getTransactionReceipt_test.zig` (if present) using a mocked `ReceiptResponse`.
- Verify the RPC layer maps a block of receipts via `eth_getBlockReceipts_test.zig` (if present).

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| **Memory Leaks from `logs` Arrays:** `Log` topics and data, along with `ReceiptResponse` logs, are dynamically sized. | Ensure `jsonParseFromValue` uses the provided `allocator` carefully and document that callers must use an arena allocator or explicitly free. |
| **Missing Mutually Exclusive Checks:** `status` and `root` can theoretically both be passed. | The `jsonParseFromValue` must enforce EIP-658 by throwing an error if both or neither are provided (depending on strictness vs. permissiveness). |
| **Unmapped `null` fields:** Contract creations have a `null` `to` field, and standard transactions have a `null` `contractAddress`. | Heavily lean into zig's `?T` (optional) type. Test specific cases where `to` is `null` to ensure `jsonParseFromValue` doesn't throw a parsing error. |

## Verification Against Acceptance Criteria

1. Verify `ReceiptResponse` struct contains exact fields: `transactionHash`, `transactionIndex`, `blockHash`, `blockNumber`, `from`, `to`, `cumulativeGasUsed`, `gasUsed`, `contractAddress`, `logs`, `logsBloom`, `root` (optional), `status` (optional), `effectiveGasPrice`, `type` (optional).
2. Verify `eth_getTransactionReceipt` returns `ReceiptResponse`.
3. Verify `eth_getBlockReceipts` returns `[]ReceiptResponse`.
4. Execute test suite locally (`zig build test`) to confirm tests cover EIP-658 mutually exclusivity and EIP-4844 fields.
