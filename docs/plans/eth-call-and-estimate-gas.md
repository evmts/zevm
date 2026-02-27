# Plan: Implement eth_call and eth_estimateGas

## Overview
This plan details the TDD-driven implementation of the `eth_call` and `eth_estimateGas` RPC handlers for `zevm`. These handlers will utilize the `voltaire` JSON-RPC types and `StateManager`, alongside the `guillotine-mini` EVM execution engine via the `HostAdapter`. Execution will be stateless, using `StateManager.checkpoint()` and `StateManager.revert()` to ensure no persistent changes occur, even when applying EIP-3155 state overrides.

## TDD Step Order
1. **Test `resolveBlockTag`**: Write unit tests for block tag resolution (latest, earliest, pending, block number).
2. **Implement `resolveBlockTag`**: Implement the resolution logic to query the correct state root.
3. **Test `eth_call`**: Write unit tests for `eth_call` covering basic message calls, EIP-3155 state overrides, revert scenarios, and param validation.
4. **Implement `eth_call`**: Implement the RPC handler. It will parse params, checkpoint state, apply overrides, initialize the EVM via `HostAdapter`, execute the call, revert the state, and return the result or error.
5. **Test `eth_estimateGas`**: Write unit tests for `eth_estimateGas` covering EOA transfers (21000 gas), contract deployments (`CREATE_GAS`), successful contract calls via binary search, and reverting executions.
6. **Implement `eth_estimateGas`**: Implement the RPC handler using a binary search between intrinsic gas and block gas limit, internally wrapping the `eth_call` logic.
7. **Integration Tests**: Wire up execution of the test vectors from `execution-apis/tests/eth_call/` and `execution-apis/tests/eth_estimateGas/` to ensure full compliance.

## Files to Create/Modify
- `src/rpc_utils.zig`
  - `pub fn resolveBlockTag(allocator: std.mem.Allocator, state_manager: *voltaire.StateManager, tag: voltaire.rpc.BlockTag) !voltaire.primitives.Hash`
- `src/eth_call.zig`
  - `pub fn executeCall(allocator: std.mem.Allocator, state_manager: *voltaire.StateManager, params: voltaire.rpc.eth.call.Params) !voltaire.rpc.eth.call.Result`
- `src/eth_estimateGas.zig`
  - `pub fn estimateGas(allocator: std.mem.Allocator, state_manager: *voltaire.StateManager, params: voltaire.rpc.eth.estimateGas.Params) !voltaire.rpc.eth.estimateGas.Result`

## Tests to Write (Unit & Integration)
- `src/rpc_utils_test.zig`:
  - Test resolution of `latest`, `earliest`, `pending`, and specific block numbers.
- `src/eth_call_test.zig`:
  - Test execution of a simple view function.
  - Test `eth_call` with state overrides (e.g., modifying caller balance or contract code).
  - Test returning a hex-encoded revert reason when EVM execution fails.
  - Test validation of `CallObject` inputs.
- `src/eth_estimateGas_test.zig`:
  - Test exactly 21000 gas returned for simple EOA transfers.
  - Test gas estimation for contract creation (`CREATE_GAS` + execution).
  - Test successful binary search yielding the exact minimum gas for a contract call.
  - Test proper error bubbling when the call inherently reverts regardless of gas limit.
- **Integration**:
  - Add a test runner in `src/integration_tests.zig` (or equivalent) to execute the 6 JSON test vectors for both `eth_call` and `eth_estimateGas` from `execution-apis/tests/`.

## Risks and Mitigations
- **Risk**: State leakage. If `StateManager.revert()` is bypassed due to a panic or unhandled error, subsequent RPC calls could be executed against a corrupted state.
  - **Mitigation**: Use Zig's `errdefer` and `defer` rigorously to guarantee that `sm.revert()` is called in all execution paths immediately after `sm.checkpoint()`.
- **Risk**: Binary search in `eth_estimateGas` taking too long or diverging.
  - **Mitigation**: Strictly bound the search between intrinsic gas and the block gas limit. Cap the number of iterations or ensure the condition logic cleanly exits.
- **Risk**: Handling EIP-3155 state overrides correctly via the `HostAdapter`.
  - **Mitigation**: Fully unit test all override types (nonce, balance, code, state diff) by injecting them into the state prior to EVM initialization.

## Verification against Acceptance Criteria
- Run `zig build test` to ensure all unit tests pass.
- Run integration tests against `execution-apis/tests/eth_call/` and `execution-apis/tests/eth_estimateGas/`.
- Verify that `eth_call` returns valid bytes and handles overrides without persisting state.
- Verify that `eth_estimateGas` returns minimum gas and handles creates/EOA transfers.