# Research Context: eth_call and eth_estimateGas

**Ticket:** eth-call-and-estimate-gas  
**Category:** cat-3-eth-call  
**Date:** 2026-02-26

## Overview

Implement `eth_call` and `eth_estimateGas` — the two most-used RPC methods after basic reads. These execute EVM transactions without persisting state changes, which is exactly what tx_processor + StateManager checkpoint/revert already support.

## Critical: Upstream Dependencies

We own and maintain these upstream dependencies. If they are missing functionality, add it there:

1. **voltaire** (`../voltaire/packages/voltaire-zig/src/`)
   - Has JSON-RPC types for 65 methods (Params/Results with JSON serde)
   - StateManager with fork support at `state-manager/StateManager.zig`
   - ForkBackend with RPC client + caching
   - Blockchain with block storage at `blockchain/Blockchain.zig`
   - Full EVM, crypto (BLS, secp256k1, keccak), precompiles
   - All Ethereum primitives

2. **guillotine-mini** (`../bench/guillotine-mini/`)
   - EVM interpreter
   - RPC dispatch/routing (client/rpc/)
   - Envelope parsing, response serialization
   - Engine API

## Existing ZEVM Infrastructure

### Core Files

| File | Purpose | Key Components |
|------|---------|----------------|
| `src/tx_processor.zig` | Transaction processing with EVM execution | `processTransaction()`, `intrinsicGas()`, checkpoint/revert pattern |
| `src/host_adapter.zig` | StateManager → HostInterface adapter | `HostAdapter` struct with vtable delegation |
| `src/database/database.zig` | In-memory state database | `Database` with `StateManager`, `Accounts`, `Contracts` |
| `src/block_builder.zig` | Block construction | `BlockBuilder` for assembling blocks |

### Checkpoint/Revert Pattern (Already Working)

From `tx_processor.zig`:
```zig
// Checkpoint AFTER gas/nonce so revert only undoes EVM state changes
sm.checkpoint() catch return TxError.StateError;

// ... execute EVM ...

// Commit or revert EVM state changes (gas/nonce already applied above checkpoint)
if (result.success) {
    sm.commit();
} else {
    sm.revert();
}
```

This is exactly what eth_call and eth_estimateGas need.

## eth_call

### JSON-RPC Spec

**Method:** `eth_call`  
**Params:**
1. Transaction object:
   - `from`: Address (optional, default depends on client)
   - `to`: Address (optional for contract creation)
   - `gas`: Quantity (optional)
   - `gasPrice`: Quantity (optional)
   - `maxFeePerGas`: Quantity (optional, EIP-1559)
   - `maxPriorityFeePerGas`: Quantity (optional, EIP-1559)
   - `value`: Quantity (optional)
   - `data`: Data (optional, hex string)
   - `nonce`: Quantity (optional)
   - `accessList`: Array of access list entries (optional, EIP-2930)
   - `blobVersionedHashes`: Array of hashes (optional, EIP-4844)
   - `maxFeePerBlobGas`: Quantity (optional, EIP-4844)
2. Block specification: tag (latest/pending/earliest/safe/finalized), number, or hash
3. State overrides (optional): Map of address → AccountOverride

**Returns:** `Data` - hex-encoded bytes returned by the call

**Error Response:**
- Code: 3
- Message: "execution reverted" or "execution reverted: <reason>"
- Data: Revert bytes (hex)

### State Overrides

From execution-apis spec:
```yaml
AccountOverride:
  properties:
    balance: uint256  # Account balance override
    nonce: uint64     # Account nonce override
    code: bytes       # Account code override
    state: AccountStorage     # Full storage replacement
    stateDiff: AccountStorage # Partial storage modification
```

State overrides allow temporary modification of account state before execution:
- **balance**: Override account balance
- **nonce**: Override account nonce
- **code**: Override contract code
- **state**: Replace entire storage (mutually exclusive with stateDiff)
- **stateDiff**: Override specific storage slots (mutually exclusive with state)

### Implementation Steps

1. Parse call params from voltaire's `eth_call.Params`
2. Resolve block tag to get correct state snapshot
3. Apply state overrides if provided (temporarily modify StateManager)
4. `StateManager.checkpoint()` before execution
5. Execute via guillotine-mini EVM (not tx_processor, since eth_call skips validation)
6. `StateManager.revert()` to discard changes
7. Return hex-encoded output data
8. On revert: return JSON-RPC error with code 3 and revert data in `data` field

