# Context: implement-hardhat-impersonate-account-rpc

## Ticket Info
- **Ticket ID**: implement-hardhat-impersonate-account-rpc
- **Category**: cat-9-impersonation
- **Goal**: Create `src/rpc/hardhat_impersonate_account.zig` with handler that parses address param, calls `state_manager.impersonateAccount(address)`, returns `true`.

---

## Method Specification

**Method signature:**
```
hardhat_impersonateAccount(address: DATA, 20 bytes) → bool
```

- **Params:** Single-element array: `["0x<20-byte-hex>"]`
- **Returns:** Always `true` (bool)
- **Purpose:** Marks an address as "impersonated" so that `eth_sendTransaction` with that `from` address skips signature validation. The private key is NOT needed.

**EDR spec doc (from `edr/crates/edr_provider/src/requests/methods.rs` lines 1855–1887):**
> Enables sending of transactions on behalf of the provided address, even if the private key is not available. The impersonated account does not need to have any balance to send transactions. Always returns `true`.

---

## What Voltaire Already Provides

### JSON-RPC Types
**Location:** `../voltaire/packages/voltaire-zig/src/jsonrpc/`

The voltaire `jsonrpc` module has typed `Params`/`Result` structs for `eth_*`, `debug_*`, and `engine_*` namespaces BUT **does NOT have `hardhat_*` method types**. We need to define `Params` and `Result` for `hardhat_impersonateAccount` in the new handler file itself or in a new voltaire jsonrpc file.

**Relevant voltaire types for this ticket:**
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig` — 20-byte hex address with JSON serde (`jsonParseFromValue` + `jsonStringify`)
  ```zig
  pub const Address = struct {
      bytes: [20]u8,
      // Parses "0x..." 42-char hex string
      pub fn jsonParseFromValue(...) !Address { ... }
      pub fn jsonStringify(...) !void { ... }
  };
  ```

### StateManager
**Location:** `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`

The `StateManager` struct currently does NOT have an `impersonateAccount` method. According to the ticket, we need to add `state_manager.impersonateAccount(address)`.

**Required change to voltaire StateManager:** Add an `impersonatedAccounts` set and `impersonateAccount`/`stopImpersonatingAccount` methods to `StateManager.zig`.

The EDR pattern is:
```rust
// In ProviderData (Rust):
impersonated_accounts: HashSet<Address>,

pub fn impersonate_account(&mut self, address: Address) {
    self.impersonated_accounts.insert(address);
}

pub fn stop_impersonating_account(&mut self, address: Address) -> bool {
    self.impersonated_accounts.remove(&address)
}

// Used during transaction signing:
if self.impersonated_accounts.contains(&sender) {
    // fake_sign — bypass signature validation
}
```

**Required Zig equivalent to add to `StateManager.zig`:**
```zig
impersonated_accounts: std.AutoHashMap([20]u8, void),

pub fn impersonateAccount(self: *StateManager, allocator: std.mem.Allocator, address: primitives.Address) !void {
    try self.impersonated_accounts.put(address.bytes, {});
}

pub fn stopImpersonatingAccount(self: *StateManager, address: primitives.Address) bool {
    return self.impersonated_accounts.remove(address.bytes);
}

