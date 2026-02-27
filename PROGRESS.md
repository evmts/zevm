# ZEVM Progress Report

**Last Updated:** 2026-02-26  
**Zig Version:** 0.15.2

## Executive Summary

ZEVM is a Zig Ethereum client that serves as both a light client (via consensus layer sync) and a trusted dev node (like Hardhat/Anvil). It leverages upstream dependencies (voltaire for primitives/state/blockchain, guillotine-mini for EVM interpreter) to avoid reinventing infrastructure.

### Current State: Core Infrastructure Complete, RPC Layer Missing

- ✅ **Light client consensus sync** — Full implementation with BLS signature verification
- ✅ **Transaction processing** — Intrinsic gas, ETH transfers, precompiles, nonce validation
- ✅ **Block building** — Gas limit enforcement, invalid tx filtering, receipt generation
- ✅ **State management** — Host adapter connecting voltaire's StateManager to guillotine-mini's EVM
- ✅ **Database layer** — Accounts, contracts, block hash storage
- ❌ **RPC server** — No HTTP server or JSON-RPC dispatch
- ❌ **RPC handlers** — No eth/anvil/hardhat namespace implementations
- ❌ **Mempool** — No pending transaction pool
- ❌ **Mining** — No block production coordinator

---

## Completion by Category

| Category | Status | Completion | Notes |
|----------|--------|------------|-------|
| **1. Core Consensus (Light Client)** | ✅ Complete | 100% | Full light client sync with BLS verification |
| **2. EVM Execution** | ✅ Complete | 95% | Via guillotine-mini + host adapter |
| **3. State Management** | ✅ Complete | 90% | StateManager + ForkBackend in voltaire |
| **4. Database** | ✅ Complete | 85% | Accounts, contracts, block hashes |
| **5. Transaction Processing** | ✅ Complete | 90% | Legacy tx support, EIP-1559 pending |
| **6. Block Building** | ✅ Complete | 80% | Sequential execution, gas enforcement |
| **7. RPC Infrastructure** | ❌ Not Started | 0% | Needs HTTP server + dispatch layer |
| **8. RPC Handlers (eth_*)** | ❌ Not Started | 0% | Types exist in voltaire, no handlers |
| **9. RPC Handlers (anvil_*)** | ❌ Not Started | 0% | Dev node namespace |
| **10. RPC Handlers (hardhat_*)** | ❌ Not Started | 0% | Impersonation, snapshots |
| **11. Mempool** | ❌ Not Started | 0% | Pending transaction pool |
| **12. Mining Coordinator** | 📝 Planned | 10% | Tickets created, not implemented |
| **13. Fork Backend** | 📝 Planned | 20% | voltaire has ForkBackend, needs integration |
| **14. Snapshots** | ❌ Not Started | 0% | State snapshot/revert |
| **15. Genesis/Dev Accounts** | ❌ Not Started | 0% | Hardhat-style genesis state |

---

## Detailed Status

### ✅ Complete Components

#### 1. Consensus Light Client (`consensus_sync.zig`, `consensus_verifier.zig`, `beacon_api.zig`)

| Feature | Status |
|---------|--------|
| Light client bootstrap | ✅ |
| Sync committee update verification | ✅ |
| BLS12-381 signature verification | ✅ |
| Finality update processing | ✅ |
| Optimistic header tracking | ✅ |
| Mainnet/Sepolia/Holesky configs | ✅ |
| Beacon API HTTP client | ✅ |

**Files:**
- `src/consensus_sync.zig` — Sync engine with update batching
- `src/consensus_verifier.zig` — BLS signature + proof verification
- `src/beacon_api.zig` — Beacon node HTTP client
- `src/checkpoint.zig` — Checkpoint persistence to disk

#### 2. Transaction Processor (`tx_processor.zig`)

| Feature | Status |
|---------|--------|
| Intrinsic gas calculation | ✅ |
| Legacy transaction validation | ✅ |
| Nonce validation | ✅ |
| Balance checks | ✅ |
| Gas deduction/refund | ✅ |
| Coinbase payment | ✅ |
| Precompile routing | ✅ |
| Contract creation | ✅ |
| Receipt generation | ✅ |

**Pending:**
- EIP-1559 transaction support
- EIP-2930 (access list) transactions
- EIP-4844 (blob) transactions

#### 3. Block Builder (`block_builder.zig`)

| Feature | Status |
|---------|--------|
| Sequential tx execution | ✅ |
| Gas limit enforcement | ✅ |
| Invalid tx filtering | ✅ |
| Cumulative gas tracking | ✅ |

#### 4. Host Adapter (`host_adapter.zig`)

Adapts voltaire's StateManager to guillotine-mini's HostInterface vtable.

| Feature | Status |
|---------|--------|
| Balance get/set | ✅ |
| Nonce get/set | ✅ |
| Code get/set | ✅ |
| Storage get/set | ✅ |

#### 5. Database (`database/*.zig`)

| Feature | Status |
|---------|--------|
| Account storage | ✅ |
| Contract code storage | ✅ |
| Block hash tracking | ✅ |
| State root computation | 📝 |

#### 6. Test Coverage

All existing tests pass:
- `tx_processor_test.zig` — 5 test cases
- `host_adapter_test.zig` — 4 test cases
- `block_builder_test.zig` — 3 test cases
- `consensus_verifier_test.zig` — 4 test cases
- `beacon_api_test.zig` — 4 test cases
- `consensus_sync_test.zig` — 3 test cases
- `checkpoint_test.zig` — 2 test cases
- `database_test.zig` — 4 test cases

---

### 📝 In Progress / Planned