### Key Differences from processTransaction

- eth_call does NOT validate nonce
- eth_call does NOT check balance (usually)
- eth_call does NOT deduct gas costs
- eth_call does NOT increment nonce
- eth_call uses base fee = 0 (per Geth behavior, see EDR)
- eth_call does NOT persist any state changes

## eth_estimateGas

### JSON-RPC Spec

**Method:** `eth_estimateGas`  
**Params:** Same as eth_call (transaction + block spec + state overrides)

**Returns:** `Quantity` - hex-encoded gas estimate

**Error Response:** Same as eth_call if execution reverts

### Binary Search Algorithm

From EDR (`edr/crates/edr_provider/src/data/gas.rs`):

```rust
const MAX_ITERATIONS: usize = 20;

while upper_bound - lower_bound > min_difference(lower_bound) && i < MAX_ITERATIONS {
    let mid = lower_bound + (upper_bound - lower_bound) / 2;
    
    // Test if transaction succeeds with `mid` gas
    let success = check_gas_limit(mid)?;
    
    if success {
        upper_bound = mid;
    } else {
        lower_bound = mid + 1;
    }
    i += 1;
}

return upper_bound;  // Tight upper bound on gas needed
```

### Min Difference Thresholds (Matches Hardhat)

From EDR:
```rust
fn min_difference(lower_bound: u64) -> u64 {
    if lower_bound >= 4_000_000 { 50_000 }
    else if lower_bound >= 1_000_000 { 10_000 }
    else if lower_bound >= 100_000 { 1_000 }
    else if lower_bound >= 50_000 { 500 }
    else if lower_bound >= 30_000 { 300 }
    else { 200 }
}
```

### Bounds

- **Lower bound**: Intrinsic gas (21,000 for transfers, more for contract creation/data)
- **Upper bound**: Block gas limit or user-provided gas limit
- **Initial mid**: Start close to lower bound (3x lower bound, per EDR)

### Implementation Steps

1. Same setup as eth_call (parse params, resolve block, apply overrides)
2. Calculate intrinsic gas as lower bound
3. Get block gas limit as upper bound (or user-provided gas limit)
4. Binary search:
   - Checkpoint
   - Execute with test gas limit
   - Revert
   - Adjust bounds based on success/failure
5. Return hex gas estimate (upper bound after convergence)

### Important Notes

- Default block tag is "pending" (not "latest") per Hardhat/Anvil behavior
- Must handle EIP-1559 fee parameters
- Must respect state overrides during estimation
- If execution reverts at max gas, return revert error

## Reference Implementations

### 1. EDR (Rust) - Primary Reference

**eth_call handler:** `edr/crates/edr_provider/src/requests/eth/call.rs`
- `handle_call_request()` - Main entry point
- `resolve_call_request()` - Build transaction from request
- `resolve_block_spec_for_call_request()` - Default to "latest"

**eth_estimateGas handler:** `edr/crates/edr_provider/src/requests/eth/gas.rs`
- `handle_estimate_gas()` - Main entry point
- `resolve_estimate_gas_request()` - Build transaction with fee resolution
- Uses StateOverrides::default() (no state overrides in estimateGas per EDR)

**Call execution:** `edr/crates/edr_provider/src/data/call.rs`
- `run_call()` - Execute with zero base fee wrapper
- Uses `BlockEnvWithZeroBaseFee` to mimic Geth behavior

**Gas estimation:** `edr/crates/edr_provider/src/data/gas.rs`
- `binary_search_estimation()` - Binary search implementation
- `check_gas_limit()` - Test if gas limit is sufficient

**State overrides:** `edr/crates/edr_runtime/src/overrides.rs`
- `StateOverrides` struct
- `AccountOverride` struct
- `StorageOverride` enum (Diff vs Full)
- `StateRefOverrider` - Wraps state with overrides

### 2. Foundry Anvil (Rust)

**API:** `foundry/crates/anvil/src/eth/api.rs`
- `call()` at line 1193 - Handler for eth_call
- `estimate_gas()` at line 1321 - Handler for eth_estimateGas
- Uses `EvmOverrides` for state overrides
- Supports both state and block overrides

