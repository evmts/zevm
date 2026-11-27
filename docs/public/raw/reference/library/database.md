`zevm.database` combines journaled account state with account and contract-code stores used by block execution. Reach for it when embedding ZEVM execution and you need owned in-memory state or a Merkle account root.

## Working example

This complete Zig program was run with the repository exposed as the `zevm` build module.

```zig
const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var db = try zevm.database.Database.init(allocator, null);
    defer db.deinit(allocator);

    if (db.accounts.stateRoot() != null) return error.ExpectedEmptyDatabase;
    std.debug.print("state_root=null\n", .{});
}
```

```bash
zig build run-database
```

```text
state_root=null
```

## API

The public declarations come from [`database/root.zig`](https://github.com/evmts/zevm/blob/main/src/database/root.zig), [`database.zig`](https://github.com/evmts/zevm/blob/main/src/database/database.zig), [`accounts.zig`](https://github.com/evmts/zevm/blob/main/src/database/accounts.zig), and [`contracts.zig`](https://github.com/evmts/zevm/blob/main/src/database/contracts.zig).

| Type | Members |
| --- | --- |
| `Database` | `init`, `deinit`, `syncAccountToTrie`, `syncCachedAccountsToTrie`, plus `state`, `accounts`, and `contracts` |
| `Accounts` | `init`, `deinit`, `get`, `put`, `remove`, `stateRoot` |
| `Contracts` | `init`, `deinit`, `get`, `put`, `remove` |

`StateManager` is the account-state source of truth. Call a sync method before reading the account trie root after state mutations.

## Neighbours

[Execution library](./execution-library) · [Genesis and chain import](./genesis-and-chain-import) · [State, fork, and snapshots](../../concepts/state-fork-and-snapshots)