pub fn isImpersonated(self: *StateManager, address: primitives.Address) bool {
    return self.impersonated_accounts.contains(address.bytes);
}
```

Note: `impersonated_accounts` must be initialized in `StateManager.init` and freed in `StateManager.deinit`.

---

## Reference Implementations

### EDR (Hardhat Rust) — Primary Reference
**File:** `edr/crates/edr_provider/src/requests/hardhat/accounts.rs`

```rust
pub fn handle_impersonate_account_request<...>(
    data: &mut ProviderData<...>,
    address: Address,
) -> Result<bool, ...> {
    data.impersonate_account(address);
    Ok(true)
}
```

**Key pattern:**
1. Receive `address: Address`
2. Call `data.impersonate_account(address)` — inserts into `HashSet<Address>`
3. Return `Ok(true)` always

**EDR method dispatch** (`edr/crates/edr_provider/src/requests/methods.rs` lines 1880–1887):
```rust
#[serde(rename = "hardhat_impersonateAccount", with = "edr_eth::serde::sequence")]
ImpersonateAccount(
    /// `DATA, 20 bytes` - The address to impersonate.
    RpcAddress,
),
```
- Params are a single-element positional array: `["0xADDRESS"]`
- `RpcAddress` is a newtype around `Address` that accepts both checksummed and non-checksummed hex

### Hardhat TypeScript — Helper
**File:** `hardhat/v-next/hardhat-network-helpers/src/internal/network-helpers/helpers/impersonate-account.ts`

```typescript
export async function impersonateAccount(
  provider: EthereumProvider,
  address: string,
): Promise<void> {
  await assertValidAddress(address);
  await provider.request({
    method: "hardhat_impersonateAccount",
    params: [address],
  });
}
```

- Single address param
- No return value from caller's perspective (void/undefined)
- Provider itself returns `true` (not used by helper)

### Hardhat Test
**File:** `hardhat/v-next/hardhat-network-helpers/test/network-helpers/impersonate-account.ts`

Key test behavior:
1. `eth_sendTransaction` from un-impersonated address → **should fail** (unknown account/no private key)
2. Call `hardhat_impersonateAccount(address)` → returns `true`
3. `eth_sendTransaction` from same address → **should succeed** (signature bypassed)
4. Invalid address (e.g., `"0xaa"`) → should return error

---

## Voltaire jsonrpc Module — No `hardhat_*` types

The voltaire `jsonrpc` module covers:
- `eth/` — 41 methods (eth_getBalance, eth_call, etc.)
- `debug/` — 5 methods
- `engine/` — 19 methods

**`hardhat_*` methods do NOT exist in voltaire's jsonrpc module.** For this ticket, define inline `Params`/`Result` types inside `src/rpc/hardhat_impersonate_account.zig` following the same pattern as voltaire's method files.

---

## zevm Current State

### File Structure
```
src/
  main.zig              — stub (prints "zevm - Ethereum local node")
  root.zig              — exports: database, blockchain, host_adapter, tx_processor,
                          block_builder, consensus_verifier, beacon_api, consensus_sync, checkpoint
  host_adapter.zig      — bridges StateManager → guillotine-mini HostInterface
  tx_processor.zig      — transaction processing
  block_builder.zig     — block building
  ...
build.zig               — imports: primitives, state-manager, blockchain, crypto, precompiles, guillotine_mini
                          (jsonrpc module NOT yet imported — see RPC-1 context)
```

### No `src/rpc/` directory exists yet
The ticket creates `src/rpc/hardhat_impersonate_account.zig` — this is a **new directory and file**.

### Build System
The `zevm` module in `build.zig` imports:
- `primitives` — from voltaire
- `state-manager` — from voltaire (provides `StateManager`)
- `blockchain`, `crypto`, `precompiles` — from voltaire
- `guillotine_mini` — EVM interpreter

The `jsonrpc` module is NOT yet imported (tracked in ticket RPC-1 / `docs/context/RPC-1.md`). For this handler, we may need to import `jsonrpc` OR define local Params/Result inline.

---

## Implementation Plan

### Step 1: Add `impersonateAccount` to voltaire StateManager

In `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`:

```zig
pub const StateManager = struct {
    allocator: std.mem.Allocator,
    journaled_state: JournaledState.JournaledState,
    snapshot_counter: u64,
    snapshots: std.AutoHashMap(u64, usize),
    impersonated_accounts: std.AutoHashMap([20]u8, void),  // ADD THIS

    pub fn init(allocator: std.mem.Allocator, fork_backend: ?*ForkBackend.ForkBackend) !StateManager {
        return .{
            .allocator = allocator,
            .journaled_state = try JournaledState.JournaledState.init(allocator, fork_backend),
            .snapshot_counter = 0,
            .snapshots = std.AutoHashMap(u64, usize).init(allocator),
            .impersonated_accounts = std.AutoHashMap([20]u8, void).init(allocator),  // ADD THIS
        };
    }

    pub fn deinit(self: *StateManager) void {
        self.journaled_state.deinit();
        self.snapshots.deinit();
        self.impersonated_accounts.deinit();  // ADD THIS
    }

    // ADD THESE METHODS:
    pub fn impersonateAccount(self: *StateManager, address: Address) !void {
        try self.impersonated_accounts.put(address.bytes, {});
    }

    pub fn stopImpersonatingAccount(self: *StateManager, address: Address) bool {
        return self.impersonated_accounts.remove(address.bytes);
    }

    pub fn isImpersonated(self: *StateManager, address: Address) bool {
        return self.impersonated_accounts.contains(address.bytes);
    }
    // ... rest of existing methods unchanged
};
```

### Step 2: Create `src/rpc/hardhat_impersonate_account.zig`

```zig
const std = @import("std");
const state_manager = @import("state-manager");

