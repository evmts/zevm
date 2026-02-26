# RPC-1: Import jsonrpc module from voltaire in build.zig

## Overview

Wire up voltaire's existing `jsonrpc` module (65 Ethereum JSON-RPC method types across `eth/`, `debug/`, `engine/` namespaces) so zevm source files can `@import("jsonrpc")`. This requires two changes:

1. **Export** the module from `../voltaire/build.zig` (it exists as source but is not yet a named module)
2. **Import** it in `zevm/build.zig` and add it to the zevm module's imports

The jsonrpc module is self-contained — only `std` and relative imports, no `primitives` or `crypto` dependencies.

---

## TDD Step Order

### Step 1 — Write a compile-time smoke test (TEST FIRST)

**File to create:** `src/jsonrpc_import_test.zig`

Write a test that will fail until the build wiring is complete. The test verifies:
- `@import("jsonrpc")` resolves without error
- Key public types are accessible: `JsonRpcMethod`, `eth.EthMethod`, `debug.DebugMethod`, `engine.EngineMethod`
- `eth.EthMethod.fromMethodName("eth_chainId")` returns `.eth_chainId`
- `types.Address`, `types.Hash`, `types.Quantity`, `types.BlockTag`, `types.BlockSpec` are accessible

```zig
// src/jsonrpc_import_test.zig
const std = @import("std");
const jsonrpc = @import("jsonrpc");

test "jsonrpc module is importable" {
    // Verify top-level namespace access compiles
    _ = jsonrpc.JsonRpcMethod;
    _ = jsonrpc.eth;
    _ = jsonrpc.debug;
    _ = jsonrpc.engine;
    _ = jsonrpc.types;
}

test "eth namespace has expected method count" {
    // EthMethod union should have 41 variants — verify a few key ones compile
    _ = jsonrpc.eth.EthMethod.eth_chainId;
    _ = jsonrpc.eth.EthMethod.eth_blockNumber;
    _ = jsonrpc.eth.EthMethod.eth_getBalance;
    _ = jsonrpc.eth.EthMethod.eth_sendRawTransaction;
    _ = jsonrpc.eth.EthMethod.eth_call;
}

test "EthMethod.fromMethodName resolves known method" {
    const tag = try jsonrpc.eth.EthMethod.fromMethodName("eth_chainId");
    try std.testing.expectEqual(.eth_chainId, tag);
}

test "EthMethod.fromMethodName errors on unknown method" {
    const result = jsonrpc.eth.EthMethod.fromMethodName("eth_bogus");
    try std.testing.expectError(error.UnknownMethod, result);
}

test "debug namespace accessible" {
    _ = jsonrpc.debug.DebugMethod;
}

test "engine namespace accessible" {
    _ = jsonrpc.engine.EngineMethod;
}

test "shared types accessible" {
    _ = jsonrpc.types.Address;
    _ = jsonrpc.types.Hash;
    _ = jsonrpc.types.Quantity;
    _ = jsonrpc.types.BlockTag;
    _ = jsonrpc.types.BlockSpec;
}
```

Add the test file to `src/root.zig`:
```zig
_ = @import("jsonrpc_import_test.zig");
```

At this point `zig build test` **fails** (expected — `@import("jsonrpc")` is not yet wired).

---

### Step 2 — Export jsonrpc module from voltaire's build.zig (IMPLEMENTATION)

**File to modify:** `../voltaire/build.zig`

After `primitives_mod` is declared (around line 74), add:

