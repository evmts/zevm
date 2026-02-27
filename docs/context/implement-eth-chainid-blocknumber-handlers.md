# Research: Implement eth_chainId and eth_blockNumber RPC Handlers

**Ticket:** implement-eth-chainid-blocknumber-handlers  
**Category:** cat-2-eth-read  
**Date:** 2026-02-26

---

## Executive Summary

This document contains research for implementing the two simplest read-only Ethereum JSON-RPC methods: `eth_chainId` and `eth_blockNumber`. These methods establish the foundational handler pattern for all subsequent RPC implementations in zevm.

---

## Specification References

### Execution APIs Spec (execution-apis/src/eth/client.yaml)

#### eth_chainId
```yaml
- name: eth_chainId
  summary: Returns the chain ID of the current network.
  params: []
  result:
    name: Chain ID
    schema:
      $ref: '#/components/schemas/uint'
  examples:
    - name: eth_chainId example
      params: []
      result:
        name: Chain ID
        value: '0x1'  # Returns as hex QUANTITY
```

#### eth_blockNumber
```yaml
- name: eth_blockNumber
  summary: Returns the number of most recent block.
  params: []
  result:
    name: Block number
    schema:
      $ref: '#/components/schemas/uint'
  examples:
    - name: eth_blockNumber example
      params: []
      result:
        name: Block number
        value: '0x2377'  # Returns as hex QUANTITY
```

**Key Spec Details:**
- Both methods take **zero parameters** (empty params array)
- Both return `uint` (QUANTITY) - hex-encoded unsigned integer with 0x prefix
- No block spec parameter needed for either method
- Chain ID is configured at node startup, block number comes from canonical head

---

## Upstream Dependencies (CRITICAL - DO NOT REINVENT)

### 1. Voltaire (`../voltaire/packages/voltaire-zig/src/`)

Voltaire already provides complete type definitions for both methods:

**File:** `jsonrpc/eth/chainId/eth_chainId.zig`
```zig
pub const method = "eth_chainId";

pub const Params = struct {
    // Empty params - no fields
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.write(.{});
    }
};

pub const Result = struct {
    value: types.Quantity,  // hex encoded unsigned integer
    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }
};
```

**File:** `jsonrpc/eth/blockNumber/eth_blockNumber.zig`
```zig
pub const method = "eth_blockNumber";

pub const Params = struct {
    // Empty params - no fields
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void {
        try jws.write(.{});
    }
};

pub const Result = struct {
    value: types.Quantity,  // hex encoded unsigned integer
    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void {
        try jws.write(self.value);
    }
};
```

**File:** `jsonrpc/types/Quantity.zig`
- Simple wrapper around `std.json.Value` for hex quantity encoding
- Handles 0x-prefixed hex without leading zeros per EIP-1474

**File:** `blockchain/Blockchain.zig`
Key methods for blockNumber:
```zig
/// Get current head block number (local canonical chain)
pub fn getHeadBlockNumber(self: *Blockchain) ?u64 {
    return self.block_store.getHeadBlockNumber();
}
```

**Voltaire Re-exports:**
- `jsonrpc/root.zig` - Re-exports all method types via `JsonRpcMethod` union
- `jsonrpc/eth/methods.zig` - Contains `EthMethod` union with all 40+ eth methods
- Access via: `@import("voltaire").jsonrpc.eth.EthMethod`

### 2. Guillotine-Mini (`../guillotine-mini/`)

Guillotine-mini is an **EVM interpreter**, not an RPC server. It provides:
- EVM execution engine (`src/evm.zig`)
- Host interface (`src/host.zig`) for state access
- No RPC dispatch/routing layer

**Conclusion:** RPC dispatch must be implemented in zevm, not guillotine-mini.

---

## Reference Implementations

### 1. TEVM (`../tevm-monorepo/packages/actions/src/eth/`)

**chainIdHandler.js:**
```javascript
export const chainIdHandler = (client) => async () => {
    const { common } = await client.getVm()
    return BigInt(common.id)  // Returns chain ID as bigint
}
```

**blockNumberHandler.js:**
```javascript
export const blockNumberHandler = (client) => async () => {
    const vm = await client.getVm()
    return vm.blockchain.getCanonicalHeadBlock().then((block) => block.header.number)
}
```

**Pattern:** Handler receives client/node reference, returns async function that calls appropriate backend method.

### 2. Hardhat EDR (`edr/crates/edr_provider/src/requests/eth/blockchain.rs`)

```rust
pub fn handle_block_number_request<...>(
    data: &ProviderData<ChainSpecT, TimerT>,
) -> Result<U64, ProviderErrorForChainSpec<ChainSpecT>> {
    Ok(U64::from(data.last_block_number()))
}

pub fn handle_chain_id_request<...>(
    data: &ProviderData<ChainSpecT, TimerT>,
) -> Result<U64, ProviderErrorForChainSpec<ChainSpecT>> {
    Ok(U64::from(data.chain_id()))
}
```

**Pattern:** 
- Pure functions taking `ProviderData` reference
- Direct delegation to data layer
- Returns typed result (not async for simple getters)