**Backend:** `foundry/crates/anvil/src/eth/backend/mem/mod.rs`
- Call execution with state overrides
- Gas estimation with binary search

### 3. tevm (TypeScript)

**Call handler:** `tevm-monorepo/packages/actions/src/Call/`
- `CallParams.ts` - Parameter types
- `callHandlerOpts.ts` - Option processing
- `handleStateOverrides.ts` - State override application

**eth_call procedure:** `tevm-monorepo/packages/actions/src/eth/ethCallProcedure.spec.ts`
- Test showing basic call flow

### 4. execution-apis Test Vectors

**eth_call tests:** `execution-apis/tests/eth_call/`
- `call-contract.io` - Basic contract call
- `call-revert-abi-error.io` - Revert with ABI-encoded error
- `call-revert-abi-panic.io` - Panic revert
- `call-eip7702-delegation.io` - EIP-7702 delegation

**eth_estimateGas tests:** `execution-apis/tests/eth_estimateGas/`
- `estimate-simple-transfer.io` - Basic transfer (0x5208 = 21000)
- `estimate-successful-call.io` - Contract call
- `estimate-failed-call.io` - Reverting call
- `estimate-call-abi-error.io` - Revert with ABI error
- `estimate-with-eip4844.io` - Blob transaction
- `estimate-with-eip7702.io` - EIP-7702 transaction

## State Override Implementation Strategy

Since voltaire's StateManager already supports:
- `setBalance(address, balance)`
- `setNonce(address, nonce)`
- `setCode(address, code)`
- `setStorage(address, slot, value)`

We can implement state overrides by:

1. Before checkpoint, apply all overrides to StateManager
2. Execute the call
3. Revert (which restores original state including overrides)

For storage overrides:
- `state` (full): Clear all storage for address, then set provided slots
- `stateDiff` (diff): Just set the provided slots, leave others unchanged

## Error Handling

Both methods should return JSON-RPC errors with:

**Revert Error:**
```json
{
  "code": 3,
  "message": "execution reverted" or "execution reverted: <decoded reason>",
  "data": "0x<revert bytes>"
}
```

**Other errors:** Standard JSON-RPC error codes

## Testing Strategy

### Unit Tests (in zevm)

1. **eth_call basic success** - Call contract, return output
2. **eth_call revert** - Call reverting contract, check error format
3. **eth_call state override** - Override balance/code/storage, verify effect
4. **eth_estimateGas simple transfer** - Should return 21000 (0x5208)
5. **eth_estimateGas contract call** - Binary search finds correct gas
6. **eth_estimateGas revert** - Returns revert error, not gas estimate

### Integration Tests (Hive)

The execution-apis test files can be used as integration test vectors:
- Parse request/response pairs
- Execute against zevm RPC
- Compare responses

### Reference E2E Tests to Port

From EDR/hardhat-tests:
- `test/internal/hardhat-network/provider/modules/eth/methods/call.ts`
- Various call scenarios with state overrides

From Foundry anvil tests:
- `foundry/crates/anvil/tests/it/api.rs` - API integration tests
- `foundry/crates/anvil/tests/it/fork.rs` - Fork mode tests with overrides

## Files to Modify/Create

### New Files
- `src/rpc/eth_call.zig` - eth_call handler
- `src/rpc/eth_estimateGas.zig` - eth_estimateGas handler
- `src/state_override.zig` - State override application
- `src/rpc_test.zig` - RPC handler tests

### Modified Files
- `src/tx_processor.zig` - May need `executeCall()` that skips validation
- `src/database/database.zig` - May need helper for state overrides

## Open Questions

1. Do we need to support block overrides in addition to state overrides?
   - Anvil/EDR support both
   - execution-apis tests include block override tests

2. Should eth_estimateGas accept state overrides?
   - EDR does NOT (uses StateOverrides::default())
   - Anvil DOES support state overrides
   - Standard says: "state overrides can be used"

3. How to handle EIP-1559 fee parameters in eth_call?
   - EDR: Use zero base fee wrapper to mimic Geth
   - Anvil: Use FeeDetails with or_zero_fees()

## Next Steps

1. Implement `eth_call` without state overrides first
2. Add state override support
3. Implement `eth_estimateGas` with binary search
4. Run execution-apis tests
5. Run Hive rpc-compat tests (expect 9+ tests to pass)
