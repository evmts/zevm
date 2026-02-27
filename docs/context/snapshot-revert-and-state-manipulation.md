# Snapshot, Revert, and State Manipulation Context

## Reference Materials
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`
- `edr/crates/edr_provider/src/requests/hardhat/state.rs`
- `edr/crates/edr_provider/src/requests/eth/evm.rs`
- `foundry/crates/anvil/src/eth/api.rs`
- `foundry/crates/anvil/tests/it/anvil_api.rs`
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetBalanceProcedure.js`
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetCodeProcedure.js`
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetNonceProcedure.js`
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetStorageAtProcedure.js`

## Existing Codebase
- `src/database/database.zig`
- `src/block_builder.zig`
- `src/host_adapter.zig`

## Summary of Implementation Steps

### 1. evm_snapshot & evm_revert
- **Snapshot (`evm_snapshot`)**: Capture the full state. Use `StateManager.snapshot()` which provides an in-memory snapshot and returns an ID. Also, capture the current block number and mempool state so those can be restored. Return the snapshot ID as a hex string.
- **Revert (`evm_revert`)**: Revert state using `StateManager.revertToSnapshot(snapshot_id)`. Also revert block number and clear blocks/transactions mined after the snapshot. Returns true on success or false on invalid ID. 

### 2. State Manipulation Methods
These methods modify the state directly, ignoring standard EVM rules to facilitate testing. 
- **`hardhat_setBalance(address, balance)`**: Calls `StateManager.setBalance(address, balance)`.
- **`hardhat_setCode(address, code)`**: Calls `StateManager.setCode(address, code)`.
- **`hardhat_setNonce(address, nonce)`**: Calls `StateManager.setNonce(address, nonce)`.
- **`hardhat_setStorageAt(address, slot, value)`**: Calls `StateManager.setStorage(address, slot, value)`.

### 3. Block/Network Manipulation Methods
- **`hardhat_setCoinbase(address)`**: Update the coinbase address in the NodeConfig.
- **`hardhat_setNextBlockBaseFeePerGas(fee)`**: Set the base fee for the next block to be mined.
- **`evm_setBlockGasLimit(limit)`**: Set the block gas limit (via block context).

### 4. Compatibility Aliases
- Ensure all `hardhat_*` methods are aliased to `anvil_*` variants (e.g. `anvil_setBalance`) for full compatibility with Hardhat/Anvil/Foundry testing tools.

### 5. Integration
- Add the Hardhat/Anvil/EVM namespace JSON-RPC types into Voltaire's JSON-RPC module (or adapt `guillotine-mini`/`zevm` routing) for dispatching these methods.
- Plumb these methods through the `zevm` RPC handler down to the `Database` wrapper and the underlying `StateManager`.
