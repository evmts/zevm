# TDD Implementation Plan: Add Block Response Types to Voltaire

## Overview
The goal is to implement the JSON-RPC `BlockResponse` type in the `voltaire` repository, including its dependent types `Withdrawal` and `TransactionInfo`. This type must strictly match the Ethereum execution APIs specification (EIP-1474) for `eth_getBlockByNumber` and `eth_getBlockByHash` responses.

## TDD Step Order (Tests before implementation)

We will follow a strict Test-Driven Development approach, ensuring that serialization behavior is validated against the execution-apis specification before writing the implementation.

### Step 1: Implement `Withdrawal` type
- **Test First**: Create `Withdrawal_test.zig`. Write unit tests to verify JSON serialization conforms to EIP-1474 (e.g., fields `index`, `validatorIndex`, `amount` as `QUANTITY`, `address` as `DATA`).
- **Implementation**: Create `Withdrawal.zig`. Implement the struct and any custom `jsonStringify` logic required to match the spec. Export it in `types.zig`.

### Step 2: Implement `TransactionInfo` type
- **Test First**: Create `TransactionInfo_test.zig`. Write tests to ensure proper serialization of various transaction types (Legacy, EIP-2930, EIP-1559, EIP-4844) with correct field inclusion.
- **Implementation**: Create `TransactionInfo.zig`. Implement a struct or union that can represent hydrated transaction data. Export it in `types.zig`.

### Step 3: Implement `BlockResponse` type
- **Test First**: Create `BlockResponse_test.zig`. Write tests using the execution-apis test vectors (e.g., Genesis block, Cancun block). Verify that optional fields are completely omitted when null (not serialized as `"field": null`), and that the `transactions` array handles both unhydrated (hashes) and hydrated (`TransactionInfo`) representations.
- **Implementation**: Create `BlockResponse.zig`. Define all required and optional fields. Implement a custom `jsonStringify` method if necessary to omit nulls. Export it in `types.zig`.

### Step 4: Update RPC Method Signatures
- **Test First**: Update existing tests in `eth_getBlockByNumber_test.zig` and `eth_getBlockByHash_test.zig` to expect a strongly-typed `BlockResponse` structure instead of the previous placeholder.
- **Implementation**: Modify `eth_getBlockByNumber.zig` and `eth_getBlockByHash.zig` to update their `Result` type alias from `types.Quantity` to `types.BlockResponse`. Update `eth_getBlockByNumber` params to use proper `BlockNumberOrTag`.

## Files to Create and Modify

**Create:**
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Withdrawal_test.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Withdrawal.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionInfo_test.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionInfo.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockResponse_test.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockResponse.zig`

**Modify:**
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` (Export the new types)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByNumber/eth_getBlockByNumber.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByHash/eth_getBlockByHash.zig`

## Tests to Write

- **Unit Tests (`*_test.zig`)**: 
  - `Withdrawal`: Serialize basic withdrawal structure and verify field types.
  - `TransactionInfo`: Serialize all supported transaction types.
  - `BlockResponse`: Serialize exact shapes for Genesis, London, Shanghai, and Cancun blocks. Ensure correct conditional serialization of fields like `baseFeePerGas`, `withdrawals`, `blobGasUsed`, etc.
- **Integration Tests**: 
  - Existing RPC handlers need to be tested for type compliance with the newly introduced types in `eth_getBlockByNumber` and `eth_getBlockByHash`.

## Risks and Mitigations

- **Risk**: Zig's default `std.json.stringify` outputs `null` for null optionals. EIP-1474 requires omitting these fields entirely.
  - **Mitigation**: Implement a custom `jsonStringify(self, jws)` method for `BlockResponse` to selectively write fields only if they are not null.
- **Risk**: The `transactions` field can be either an array of hashes or an array of hydrated transactions.
  - **Mitigation**: Use a tagged union (e.g., `HashOrTransactionInfo`) or `std.json.Value` with a custom formatter to handle the dual-nature of the `transactions` array.

## Verification of Acceptance Criteria

1. Run `zig build test` in the `voltaire` package to ensure all unit tests pass.
2. Ensure the resulting JSON serialization outputs precisely match the formats described in `execution-apis/tests/eth_getBlockByNumber/` examples.
3. Validate that `eth_getBlockByNumber` and `eth_getBlockByHash` are properly returning `BlockResponse`.