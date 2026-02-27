# Plan: fix-account-iterator-missing

## Overview

`Database.syncCachedAccountsToTrie()` calls `self.state.accountIterator()` but `StateManager` in voltaire has no such method. The fix adds `accountIterator()` to `StateManager` in voltaire, delegating to `self.journaled_state.account_cache.cache.iterator()`. This is a 1-line method that unblocks state root computation after block execution.

## Approach

**Option A (short-term, this ticket):** Add `accountIterator()` to `StateManager` that returns the underlying `std.AutoHashMap` iterator. This matches Foundry's iterate-all-accounts pattern, which is acceptable for a dev node.

**Option B (future optimization):** Track dirty addresses during block execution and only sync those. Deferred — not in scope for this ticket.

## TDD Step Order

### Step 1: Write test in voltaire for `accountIterator()`

**File:** `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`

Add a test at the bottom of the file:

```zig
test "StateManager - accountIterator returns cached accounts" {
    const allocator = std.testing.allocator;
    var manager = try StateManager.init(allocator, null);
    defer manager.deinit();

    const addr1 = Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 };
    const addr2 = Address{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 };

    try manager.setBalance(addr1, 1000);
    try manager.setBalance(addr2, 2000);

    var it = manager.accountIterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
```

This test will fail because `accountIterator()` doesn't exist yet.

### Step 2: Implement `accountIterator()` on `StateManager`

**File:** `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`

Add method to `StateManager` struct:

```zig
pub fn accountIterator(self: *StateManager) std.AutoHashMap(Address, StateCache.AccountState).Iterator {
    return self.journaled_state.account_cache.cache.iterator();
}
```

- Returns `std.AutoHashMap(Address, StateCache.AccountState).Iterator`
- Accesses `account_cache.cache` directly (it's a public field on `JournaledState`)
- No new imports needed — `StateCache` is already imported

### Step 3: Verify voltaire tests pass

```bash
cd ../voltaire && zig build test
```

### Step 4: Write integration test in zevm for `syncCachedAccountsToTrie`

**File:** `src/database/database_test.zig`

Add test:

```zig
test "syncCachedAccountsToTrie flushes all accounts to trie" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    const addr1 = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const addr2 = try primitives.Address.fromHex("0x70997970c51812dc3a010c7d01b50e0d17dc79c8");

    try db.state.setBalance(addr1, 1000);
    try db.state.setBalance(addr2, 2000);

    try db.syncCachedAccountsToTrie(std.testing.allocator);

    // Both accounts should now be in the trie
    const r1 = try db.accounts.get(std.testing.allocator, addr1);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqual(@as(u256, 1000), r1.?.balance);

    const r2 = try db.accounts.get(std.testing.allocator, addr2);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqual(@as(u256, 2000), r2.?.balance);

    // State root should be non-null after sync
    try std.testing.expect(db.accounts.stateRoot() != null);
}
```

### Step 5: Verify zevm tests pass

```bash
zig build test
```

## Files to Modify

| File | Change |
|------|--------|
| `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` | Add `accountIterator()` method + test |
| `src/database/database_test.zig` | Add integration test for `syncCachedAccountsToTrie` |

## Files NOT Modified

- `src/database/database.zig` — `syncCachedAccountsToTrie` already has the correct call site; it just needs the upstream method to exist
- `JournaledState.zig` — `account_cache` is already a public field, no change needed
- `StateCache.zig` — `cache` is already a public field on `AccountCache`, no change needed
- `root.zig` — No new types to re-export (iterator type is inferred from `accountIterator()` return)

## Function Signatures

```zig
// In StateManager (voltaire)
pub fn accountIterator(self: *StateManager) std.AutoHashMap(Address, StateCache.AccountState).Iterator
```

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Iterator invalidated by concurrent mutation | Not an issue — dev node is single-threaded; iterator is consumed immediately in `syncCachedAccountsToTrie` |
| Iterating ALL accounts (including fork-fetched unchanged ones) is wasteful | Acceptable for dev node (matches Foundry pattern). Future dirty-tracking optimization is a separate ticket |
| `StateManager` style violation — voltaire uses `Address` alias | Voltaire's `StateManager.zig` already uses `const Address = primitives.Address` at the top. This is voltaire's convention, not zevm's. Follow voltaire's existing style |

## Verification Against Acceptance Criteria

1. **`accountIterator()` exists on StateManager** — Step 2 adds it
2. **`Database.syncCachedAccountsToTrie()` compiles and works** — Step 4 test proves it
3. **State root computation unblocked** — Test verifies `stateRoot() != null` after sync
4. **All existing tests continue to pass** — Steps 3 and 5 verify no regressions