#### 7. RPC Server Infrastructure

**Status:** Not started. Research tickets created.

**Upstream Available:**
- voltaire has 65 JSON-RPC method types (Params/Results with JSON serde)
- No HTTP server or dispatch in upstream

**Required Work:**
- HTTP server (use std.http.Server or external)
- JSON-RPC envelope parsing
- Method dispatch/routing
- Error response formatting

#### 8-10. RPC Handlers

**Status:** Not started. Plans created for:
- `cat-2-eth-read`: eth_getBalance, eth_getCode, eth_getStorageAt, eth_getTransactionCount
- `cat-3-eth-call`: eth_call, eth_estimateGas
- `cat-4-eth-send`: eth_sendRawTransaction, eth_sendTransaction
- `cat-5-block-queries`: eth_getBlockByHash, eth_getBlockByNumber, etc.
- `cat-6-mining`: eth_mine, anvil_mine
- `cat-7-snapshots`: evm_snapshot, evm_revert
- `cat-9-impersonation`: hardhat_impersonateAccount

#### 11. Mempool

**Status:** Not started. Ticket created.

**Required:**
- Pending transaction pool
- Nonce ordering
- Gas price prioritization
- Transaction validation pipeline

#### 12. Mining Coordinator

**Status:** Planned. Ticket created.

**Required:**
- Automatic block production
- Interval-based mining
- Dev mode (mine on demand)
- Coinbase configuration

#### 13. Fork Backend Integration

**Status:** Planned. Ticket created.

**Upstream Available:**
- voltaire has `ForkBackend.zig` with RPC client + caching

**Required:**
- Database integration with ForkBackend
- Remote state fetching
- Block replay for historical queries

#### 14. Snapshots

**Status:** Not started. Ticket created.

**Required:**
- State snapshot capture
- Revert to snapshot
- Snapshot ID management

#### 15. Genesis / Dev Accounts

**Status:** Not started. Ticket created.

**Required:**
- Genesis state configuration
- Hardhat-style dev accounts (10 accounts with 10,000 ETH)
- Auto-funding on startup

---

## Upstream Dependencies

### voltaire (`../voltaire`)

| Module | Usage |
|--------|-------|
| `primitives` | All Ethereum types (Address, Hash, Transaction, Block, etc.) |
| `state-manager` | StateManager, ForkBackend, JournaledState |
| `blockchain` | BlockStore, Blockchain |
| `crypto` | BLS12-381, secp256k1, keccak256 |
| `precompiles` | All Ethereum precompiles |
| `jsonrpc` | 65 JSON-RPC method types (Params/Results) |
| `evm` | Alternative EVM (unused, using guillotine-mini) |

### guillotine-mini (`../guillotine-mini`)

| Module | Usage |
|--------|-------|
| `evm.zig` | EVM interpreter with comptime configuration |
| `host.zig` | HostInterface vtable definition |
| `call_params.zig` | Call/create parameter types |
| `call_result.zig` | Execution result types |
| `access_list_manager.zig` | EIP-2930 access list tracking |
| `async_executor.zig` | Async execution utilities |

---

## Recent Work (from git log)

### Research Phase (2026-02-26)

Created comprehensive plans for all major components:

1. **cat-1-rpc-server**: HTTP JSON-RPC server and dispatch
2. **cat-2-eth-read**: Core eth read methods + genesis state
3. **cat-3-eth-call**: eth_call + eth_estimateGas
4. **cat-4-eth-send**: Transaction sending + mempool
5. **cat-5-block-queries**: Block/tx queries + storage
6. **cat-6-mining**: Mining coordinator + anvil namespace
7. **cat-7-snapshots**: Snapshot/revert functionality
8. **cat-9-impersonation**: Hardhat impersonation
9. **cat-10-forking**: ForkBackend database integration

### Implementation Status

- ✅ Core light client consensus sync
- ✅ Transaction processing pipeline
- ✅ Block building
- ✅ Host adapter for EVM state access
- ✅ Database layer
- ✅ All test suites passing

---

## Gaps & Priorities

### Critical Path (Dev Node MVP)

| Priority | Component | Blocker | Effort |
|----------|-----------|---------|--------|
| 1 | HTTP JSON-RPC Server | None | Medium |
| 2 | eth_read handlers | Server | Low |
| 3 | eth_call handler | Server | Low |
| 4 | eth_sendRawTransaction | Server + Mempool | Medium |
| 5 | Mempool | None | Medium |
| 6 | Mining coordinator | Mempool | Low |
| 7 | Genesis state | None | Low |
| 8 | Anvil namespace | Mining | Low |

### Secondary (Advanced Features)

| Priority | Component | Blocker | Effort |
|----------|-----------|---------|--------|
| 9 | Fork backend | Database | Medium |
| 10 | Snapshots | StateManager | Medium |
| 11 | Hardhat namespace | Snapshots | Low |
| 12 | Filters (eth_newFilter) | None | Medium |
| 13 | Websockets | HTTP server | High |

---

## Build & Test Commands

```bash
# Build
zig build

# Run tests
zig build test

# Run executable
zig build run

# Fetch dependencies
zig build --fetch
```

---

## Code Statistics

```
Language     Files    Lines    Code    Comments    Blank
Zig           20      ~3500   ~2800      ~300       ~400
```

---

## Next Steps

1. **Implement HTTP JSON-RPC server** — Foundation for all RPC handlers
2. **Add core eth_* handlers** — Minimum viable dev node interface
3. **Implement mempool** — Required for transaction broadcasting
4. **Add mining coordinator** — Automatic block production
5. **Genesis state & dev accounts** — Hardhat-style local development
