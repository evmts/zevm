# Context: tx-sending-and-mempool

## Goal
Implement the critical path from user transaction intent to on-chain state change, specifically focusing on `eth_sendTransaction`, `eth_sendRawTransaction`, transaction mempool, and automine integration.

## Reference Materials

### Upstream Dependencies
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/sendRawTransaction/eth_sendRawTransaction.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/sendTransaction/eth_sendTransaction.zig`
  - Defines the JSON-RPC types for `Params` and `Result` for submitting transactions. `Params.transaction` carries the transaction data, and `Result.value` is the transaction hash.

### Existing Codebase (ZEVM)
- `src/tx_processor.zig`: Handles gas deduction, nonce incrementation, EVM execution, state commits/reverts, and gas refunds. Computes legacy transaction hashes.
- `src/block_builder.zig`: Defines `buildBlock` which sequentially processes transactions and builds a block. Invalid transactions (bad nonce, insufficient balance) are filtered.
- `src/host_adapter.zig`: Adapts `state_manager` to the EVM Host interface.
- `src/database/database.zig`: Handles state trie synchronization.

### Reference Implementations
- **TeVM (`../tevm-monorepo/packages/actions/src/eth/`)**: 
  - `ethSendRawTransactionProcedure.js` and `ethSendTransactionProcedure.js` showcase validation, adding the transaction to the txPool, and immediately calling `handleAutomining` if the node's mining config dictates 'auto'.
- **Hardhat EDR (`edr/crates/edr_provider/src/requests/eth/transactions.rs`)**:
  - Showcases RLP decoding, signature validation, chain ID verification, EIP-1559 gas calculation defaults, and routing to the node's transaction logger/mempool.
- **Foundry Anvil (`foundry/crates/anvil/src/eth/pool/`)**:
  - `transactions.rs` and `mod.rs` detail an advanced pool supporting `ReadyTransactions` vs `PendingTransactions`. Transactions require markers (`nonce`, `sender`) to become ready. Prioritization is done via transaction fees (gas price) then submission ID/nonce.

## Key Insights for Implementation

1. **Mempool Design:**
   - Must differentiate between *Pending* (future nonces) and *Ready* (matching current nonces).
   - Needs to support queuing by sender and ordering by nonce strictly, and sorting across senders by gas price.
   - Upon block mining, transactions must be pruned from the pool, unlocking dependent pending transactions if their nonce becomes current.

2. **`eth_sendRawTransaction` Flow:**
   - Deserialize RLP-encoded bytes.
   - Validate signature and recover the `sender`.
   - Validate the initial constraints (chain ID matches, balance is sufficient, nonce is valid).
   - Compute transaction hash.
   - Add to mempool.
   - Trigger automine (if enabled).
   - Return transaction hash.

3. **`eth_sendTransaction` Flow:**
   - Look up the private key for the `from` address in the node's managed accounts.
   - Assign defaults (gas, gasPrice, nonce) if not provided by the user.
   - Sign the transaction.
   - Hand over to the `sendRawTransaction` flow.

4. **Automine Integration:**
   - When a transaction is added to the pool and automine is enabled, gather all *Ready* transactions from the mempool.
   - Call `block_builder.buildBlock(allocator, sm, host_iface, ready_txs, block_ctx)`.
   - Increment block number, commit to blockchain storage, and flush state root to the trie via `Database.syncAccountToTrie`.
   - Prune the mined transactions from the mempool.
