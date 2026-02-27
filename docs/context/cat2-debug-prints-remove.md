# Research: cat2-debug-prints-remove

**Ticket:** Remove 9 debug print statements from JournaledState.getAccount in voltaire  
**Category:** cat-2-eth-read  
**Upstream Dependency:** voltaire (../voltaire)

---

## Problem Statement

`JournaledState.getAccount` in voltaire contains 9 `std.debug.print` statements that fire on every account read. These produce ~9 lines of stderr per account lookup, making the server output unreadable and unsuitable for production use.

---

## Location of Debug Prints

**File:** `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig`  
**Function:** `getAccount` (lines 79-105)  
**Lines:** 80-104 (9 debug print statements)

### The 9 Debug Print Statements

```zig
/// Get account (normal cache → fork backend → default)
pub fn getAccount(self: *JournaledState, address: Address) !StateCache.AccountState {
    std.debug.print("DEBUG: JournaledState.getAccount called\n", .{});                          // Line 80
    std.debug.print("DEBUG: address bytes[0..4]={any}\n", .{address.bytes[0..4]});             // Line 81

    // Check normal cache first
    std.debug.print("DEBUG: checking normal cache...\n", .{});                                 // Line 84
    if (self.account_cache.get(address)) |account| {
        std.debug.print("DEBUG: found in normal cache\n", .{});                               // Line 86
        return account;
    }

    // Check fork backend
    std.debug.print("DEBUG: checking fork_backend...\n", .{});                                 // Line 91
    if (self.fork_backend) |fork| {
        std.debug.print("DEBUG: fork_backend exists, calling fork.fetchAccount\n", .{});      // Line 93
        std.debug.print("DEBUG: fork={*}\n", .{fork});                                         // Line 94
        const account = try fork.fetchAccount(address);
        std.debug.print("DEBUG: fork.fetchAccount returned\n", .{});                          // Line 96
        // Cache in normal cache for future reads
        try self.account_cache.put(address, account);
        return account;
    }

    // Return empty account if no fork
    std.debug.print("DEBUG: no fork backend, returning empty account\n", .{});                // Line 103
    return StateCache.AccountState.init();
}
```

---

## Impact Analysis

### Why This Matters

1. **Performance Impact:** Every account read triggers 9 debug prints
2. **Log Spam:** In a typical EVM execution, thousands of account reads occur, producing overwhelming stderr output
3. **Production Blocker:** Cannot run a server with this level of debug output
4. **Violation of Project Standards:** The voltaire CONTRIBUTING.md explicitly states: "NO `std.debug.print` in library code (this is a library, not an app)"

### Usage Context

The `getAccount` function is called by:
- `StateManager.getBalance()` - line 66
- `StateManager.getNonce()` - line 71
- `StateManager.setBalance()` - line 85
- `StateManager.setNonce()` - line 91

All state accessor/mutator methods in StateManager go through `JournaledState.getAccount`, making this a hot path.

---

## Solution

### Simple Removal

Since voltaire is a library (not an application), debug prints should not be present in library code. The fix is straightforward:

**Remove lines 80-81, 84, 86, 91, 93-94, 96, and 103** (the debug print statements only, not the logic).

### Preserving Logic

The actual logic flow should remain unchanged:
1. Check normal cache first
2. If miss and fork_backend present, fetch from remote and cache
3. Otherwise return default empty account

---

## Related Files (for context)

| File | Purpose |
|------|---------|
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig` | Main file with debug prints |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/StateCache.zig` | Account/Storage/Contract caches with checkpointing |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/ForkBackend.zig` | Remote state fetching via RPC |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` | Public API that calls JournaledState |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/root.zig` | Module re-exports |

---

## Testing

After removal, run voltaire tests to ensure functionality is preserved:

```bash
cd ../voltaire/packages/voltaire-zig
zig build test
```

Specific tests for JournaledState:
- `test "JournaledState - basic operations without fork"`
- `test "JournaledState - checkpoint and revert"`
- `test "JournaledState - checkpoint and commit"`
- `test "JournaledState - default values without fork"`
- `test "JournaledState - nested checkpoints"`

---

## Implementation Notes

1. **Upstream Fix:** Since we own voltaire, fix this in the upstream repo, not in zevm
2. **No Tests Needed:** This is a cleanup task - no behavior change, just removing debug output
3. **Style Compliance:** Removing these prints aligns with voltaire's CONTRIBUTING.md guidelines

---

## References

- **voltaire CONTRIBUTING.md line 55:** "NO `std.debug.print` in library code (this is a library, not an app)"
- **JournaledState.getAccount:** Lines 80-104 in `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig`
