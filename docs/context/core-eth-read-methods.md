# Context: Core eth_* Read Method Handlers

## Ticket Info
- **Ticket ID**: core-eth-read-methods
- **Category**: cat-2-eth-read
- **Goal**: Implement 14 read-only state query RPC methods using `voltaire` backends (`StateManager`, `Blockchain`).

## Methods to Implement
- `eth_chainId`
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getCode`
- `eth_getStorageAt`
- `eth_getTransactionCount`
- `eth_gasPrice`
- `eth_accounts`
- `eth_coinbase`
- `net_version`
- `web3_clientVersion`
- `eth_syncing`
- `eth_maxPriorityFeePerGas`
- `eth_blobBaseFee`

## Reference Paths
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/` - Provides JSON-RPC types for 65 methods (Params/Results with JSON serde).
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` - Contains methods like `getBalance`, `getCode`, `getStorage`, and `getNonce`.
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` - Contains block storage and head block information.
- `execution-apis/tests/eth_getBalance/get-balance.io` - Test vectors for `eth_getBalance`.
- `execution-apis/tests/eth_getCode/get-code.io` - Test vectors for `eth_getCode`.
- `execution-apis/tests/eth_getStorageAt/get-storage.io` - Test vectors for `eth_getStorageAt`.
- `edr/crates/edr_provider/src/requests/eth.rs` - Hardhat's Rust EDR provider reference for RPC handlers.
- `../tevm-monorepo/packages/actions/src/` - TypeScript dev node actions referencing expected behaviors.
- `src/main.zig` - Entry point for the ZEVM daemon.
- `src/root.zig` - ZEVM root library exports.
- `src/database/database.zig` - Database abstractions, useful for understanding how state and blockchain integrate.

## Summary & Constraints
- **Do not reinvent the wheel**: `voltaire` and `guillotine-mini` already have the necessary infrastructure.
- Use `voltaire`'s `Params` and `Result` types for the RPC responses.
- Implement shared utility for resolving block tags (`'latest'`, `'earliest'`, `'pending'`, `<block_number>`).
- Need to initialize the genesis state: pre-fund dev accounts (like Hardhat's 20 accounts with 10000 ETH each) and store in `Blockchain` and `StateManager`.
- Ensure zig style is adhered to: use fully qualified paths (`no local type aliases`), and do not store allocators in structs (pass them to methods).
