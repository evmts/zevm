# ZEVM — Zig Ethereum Virtual Machine

## Overview

ZEVM is a Zig Ethereum client that operates in two modes:
1. **Light client** — Syncs consensus via Beacon chain, verifies proofs trustlessly (like Helios)
2. **Trusted dev node** — Local development node with Hardhat/Anvil-compatible JSON-RPC (like EDR/Anvil)

## Architecture

ZEVM is a **thin integration layer** on top of two upstream libraries we own:

- **voltaire** (`../voltaire`) — Ethereum primitives, JSON-RPC types (65 methods), StateManager with fork support, ForkBackend, Blockchain, full EVM, crypto, precompiles
- **guillotine-mini** (`../bench/guillotine-mini`) — EVM interpreter, RPC dispatch/routing, envelope parsing, response serialization

If either upstream library is missing a feature, add it there — not in zevm.

## Target Feature Parity

ZEVM aims for feature parity with:
- **Hardhat EDR** (edr/) — 73 RPC methods, mining modes, snapshots, impersonation, tracing
- **Foundry Anvil** (foundry/) — Fast dev node with fork support
- **TEVM** (../tevm-monorepo) — TypeScript trusted client with eth/anvil/debug handlers
- **Helios** — Rust light client with consensus verification + proof-based reads

## What's Already Done

### Consensus Layer (Light Client)
- BLS12-381 signature verification
- SSZ Merkle proof validation
- Beacon API client (bootstrap, updates, finality)
- Consensus sync engine (bootstrap → sync → advance)
- Checkpoint file persistence
- Network configs (mainnet, sepolia, holesky)

### Execution Layer
- Transaction processing with full gas accounting (intrinsic gas, refunds, miner payment)
- Block building with gas limit enforcement and receipt generation
- State management with journaling (checkpoint/revert)
- Merkle Patricia Trie for state root computation
- Contract code deduplication
- Host adapter bridging voltaire StateManager to guillotine-mini HostInterface

## What's Needed

### 1. HTTP JSON-RPC Server
- HTTP listener on configurable port (default 8545)
- JSON-RPC 2.0 request/response handling (reuse voltaire jsonrpc types + guillotine-mini rpc dispatch)
- Batch request support
- Standard error codes (-32700, -32600, -32601, -32602, -32603)

### 2. Core eth_* Read Methods
- eth_chainId, eth_blockNumber, eth_getBalance, eth_getCode, eth_getStorageAt
- eth_getTransactionCount, eth_gasPrice, eth_coinbase, eth_accounts
- eth_maxPriorityFeePerGas, eth_blobBaseFee, eth_feeHistory

### 3. eth_call + eth_estimateGas
- Execute against state without persisting (checkpoint/revert)
- State overrides support
- Gas estimation via binary search

### 4. Transaction Sending + Mempool
- eth_sendTransaction, eth_sendRawTransaction
- Pending transaction pool with nonce ordering
- Automine integration

### 5. Block & Transaction Queries
- eth_getBlockByNumber/Hash, eth_getTransactionByHash
- eth_getTransactionReceipt, eth_getBlockReceipts
- eth_getLogs with address/topic/block-range filtering

### 6. Mining Modes
- Automine (mine on every tx — default)
- Manual mining (evm_mine, hardhat_mine)
- Interval mining (timer-based)

### 7. Snapshot & Revert
- evm_snapshot: capture full state with ID
- evm_revert: rollback to snapshot

### 8. State Manipulation (Hardhat/Anvil compat)
- hardhat_setBalance, hardhat_setCode, hardhat_setNonce, hardhat_setStorageAt
- hardhat_setCoinbase, hardhat_setNextBlockBaseFeePerGas, hardhat_setPrevRandao
- evm_setBlockGasLimit

### 9. Account Impersonation
- hardhat_impersonateAccount, hardhat_stopImpersonatingAccount
- Skip signature validation for impersonated addresses

### 10. Fork Mode
- CLI flag --fork-url to fork from remote RPC
- Use voltaire's ForkBackend + JournaledState (already implements fork caching)
- Local state overrides on top of forked state

### 11. Debug & Tracing
- debug_traceCall, debug_traceTransaction
- Struct log tracer (geth format)
- Configurable: disableStorage, disableMemory, disableStack

### 12. Filters & Subscriptions
- eth_newFilter, eth_newBlockFilter, eth_newPendingTransactionFilter
- eth_getFilterChanges, eth_getFilterLogs, eth_uninstallFilter
- eth_subscribe/eth_unsubscribe (WebSocket)

### 13. Time Manipulation
- evm_increaseTime, evm_setNextBlockTimestamp
- hardhat_setPrevRandao

## Zig Style Rules

- No local type aliases (`const Foo = bar.Foo` is banned). Always use fully qualified paths.
- No stored allocators. Pass allocator explicitly to methods that need it.
- Zig 0.15 with lowercase `@typeInfo` variants (`.int`, `.bool`, `.float`).
