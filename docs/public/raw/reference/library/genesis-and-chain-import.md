`zevm.genesis_alloc` loads genesis accounts and header fields, while `zevm.chain_import` decodes concatenated RLP blocks into canonical query history. Reach for them when bootstrapping a custom trusted chain or attaching prebuilt block history without executing the imported transactions.

## Working example

This program loads one funded genesis account and verifies its header timestamp.

```zig
const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var db = try zevm.database.Database.init(allocator, null);
    defer db.deinit(allocator);

    const json =
        \\{
        \\  "timestamp": "0x2a",
        \\  "gasLimit": "0x1c9c380",
        \\  "alloc": {
        \\    "0x1000000000000000000000000000000000000001": {
        \\      "balance": "0xde0b6b3a7640000"
        \\    }
        \\  }
        \\}
    ;
    var loaded = try zevm.genesis_alloc.loadGenesisJson(allocator, &db.state, json);
    defer loaded.deinit(allocator);

    if (loaded.account_count != 1) return error.WrongAccountCount;
    if (loaded.header.timestamp != 42) return error.WrongTimestamp;

    std.debug.print("accounts={d}\ntimestamp={d}\n", .{ loaded.account_count, loaded.header.timestamp });
}
```

```bash
zig build run-genesis
```

```text
accounts=1
timestamp=42
```

## API and CLI flags

The implementations are [`genesis_alloc.zig`](https://github.com/evmts/zevm/blob/main/src/genesis_alloc.zig), [`chain_import.zig`](https://github.com/evmts/zevm/blob/main/src/chain_import.zig), and [`cli.zig`](https://github.com/evmts/zevm/blob/main/src/cli.zig).

| Surface | API |
| --- | --- |
| Genesis types | `HeaderConfig`, `LoadedGenesis`, `Error` |
| Genesis loading | `loadGenesisFile`, `loadGenesisJson`, `loadGenesisValue` |
| Genesis application | `applyGenesisFile`, `applyGenesisJson`, `applyGenesisValue` |
| Chain types | `ImportStats`, `OwnedBlockBody`, `DecodedBlock` |
| Chain import | `importChainFile`, `importChainBytes`, `decodeNextBlock`, `cloneBlockBody`, `freeTransactions` |
| CLI | `--genesis <path>`, `--chain-rlp <path>` |

Imported RLP blocks become canonical query history. Phase 1 does not execute their transactions or materialize imported state, receipts, or logs.

## Neighbours

[Database](./database) · [Execution library](./execution-library) · [Trusted-mode configuration](../configuration/trusted-mode)
