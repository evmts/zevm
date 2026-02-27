# Plan: Implement eth_chainId and eth_blockNumber RPC Handlers

**Ticket:** implement-eth-chainid-blocknumber-handlers  
**Category:** cat-2-eth-read  
**Date:** 2026-02-26

---

## Overview

Implement handlers for `eth_chainId` and `eth_blockNumber` — the two simplest read-only JSON-RPC methods. These establish the foundational handler pattern for all subsequent RPC methods in zevm.

**Approach:** Handlers are pure functions that take a `Provider` struct and return raw `u64` values. JSON serialization into voltaire's `Quantity` / `Result` types will be handled by the RPC dispatch layer (separate ticket: cat-1-rpc-server). This mirrors the pattern in EDR (`Ok(U64::from(data.chain_id()))`) and Anvil (`Ok(U256::from(self.backend.best_number()))`).

**Key constraint:** The `jsonrpc` module from voltaire is **not yet imported** in zevm's `build.zig`. This ticket adds it so handler types are available for future dispatch integration.

---

## Dependencies (DO NOT REINVENT)

| What | Source | Status |
|------|--------|--------|
| `eth_chainId` Params/Result types | `voltaire` → `jsonrpc.eth.eth_chainId` | ✅ Exists |
| `eth_blockNumber` Params/Result types | `voltaire` → `jsonrpc.eth.eth_blockNumber` | ✅ Exists |
| `Quantity` type (hex QUANTITY) | `voltaire` → `jsonrpc.types.Quantity` | ✅ Exists |
| `Blockchain.getHeadBlockNumber()` | `voltaire` → `blockchain.Blockchain` | ✅ Exists |
| HTTP server / dispatch | N/A | ❌ Separate ticket |

---

## Architecture

```
Handler functions (zevm)          Upstream types (voltaire)
┌──────────────────────┐          ┌──────────────────────┐
│ eth_handler.zig      │          │ jsonrpc/             │
│  chainId(Provider)   │ ── u64 → │  eth_chainId.Result  │ (dispatch layer, future)
│  blockNumber(Provider│ ── u64 → │  eth_blockNumber.Res │
│                      │          │  types.Quantity      │
│ Provider struct:     │          ├──────────────────────┤
│  chain_id: u64       │          │ blockchain/          │
│  blockchain: *BC     │◀─────────│  Blockchain          │
└──────────────────────┘          │   .getHeadBlockNumber│
                                  └──────────────────────┘
```

---

## TDD Step Order

### Step 1: Write test file `src/rpc/eth_handler_test.zig`

Write failing tests FIRST for both handlers.

**Tests to write:**

```zig
// Test 1: eth_chainId returns configured chain ID
test "chainId returns configured chain ID" {
    // Create Provider with chain_id = 1 (mainnet)
    // Call chainId()
    // Assert result == 1
}

// Test 2: eth_chainId returns custom chain ID
test "chainId returns custom dev chain ID" {
    // Create Provider with chain_id = 1337 (hardhat default)
    // Call chainId()
    // Assert result == 1337
}

// Test 3: eth_blockNumber returns 0 for empty blockchain
test "blockNumber returns 0 for empty blockchain" {
    // Create Blockchain with no blocks
    // Create Provider
    // Call blockNumber()
    // Assert result == 0
}

// Test 4: eth_blockNumber returns head after adding blocks
test "blockNumber returns head block number" {
    // Create Blockchain, add genesis + block 1
    // Create Provider
    // Call blockNumber()
    // Assert result == 1
}

// Test 5: eth_blockNumber returns 0 when blockchain has no canonical head
test "blockNumber returns 0 when no canonical head" {
    // Create Blockchain without setting canonical head
    // Call blockNumber()
    // Assert result == 0 (fallback, matches Anvil behavior)
}
```

### Step 2: Create `src/rpc/eth_handler.zig` — Provider struct

```zig
const blockchain = @import("blockchain");

pub const Provider = struct {
    chain_id: u64,
    blockchain: *blockchain.Blockchain,
};
```

No stored allocator (per style guide). No local type aliases.

### Step 3: Implement `chainId` handler

```zig
pub fn chainId(provider: *const Provider) u64 {
    return provider.chain_id;
}
```

### Step 4: Implement `blockNumber` handler

```zig
pub fn blockNumber(provider: *const Provider) u64 {
    return provider.blockchain.getHeadBlockNumber() orelse 0;
}
```

### Step 5: Add `jsonrpc` module to `build.zig`

Add the voltaire `jsonrpc` module to zevm's module imports so it's available for the future dispatch layer.

```zig
// In build.zig, after existing voltaire module imports:
const jsonrpc_mod = voltaire.module("jsonrpc");

// Add to zevm module imports:
.{ .name = "jsonrpc", .module = jsonrpc_mod },
```

### Step 6: Wire up exports in `src/rpc/root.zig` and `src/root.zig`

Create `src/rpc/root.zig`:
```zig
pub const eth_handler = @import("eth_handler.zig");

test {
    _ = @import("eth_handler_test.zig");
}
```

Add to `src/root.zig`:
```zig
pub const rpc = @import("rpc/root.zig");
```

And add the test import.

### Step 7: Run tests, verify all pass

```bash
zig build test
```

All 5 new tests should pass. All existing tests should remain in their current state (no regressions).

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/rpc/eth_handler.zig` | Provider struct + chainId/blockNumber handlers |
| `src/rpc/eth_handler_test.zig` | Unit tests for both handlers |
| `src/rpc/root.zig` | RPC module exports |

## Files to Modify

| File | Change |
|------|--------|
| `build.zig` | Add `jsonrpc` module import from voltaire |
| `src/root.zig` | Add `rpc` module export + test import |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Blockchain requires blocks to be inserted with valid parent linkage | Use `BlockStore` directly in tests or create minimal genesis block with zero parent hash |
| `getHeadBlockNumber()` returns `null` for empty chains | Handler returns `0` as fallback (matches Anvil/Hardhat behavior for fresh chains) |
| `jsonrpc` module may have transitive dependencies not satisfied | Module is self-contained per voltaire's build.zig comment: "no import of primitives or crypto is needed" |
| Quantity construction from u64 needs allocation for hex string | Defer to dispatch layer — handlers return raw u64 |

---

## Verification Against Acceptance Criteria

1. **eth_chainId returns configured chain ID** → Test 1, 2 verify directly
2. **eth_blockNumber returns current canonical head** → Test 4, 5 verify with actual Blockchain
3. **Handler pattern established** → Provider struct + pure handler functions serve as template
4. **Voltaire types used, not reinvented** → jsonrpc module imported; handlers return u64 that dispatch layer wraps in voltaire Result types
5. **Zero parameters** → Handlers take only Provider reference, no params struct needed
6. **All existing tests still pass** → Step 7 verifies no regressions

---

## Implementation Notes

- **No JSON serialization in handlers.** Handlers return `u64`. The dispatch layer (cat-1-rpc-server ticket) will convert `u64` → `Quantity` → JSON response. This keeps handlers pure and testable without JSON parsing.
- **Provider is a value struct, not heap-allocated.** It holds a `u64` and a pointer — no ownership semantics needed.
- **Both handlers are synchronous.** No async, no allocation, no error returns (except potentially for blockNumber if we want to propagate blockchain errors, but `getHeadBlockNumber` is infallible).
