# Context: eth_call and eth_estimateGas Implementation

## Objective
Implement `eth_call` and `eth_estimateGas` RPC handlers for `zevm` using the `voltaire` and `guillotine-mini` libraries. Both functions are fundamental to DApp interactions, executing EVM calls against a temporary state without committing changes to the blockchain.

## Reference Paths & Implementations

### Upstream Dependencies (Do not reinvent)
*   **Voltaire JSON-RPC Types**: `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/call/eth_call.zig`, `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/estimateGas/eth_estimateGas.zig` (Defines `Params` and `Result` for both JSON-RPC methods).
*   **Voltaire StateManager**: `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` (Use `checkpoint()` and `revert()` to ensure state doesn't persist. Support state overrides using `setBalance`, `setNonce`, `setCode`, `setStorage`).
*   **Host Adapter**: `src/host_adapter.zig` (Adapts Voltaire's `StateManager` to Guillotine-Mini's `HostInterface` vtable).
*   **Guillotine-Mini EVM**: Setup EVM with the provided block context, initialize with `HostAdapter`, and dispatch `Evm.call()` passing `CallParams` (`.call` for direct interactions, `.create` for contract deployments). Output bytes and gas usage are captured via the returned result.

### Implementation References (For Behavior & Edge Cases)
*   **Hardhat/EDR**: `edr/crates/edr_provider/src/requests/eth/call.rs` (Handles block spec resolution, state overrides application, and transaction validation).
*   **Foundry Anvil**: `foundry/crates/anvil/src/eth/api.rs` (RPC layer translation, override resolution, and simulation routines).
*   **TEVM**: `../tevm-monorepo/packages/actions/src/Call/callHandler.js` & `../tevm-monorepo/packages/actions/src/eth/ethEstimateGasProcedure.js` (Reference for mapping `eth_estimateGas` to `call`, utilizing binary search or direct VM gas execution values with the `blockTag`).

### Test Coverage (Blackbox / Execution APIs)
*   **Execution APIs Tests**: Ensure integration is verified using test vectors in `execution-apis/tests/eth_call/` and `execution-apis/tests/eth_estimateGas/`. Examples include `call-revert-abi-error.io`, `call-eip7702-delegation.io`, `estimate-successful-call.io`.

## Implementation Strategy

### 1. `eth_call` Execution
1.  **Block Tag Resolution**: Resolve the block context (e.g., `latest`, `pending`) to query the correct state root.
2.  **State Snapshot**: Before execution, call `sm.checkpoint()` on Voltaire's `StateManager`.
3.  **State Overrides**: If EIP-3155 state overrides are provided, temporarily modify the state (e.g., `sm.setBalance()`).
4.  **EVM Initialization**: Setup the `HostAdapter` with the `StateManager`. Initialize Guillotine-Mini `Evm` passing the `HostAdapter` interface.
5.  **Execution**: Formulate `Evm.CallParams` (`.call` or `.create`) using the parameters from `EthCall.Params` and execute `evm.call()`.
6.  **Cleanup**: Irrespective of success or failure, call `sm.revert()` to rollback all state changes (including overrides).
7.  **Result**: Return the returned output byte array.

### 2. `eth_estimateGas` Logic
1.  **Wrapper**: Acts as a wrapper over `eth_call` mechanics.
2.  **Binary Search / Step**: Estimate gas bounds between the intrinsic gas baseline (e.g., 21000 for standard calls to EOAs) and the block gas limit.
3.  **Execution Loop**: Iteratively run the EVM execution (using checkpoints/reverts each time) adjusting the gas limit.
4.  **Failure Handling**: If execution fails at a given gas limit, increase the lower bound. Return the minimum gas required to not revert. Provide appropriate errors matching the revert reason if execution never succeeds.

## Relevant Workspace Files
*   **`src/tx_processor.zig`**: Demonstrates EVM routing, intrinsic gas calculation (`INTRINSIC_GAS`, `CREATE_GAS`), precompile dispatching, and transaction failure routing.
*   **`src/host_adapter.zig`**: Contains `HostAdapter` struct to wrap `state_manager` correctly for the EVM boundary.
*   **`src/block_builder.zig`**: Outlines execution limits (`block_gas_limit`) and transaction dropping boundaries which should be mirrored for RPC validations.
