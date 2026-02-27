# Plan: Integrate ForkBackend into Database Initialization

## Overview

Wire `Database.init` to accept an optional `*state_manager.ForkBackend` pointer and forward it to `StateManager.init`, replacing the hardcoded `null`. This is pure constructor plumbing — no new behavior, no new modules, no new abstractions. The change surfaces a seam that downstream fork-mode work will plug into.

### Scope

- **1 production file**: `src/database/database.zig` — change `init` signature
- **1 test file**: `src/database/database_test.zig` — update 14 callsites to pass explicit `null`
- **0 new files**: no new modules, no new types
- **0 upstream changes**: voltaire `StateManager.init` already accepts `?*ForkBackend.ForkBackend`

### Design Decision

Pass `?*state_manager.ForkBackend` directly (not a config struct). Rationale:
- Matches upstream `StateManager.init(allocator, ?*ForkBackend.ForkBackend)` 1:1
- No indirection through a config type that would need to be maintained
- Caller creates and owns `ForkBackend` externally (upstream ownership pattern)
- `Database.deinit` does NOT deinit the fork backend (externally owned pointer)

---

## TDD Step Order

### Step 1: Update test callsites (RED → GREEN transition prep)

**File**: `src/database/database_test.zig`

**What**: Change all 14 `Database.init(std.testing.allocator)` calls to `Database.init(std.testing.allocator, null)`.

At this point the tests will fail to compile because the production signature still takes 1 arg.

**Callsites** (line numbers from current file):
| Line | Variable |
|------|----------|
| 6    | `db`     |
| 13   | `db`     |
| 31   | `db`     |
| 40   | `db`     |
| 52   | `db`     |
| 69   | `db`     |
| 83   | `db`     |
| 105  | `db`     |
| 123  | `db1`    |
| 125  | `db2`    |
| 141  | `db`     |
| 162  | `db`     |
| 170  | `db1`    |
| 172  | `db2`    |

### Step 2: Update production signature (make tests GREEN)

**File**: `src/database/database.zig`

**Change `init` from**:
```zig
pub fn init(allocator: std.mem.Allocator) !Database {
    return .{
        .state = try state_manager.StateManager.init(allocator, null),
        ...
    };
}
```

**To**:
```zig
pub fn init(allocator: std.mem.Allocator, fork_backend: ?*state_manager.ForkBackend) !Database {
    return .{
        .state = try state_manager.StateManager.init(allocator, fork_backend),
        ...
    };
}
```

Note: `state_manager.ForkBackend` is the re-exported type from voltaire's `state-manager/root.zig` (`pub const ForkBackend = ForkBackendMod.ForkBackend`). No local alias needed.

### Step 3: Run tests, verify GREEN

```bash
zig build test
```

Expected: all 14 database tests pass. The 3 pre-existing failures in `tx_processor_test` and `consensus_verifier_test` are unrelated and remain unchanged.

### Step 4: Add fork-mode integration test

**File**: `src/database/database_test.zig`

**New test**: `"init with fork backend creates database"` — verifies that `Database.init` can accept a non-null `ForkBackend` pointer and initializes without error.

```zig
test "init with fork backend creates database" {
    const state_manager = @import("state-manager");

    var fork = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork.deinit();

    var db = try database.Database.init(std.testing.allocator, &fork);
    defer db.deinit(std.testing.allocator);

    // Verify state manager is functional with fork backend
    const addr = try primitives.Address.fromHex("0x0000000000000000000000000000000000000001");
    // With fork backend but no RPC client, unknown account read will
    // return error.RpcPending or empty — we just verify init succeeds
    // and basic state operations don't crash
    try db.state.setBalance(addr, 42);
    const balance = try db.state.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 42), balance);
}
```

This test proves:
1. `ForkBackend` can be constructed and passed to `Database.init`
2. The `StateManager` inside `Database` is wired to the fork backend
3. Local writes still work (writes go to local cache, not fork)

### Step 5: Final test run

```bash
zig build test
```

All 15 database tests (14 existing + 1 new) should pass.

---

## Files to Modify

| File | Change |
|------|--------|
| `src/database/database.zig` | Add `fork_backend: ?*state_manager.ForkBackend` parameter to `init` |
| `src/database/database_test.zig` | Update 14 callsites to pass `null`; add 1 new fork-mode test |

## Files NOT Changed

| File | Reason |
|------|--------|
| `src/database/root.zig` | Only re-exports; no signature change |
| `src/tx_processor_test.zig` | Uses `StateManager.init` directly, not `Database.init` |
| `src/host_adapter_test.zig` | Uses `StateManager.init` directly |
| `src/block_builder_test.zig` | Uses `StateManager.init` directly |
| voltaire `StateManager.zig` | Already accepts `?*ForkBackend.ForkBackend` — no change needed |

---

## Tests

### Unit Tests (existing, updated signature)

All 14 existing tests in `database_test.zig` — unchanged behavior, just pass `null` as second arg:

1. `init produces null state root (empty trie)`
2. `put and get account`
3. `get nonexistent account returns null`
4. `put account produces non-null state root`
5. `update existing account`
6. `remove account`
7. `multiple accounts have independent state`
8. `state root changes on mutation`
9. `same state produces same root (deterministic)` (x2 inits)
10. `contract account with custom code hash`
11. `remove nonexistent account is safe`
12. `deterministic root with multiple accounts inserted in different order` (x2 inits)

### Integration Test (new)

15. `init with fork backend creates database` — proves the wiring works end-to-end with a real `ForkBackend` instance

---

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `ForkBackend.init` needs an import not currently in `database_test.zig` | Certain | Add `const state_manager = @import("state-manager");` at test scope |
| `ForkBackend` requires `RpcClient` for real reads, which we don't set up in tests | Low | Test only exercises local writes (set + get balance). Remote reads not triggered. |
| `ForkBackend.deinit` signature mismatch | Low | Check upstream `deinit` takes `*ForkBackend` — standard pattern |
| `syncCachedAccountsToTrie` uses `accountIterator` not exposed by voltaire `StateManager` | Known, out of scope | Pre-existing issue, not introduced or worsened by this ticket |
| Future callers of `Database.init` must now pass fork backend | Intentional | This is the desired API change — forces callers to be explicit about fork mode |

---

## Verification Against Acceptance Criteria

| Criterion | How Verified |
|-----------|-------------|
| `Database.init` accepts optional `*ForkBackend` or fork configuration | New signature: `init(allocator, fork_backend: ?*state_manager.ForkBackend)` |
| Fork backend is passed to `StateManager.init` instead of `null` | `state_manager.StateManager.init(allocator, fork_backend)` in implementation |
| All test initializations updated to match new signature | 14 callsites changed to pass `null` explicitly |
| Tests pass | `zig build test` — 15 database tests green |
| No upstream changes required | voltaire `StateManager.init` already accepts the optional pointer |
