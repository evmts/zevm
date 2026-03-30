# Context for genesis-bootstrap-and-core-eth-read

> **Archival / Non-Normative Notice**
> This document is retained for historical implementation context only and is **not** a source of requirements.
> For canonical, normative requirements, use:
> - `docs/specs/prd.md`
> - `docs/specs/json-rpc-contract.md`

## Ticket Details
- **Title**: Add node bootstrap state and core eth_* read handlers
- **Description**: Build a minimal ZEVM node runtime that initializes chain config and state needed for read methods, then implement core read handlers using existing StateManager/Database wiring. Focus on `eth_chainId`, `eth_blockNumber`, `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount`, `eth_gasPrice`, `eth_coinbase`, `eth_accounts`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee`, and `eth_feeHistory`. Reuse voltaire JSON-RPC types and existing ZEVM database/state components; avoid duplicating account/state primitives.
- **Category**: cat-2-eth-read
- **ID**: genesis-bootstrap-and-core-eth-read

## Reference Implementations & Specs
### `execution-apis/src/eth/state.yaml` & `fee_market.yaml`
Provides standard OpenAPI specs for core read methods:
- `eth_getBalance`: Needs address, block tag (latest, pending, hash). Returns balance in wei.
- `eth_getStorageAt`: Needs address, storage slot, block tag. Returns value as bytes.
- `eth_getTransactionCount`: Needs address, block tag. Returns account nonce.
- `eth_getCode`: Needs address, block tag. Returns bytecode as bytes.
- `eth_gasPrice`: Returns current gas price in wei.
- `eth_blobBaseFee`: Returns base fee per blob gas in wei.
- `eth_maxPriorityFeePerGas`: Returns max priority fee per gas.
- `eth_feeHistory`: Returns block base fees, gas used ratios, and rewards based on percentiles.

### Reference Implementations
- `../tevm-monorepo/packages/actions/src/eth/ethGetTransactionCountProcedure.js`: Shows pending transactions check, retrieving state root from block header, and returns nonce + pending count or forks appropriately.
- `edr/crates/edr_provider/src/requests/eth/blocks.rs`: Hardhat's Rust implementation showing block fetching (by hash or number), transaction detail serialization, and total difficulty calculations. Handles pending blocks by mining a pending block and retrieving its state.

### Upstream Dependencies (`voltaire`)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig`: Provides the `EthMethod` union for all JSON-RPC `eth_*` namespaces, including `Params` and `Result` types for robust JSON serialization/deserialization. Contains all required methods for this ticket (e.g., `eth_getBalance.Params`, `eth_getBalance.Result`).
- `StateManager` (`../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`): Source of truth for all account state. Has journal support and API like `getBalance(address)`, `getNonce(address)`, `getCode(address)`, etc.

### Existing Implementation (`zevm`)
- `src/database/database.zig`: `Database` struct contains `state: state_manager.StateManager`, `accounts`, `contracts`, `block_hashes`. Provides `init`, `deinit`, and methods to sync accounts to trie (`syncAccountToTrie`, `syncCachedAccountsToTrie`).

## Plan for Implementation
1. **Node Runtime**: Scaffold `src/node.zig` to bootstrap chain configuration and state. It should expose the `Database` and potentially an API to query it.
2. **Handlers**: Create `src/rpc/handlers/eth_read.zig` containing handler functions for `eth_chainId`, `eth_blockNumber`, `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount`, `eth_gasPrice`, `eth_coinbase`, `eth_accounts`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee`, and `eth_feeHistory`.
3. **Integration**: Wire the handlers in `eth_read.zig` to use the `node.zig` runtime, leveraging `Database.state` (`StateManager`) to read account balances, nonces, code, and storage. Use the `voltaire` JSON-RPC types for parsing requests and formatting responses.
4. **Testing**: Write unit tests in `src/rpc/handlers/eth_read_test.zig` verifying each read method returns correctly formatted data based on seeded state.