```zig
// JSON-RPC module — Ethereum JSON-RPC type system (65 methods, self-contained)
const jsonrpc_mod = b.addModule("jsonrpc", .{
    .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

No `addImport` calls needed — the module is self-contained (only `std` + relative imports).

---

### Step 3 — Import jsonrpc module in zevm's build.zig (IMPLEMENTATION)

**File to modify:** `zevm/build.zig`

**Change A:** After `precompiles_mod` import (line 16), add:
```zig
const jsonrpc_mod = voltaire.module("jsonrpc");
```

**Change B:** Add to the zevm module imports array:
```zig
.{ .name = "jsonrpc", .module = jsonrpc_mod },
```

The final `mod` declaration becomes:
```zig
const mod = b.addModule("zevm", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .imports = &.{
        .{ .name = "primitives", .module = primitives_mod },
        .{ .name = "state-manager", .module = state_manager_mod },
        .{ .name = "blockchain", .module = blockchain_mod },
        .{ .name = "crypto", .module = crypto_mod },
        .{ .name = "precompiles", .module = precompiles_mod },
        .{ .name = "guillotine_mini", .module = guillotine_mini_mod },
        .{ .name = "jsonrpc", .module = jsonrpc_mod },
    },
});
```

---

### Step 4 — Run tests and verify (VERIFY)

```
zig build test
```

All previously passing tests must still pass. The new `jsonrpc_import_test.zig` tests must now pass.

---

## Files to Create/Modify

| File | Action | Change |
|------|--------|--------|
| `../voltaire/build.zig` | **Modify** | Add `jsonrpc_mod` module export after `primitives_mod` |
| `zevm/build.zig` | **Modify** | Add `jsonrpc_mod` import + add to zevm module imports |
| `zevm/src/jsonrpc_import_test.zig` | **Create** | 7 compile-time + runtime tests for module accessibility |
| `zevm/src/root.zig` | **Modify** | Add `_ = @import("jsonrpc_import_test.zig");` to test block |

---

## Tests

### Unit tests (in `jsonrpc_import_test.zig`)

| Test name | What it verifies |
|-----------|-----------------|
| `jsonrpc module is importable` | Top-level namespaces compile (`JsonRpcMethod`, `eth`, `debug`, `engine`, `types`) |
| `eth namespace has expected method count` | Key EthMethod variants are accessible |
| `EthMethod.fromMethodName resolves known method` | `"eth_chainId"` → `.eth_chainId` |
| `EthMethod.fromMethodName errors on unknown method` | Unknown method → `error.UnknownMethod` |
| `debug namespace accessible` | `DebugMethod` union accessible |
| `engine namespace accessible` | `EngineMethod` union accessible |
| `shared types accessible` | All 5 shared types reachable via `jsonrpc.types.*` |

### Regression tests (already exist, must remain passing)

- `tx_processor_test.zig`
- `host_adapter_test.zig`
- `block_builder_test.zig`
- `consensus_verifier_test.zig`
- `beacon_api_test.zig`
- `consensus_sync_test.zig`
- `checkpoint_test.zig`
- `database_test.zig`

---

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| jsonrpc source files have undiscovered `@import("primitives")` calls | Low | Context doc confirmed self-contained; if discovered, add `primitives_mod.addImport` to voltaire's jsonrpc_mod |
| guillotine-mini's jsonrpc wiring (passes `primitives`+`crypto`) causes type mismatch | Low | zevm will use voltaire's module directly; guillotine-mini's wiring is separate and independent |
| voltaire build.zig has strict ordering requirements | Low | `jsonrpc_mod` has no deps so can be declared at any point after `b.addModule` setup |
| `zig build test` in voltaire repo breaks | Very low | Adding a new `b.addModule` is additive; no existing test steps reference it |

---

## Acceptance Criteria Verification

| Criterion | How verified |
|-----------|-------------|
| zevm can `@import("jsonrpc")` | `jsonrpc_import_test.zig` compile-time test |
| voltaire exports `jsonrpc` as named module | `voltaire.module("jsonrpc")` call in zevm/build.zig succeeds |
| All 65 method namespaces reachable | `eth`, `debug`, `engine` namespace tests |
| No regressions | `zig build test` passes all existing tests |
| Zig style rules followed | No local type aliases, no stored allocators, fully qualified paths |