### 3. Foundry Anvil (`foundry/crates/anvil/src/eth/api.rs`)

```rust
pub fn eth_chain_id(&self) -> Result<Option<U64>> {
    node_info!("eth_chainId");
    Ok(Some(self.backend.chain_id().to::<U64>()))
}

pub fn block_number(&self) -> Result<U256> {
    node_info!("eth_blockNumber");
    Ok(U256::from(self.backend.best_number()))
}
```

**Pattern:**
- Methods on `EthApi` struct
- Access to `self.backend` for chain state
- Returns `Result<T>` for error handling

---

## ZEVM Implementation Strategy

### Architecture

Based on the reference implementations and zevm's stated role as a **thin integration layer**, the handler pattern should be:

```
┌─────────────────────────────────────────────────────────────┐
│  zevm RPC Layer (to implement)                              │
│  ├── Provider struct: holds chain_id, blockchain reference  │
│  └── Handler functions: eth_chainId, eth_blockNumber        │
├─────────────────────────────────────────────────────────────┤
│  voltaire (upstream)                                        │
│  ├── jsonrpc types: Params, Result, Quantity                │
│  └── Blockchain: getHeadBlockNumber()                       │
├─────────────────────────────────────────────────────────────┤
│  guillotine-mini (upstream)                                 │
│  └── EVM execution (not needed for read-only methods)       │
└─────────────────────────────────────────────────────────────┘
```

### Proposed Handler Pattern

```zig
// zevm/src/handlers.zig or similar
const std = @import("std");
const jsonrpc = @import("voltaire").jsonrpc;
const blockchain = @import("voltaire").blockchain;

pub const Provider = struct {
    chain_id: u64,
    blockchain: *blockchain.Blockchain.Blockchain,
    
    // No stored allocator (per style guide)
};

/// Handler for eth_chainId
pub fn chainId(provider: *const Provider) jsonrpc.eth.eth_chainId.Result {
    // Convert u64 chain_id to Quantity type
    return .{ .value = .{ .value = .{ .integer = provider.chain_id } } };
}

/// Handler for eth_blockNumber  
pub fn blockNumber(provider: *const Provider) !jsonrpc.eth.eth_blockNumber.Result {
    const head_number = provider.blockchain.getHeadBlockNumber() orelse 0;
    return .{ .value = .{ .value = .{ .integer = head_number } } };
}
```

### Style Compliance

Per CLAUDE.md:
- ✅ No local type aliases - use `@import("voltaire").jsonrpc.eth.eth_chainId.Params`
- ✅ No stored allocators - pass explicitly where needed (not needed here)
- ✅ Minimal abstractions - direct delegation to voltaire types

---

## Test Strategy

### Unit Tests (to add in zevm)

```zig
test "eth_chainId returns configured chain ID" {
    const provider = Provider{ .chain_id = 1337, .blockchain = ... };
    const result = handlers.chainId(&provider);
    // Verify result contains 0x539 (1337 in hex)
}

test "eth_blockNumber returns head block number" {
    // Setup blockchain with known head
    // Call blockNumber handler
    // Verify returns correct hex quantity
}
```

### Integration Tests (from reference implementations)

From `hive/simulators/ethereum/rpc-compat/` - can add RPC compatibility tests once HTTP server is implemented.

From `../tevm-monorepo/packages/actions/src/eth/chainIdHandler.spec.ts`:
```typescript
// Tests to port:
- should return the chain ID
- should match the configured network
```

---

## Files to Create/Modify

### New Files
- `src/handlers.zig` or `src/rpc/handlers.zig` - Core handler implementations
- `src/provider.zig` - Provider struct holding dependencies

### Modified Files
- `src/root.zig` - Export new modules
- `src/main.zig` - Wire up handlers (future: HTTP server)

### Dependencies (Already Available)
- `@import("voltaire").jsonrpc.eth.eth_chainId` - Types
- `@import("voltaire").jsonrpc.eth.eth_blockNumber` - Types
- `@import("voltaire").blockchain.Blockchain` - Block storage

---

## Open Questions

1. **Chain ID Source**: Should chain_id be:
   - Hardcoded in config?
   - Passed via CLI argument?
   - Retrieved from genesis block?

2. **BlockNumber on Empty Chain**: Should return:
   - 0 (genesis)?
   - Error?
   - null?
   - Foundry/Anvil returns 0 for empty chain

3. **Async**: Both handlers are synchronous (no I/O), so no async needed.

---

## Summary

| Method | Params | Result Source | Voltaire Type |
|--------|--------|---------------|---------------|
| eth_chainId | None | Provider.chain_id | `jsonrpc.eth.eth_chainId` |
| eth_blockNumber | None | Blockchain.getHeadBlockNumber() | `jsonrpc.eth.eth_blockNumber` |

**Key Insight**: These are the simplest possible handlers - pure data accessors with no complex logic. Perfect for establishing the handler pattern before implementing state-dependent methods like `eth_getBalance`.

**Next Steps After This Ticket**:
- Implement HTTP JSON-RPC server wrapper
- Add remaining read methods (eth_getBalance, eth_getCode, etc.)
- Add eth_call with EVM integration
