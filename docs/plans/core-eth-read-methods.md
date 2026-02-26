# Plan: Core eth_* Read Method Handlers

## Overview
This plan details the implementation of 14 core read-only `eth_*` RPC methods for ZEVM. These queries require no EVM execution and rely on the `StateManager` and `Blockchain` provided by `voltaire`. The implementation will follow strict TDD, implementing tests first for each atomic piece, and adhere strictly to the project's Zig style rules (no local type aliases, explicit allocators).

## Risks and Mitigations
- **Risk**: Re-inventing JSON-RPC serialization/deserialization.
  **Mitigation**: Strictly use types from `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/`.
- **Risk**: Block tag resolution (e.g., `'latest'`, `'pending'`) mismatching standard RPC behavior.
  **Mitigation**: Create a dedicated block tag resolution utility fully tested against edge cases before implementing the methods.
- **Risk**: Missing Zig style requirements.
  **Mitigation**: Code reviews and strict adherence to passing `std.mem.Allocator` as a parameter and using fully qualified paths (e.g., `std.testing.allocator`, `voltaire.state_manager.StateManager`).

## TDD Step Order

### Step 1: Block Tag Resolution Utility
*   **Create Test**: `src/rpc/block_tag_test.zig`
    *   Test `'latest'` returns the blockchain's head block number.
    *   Test `'earliest'` returns 0.
    *   Test `'pending'` returns the pending block number (or head + 1 if applicable).
    *   Test hex string parsing (e.g., `'0x1b4'`) to integers.
*   **Create Implementation**: `src/rpc/block_tag.zig`
    *   Implement `pub fn resolveBlockTag(allocator: std.mem.Allocator, tag: []const u8, blockchain: *voltaire.blockchain.Blockchain) !u64`.

### Step 2: Genesis State Initialization
*   **Create Test**: `src/genesis_test.zig`
    *   Verify it creates 20 standard dev accounts.
    *   Verify each account has 10000 ETH.
    *   Verify the accounts are inserted into `StateManager` and `Blockchain` genesis.
*   **Create Implementation**: `src/genesis.zig`
    *   Implement `pub fn initDevGenesis(allocator: std.mem.Allocator, state_manager: *voltaire.state_manager.StateManager, blockchain: *voltaire.blockchain.Blockchain) !void`.

### Step 3: Constant & Simple Network Queries
*   **Methods**: `eth_chainId`, `eth_gasPrice`, `eth_accounts`, `eth_coinbase`, `net_version`, `web3_clientVersion`, `eth_syncing`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee`.
*   **Create Test**: `src/rpc/handlers/eth_constants_test.zig`
    *   Test each handler returns the expected constant or dev-configured value.
*   **Create Implementation**: `src/rpc/handlers/eth_constants.zig`
    *   Implement individual handler functions matching `voltaire` JSON-RPC types, e.g., `pub fn handleEthChainId(...) !voltaire.jsonrpc.Result`.

### Step 4: Block Number Query
*   **Methods**: `eth_blockNumber`.
*   **Create Test**: `src/rpc/handlers/eth_blockNumber_test.zig`
    *   Test against an empty and populated `Blockchain` mock to verify it returns the head block number.
*   **Create Implementation**: `src/rpc/handlers/eth_blockNumber.zig`
    *   Implement `pub fn handleEthBlockNumber(...) !voltaire.jsonrpc.Result`.

### Step 5: State Queries
*   **Methods**: `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount`.
*   **Create Test**: `src/rpc/handlers/eth_state_queries_test.zig`
    *   Test balance retrieval for pre-funded accounts and unknown accounts.
    *   Test code retrieval for smart contracts and EOAs.
    *   Test storage slot retrieval.
    *   Test nonce retrieval.
    *   Verify block tag routing works correctly.
*   **Create Implementation**: `src/rpc/handlers/eth_state_queries.zig`
    *   Implement the four handler functions routing to `voltaire.state_manager.StateManager` using `resolveBlockTag`.

### Step 6: Integration and Verification
*   **Action**: Wire all new handlers into the main RPC router (likely in `guillotine-mini` router wrappers or `src/rpc/router.zig`).
*   **Test**: Run Hive `rpc-compat` tests for `eth_blockNumber`, `eth_chainId`, `eth_getBalance`, ensuring acceptance criteria are met.

## Verification Against Acceptance Criteria
- [ ] `eth_chainId` returns configured chain ID in hex.
- [ ] `eth_blockNumber` returns current head block number.
- [ ] `eth_getBalance` returns correct balance for pre-funded accounts and 0 for unknown.
- [ ] `eth_getCode` returns bytecode for contract addresses and 0x for EOAs.
- [ ] `eth_getStorageAt` returns storage value at given slot.
- [ ] `eth_getTransactionCount` returns nonce for address.
- [ ] `eth_gasPrice` returns non-zero gas price.
- [ ] `eth_accounts` returns list of 10+ pre-funded dev account addresses.
- [ ] `eth_coinbase` returns configured coinbase.
- [ ] `net_version` returns network ID string.
- [ ] `web3_clientVersion` returns zevm version string.
- [ ] Block tag resolution works for 'latest', 'earliest', 'pending', and hex numbers.
- [ ] Genesis block created with pre-funded accounts on startup.
- [ ] Hive rpc-compat tests for eth_blockNumber, eth_chainId, eth_getBalance pass.