/// The JSON-RPC method name
pub const method = "hardhat_impersonateAccount";

/// Params: positional array with one address
pub const Params = struct {
    address: [20]u8,

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Params {
        _ = options;
        _ = allocator;
        if (source != .array) return error.UnexpectedToken;
        if (source.array.items.len != 1) return error.InvalidParamCount;
        const addr_val = source.array.items[0];
        if (addr_val != .string) return error.InvalidAddress;
        const s = addr_val.string;
        if (s.len != 42 or s[0] != '0' or (s[1] != 'x' and s[1] != 'X'))
            return error.InvalidAddress;
        var out: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, s[2..]) catch return error.InvalidAddress;
        return Params{ .address = out };
    }
};

/// Result: always true
pub const Result = struct {
    value: bool,

    pub fn jsonStringify(self: Result, jws: anytype) !void {
        try jws.write(self.value);
    }
};

/// Handler: parse params, call state_manager.impersonateAccount, return true
pub fn handle(
    params: std.json.Value,
    sm: *state_manager.StateManager,
    allocator: std.mem.Allocator,
) !Result {
    const parsed = try Params.jsonParseFromValue(allocator, params, .{});
    const addr = @import("primitives").Address{ .bytes = parsed.address };
    try sm.impersonateAccount(addr);
    return Result{ .value = true };
}
```

### Step 3: Export from `src/root.zig`

Add to the rpc module exports (after creating `src/rpc/root.zig` or directly):
```zig
pub const hardhat_impersonate_account = @import("rpc/hardhat_impersonate_account.zig");
```

### Step 4: Wire into dispatch layer

When the HTTP JSON-RPC dispatch layer (from ticket `http-jsonrpc-server-and-dispatch`) is built, add a case for `"hardhat_impersonateAccount"` that calls `hardhat_impersonate_account.handle(params, state_manager, allocator)`.

---

## Key Files Summary

| File | Role | Action |
|------|------|--------|
| `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` | State manager — needs `impersonateAccount` method | **MODIFY** (upstream voltaire) |
| `src/rpc/hardhat_impersonate_account.zig` | Handler for `hardhat_impersonateAccount` | **CREATE** |
| `src/root.zig` | Module root | **MODIFY** to export new handler |
| `build.zig` | Build config | May need jsonrpc module if types imported from voltaire |
| `edr/crates/edr_provider/src/requests/hardhat/accounts.rs` | Reference impl | Read-only |
| `edr/crates/edr_provider/src/data.rs` | Reference: impersonated_accounts HashSet pattern | Read-only |
| `hardhat/v-next/hardhat-network-helpers/src/.../impersonate-account.ts` | Reference helper | Read-only |
| `hardhat/v-next/hardhat-network-helpers/test/.../impersonate-account.ts` | Reference test | Port to Zig test |

---

## voltaire jsonrpc Address Type vs primitives.Address

**Critical distinction:**
- `voltaire jsonrpc types.Address` (`../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig`): standalone type, JSON serde, `{ bytes: [20]u8 }`
- `primitives.Address` (`../voltaire/packages/voltaire-zig/src/primitives/`): the canonical address used by StateManager

Both have `bytes: [20]u8`. StateManager uses `primitives.Address`. When parsing from JSON in the handler, parse using the jsonrpc `Address.jsonParseFromValue` pattern and then construct a `primitives.Address{ .bytes = parsed.bytes }`.

---

## Test Pattern

From the Hardhat test, port these cases to Zig:

1. `hardhat_impersonateAccount("0x000000000000000000000000000000000000bEEF")` → `true`
2. After impersonating, `isImpersonated("0xbEEF")` → `true`
3. `hardhat_stopImpersonatingAccount("0xbEEF")` → `true`
4. After stopping, `isImpersonated("0xbEEF")` → `false`
5. Invalid address (too short, wrong prefix) → `error.InvalidAddress`

---

## Zig Style Notes (per CLAUDE.md)

- No local type aliases: use `state_manager.StateManager` not `const SM = state_manager.StateManager`
- No stored allocators: pass `allocator` to `impersonateAccount` if needed (but the HashMap.put() is the allocating call, and HashMap was initialized with allocator in `init`)
- Fully qualified paths inline everywhere
- `impersonated_accounts` field: use `std.AutoHashMap([20]u8, void)` keyed on the raw bytes (no struct comparison needed)
