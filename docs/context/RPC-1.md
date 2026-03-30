# RPC-1: Import jsonrpc module from voltaire in build.zig

> Archival snapshot note: this file is a point-in-time research artifact, not the active ZEVM contract. Module export status, file paths, and line-count observations below reflect the capture-time workspace and may be stale.

## Ticket Summary

**Title:** Import jsonrpc module from voltaire in build.zig
**Category:** architectureAlignment
**Goal:** Update `zevm/build.zig` to expose the `jsonrpc` module from the voltaire dependency so zevm source files can `@import("jsonrpc")` to reuse voltaire's complete JSON-RPC type system.

---

## Key Finding: voltaire does NOT yet export a `jsonrpc` module

After reading voltaire's `build.zig` fully (1597 lines), **there is no `b.addModule("jsonrpc", ...)` call**. Voltaire currently exports only these 5 named modules:

| Module name      | Root source file |
|------------------|-----------------|
| `primitives`     | `packages/voltaire-zig/src/primitives/root.zig` |
| `crypto`         | `packages/voltaire-zig/src/crypto/root.zig` |
| `precompiles`    | `packages/voltaire-zig/src/evm/precompiles/root.zig` |
| `state-manager`  | `packages/voltaire-zig/src/state-manager/root.zig` |
| `blockchain`     | `packages/voltaire-zig/src/blockchain/root.zig` |

**The `jsonrpc` module exists as source code** at `packages/voltaire-zig/src/jsonrpc/root.zig` but is not wired up as an exported module in voltaire's build.

---

## What Needs to Be Done (Two Steps)

### Step 1 — Add `jsonrpc` module export to voltaire's `build.zig`

In `../voltaire/build.zig`, add (after `primitives_mod` is defined):

```zig
// JSON-RPC module - Ethereum JSON-RPC type system (65 methods)
const jsonrpc_mod = b.addModule("jsonrpc", .{
    .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
    .target = target,
    .optimize = optimize,
});
// jsonrpc types.zig uses hand-written types (Address, Hash, Quantity, BlockTag, BlockSpec)
// that are self-contained — no import of primitives or crypto is needed
```

**Dependency analysis of jsonrpc module:**
- `root.zig` imports: `JsonRpc.zig`, `eth/methods.zig`, `debug/methods.zig`, `engine/methods.zig`, `types.zig`
- `types.zig` imports only local files: `types/Address.zig`, `types/Hash.zig`, etc.
- `eth/chainId/eth_chainId.zig` imports `../../types.zig` (relative) and `std`
- **No external `@import("primitives")` or `@import("crypto")` calls anywhere in jsonrpc/**

The jsonrpc module is **self-contained** — it only uses `std` and relative imports. It does **not** need `primitives` or `crypto` as imports. This simplifies the build wiring considerably.

### Step 2 — Import `jsonrpc` module in zevm's `build.zig`

In `zevm/build.zig`, after the existing voltaire module imports:

```zig
const jsonrpc_mod = voltaire.module("jsonrpc");
```

Then add it to the `zevm` module's imports:

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
        .{ .name = "jsonrpc", .module = jsonrpc_mod },  // ← ADD THIS
    },
});
```

---

## File Inventory

### zevm (this repo)

| File | Purpose |
|------|---------|
| `build.zig` | Build entry point — **MODIFY** to add jsonrpc import |
| `build.zig.zon` | Package manifest — declares `voltaire` path dep, no changes needed |
| `src/root.zig` | Module root — no jsonrpc references yet |
| `src/*.zig` | Source files — currently import `primitives`, `state-manager`, `guillotine_mini` |

### voltaire upstream (`../voltaire`)

| File | Purpose |
|------|---------|
| `build.zig` | **MODIFY** — add `jsonrpc` module export |
| `packages/voltaire-zig/src/jsonrpc/root.zig` | Module entry point — exports `JsonRpc`, `eth`, `debug`, `engine`, `types`, `JsonRpcMethod` |
| `packages/voltaire-zig/src/jsonrpc/JsonRpc.zig` | Root union: `JsonRpcMethod = union(enum) { engine, eth, debug }` |
| `packages/voltaire-zig/src/jsonrpc/types.zig` | Re-exports `Address`, `Hash`, `Quantity`, `BlockTag`, `BlockSpec` |
| `packages/voltaire-zig/src/jsonrpc/eth/methods.zig` | `EthMethod` union with 41 eth_ variants |
| `packages/voltaire-zig/src/jsonrpc/debug/methods.zig` | `DebugMethod` union with 5 debug_ variants |
| `packages/voltaire-zig/src/jsonrpc/engine/methods.zig` | `EngineMethod` union with 19 engine_ variants |

---

## voltaire jsonrpc Module Structure

```
jsonrpc/
├── root.zig          → pub const JsonRpc, eth, debug, engine, types, JsonRpcMethod
├── JsonRpc.zig       → JsonRpcMethod = union(enum) { engine, eth, debug }
├── types.zig         → Address, Hash, Quantity, BlockTag, BlockSpec (hand-written)
├── types/
│   ├── Address.zig
│   ├── Hash.zig
│   ├── Quantity.zig
│   ├── BlockTag.zig
│   └── BlockSpec.zig
├── eth/
│   ├── methods.zig   → EthMethod union (41 methods), methodName(), fromMethodName()
│   └── [method]/eth_[method].zig  (41 files, each with Params + Result + method const)
├── debug/
│   ├── methods.zig   → DebugMethod union (5 methods)
│   └── [method]/debug_[method].zig  (5 files)
└── engine/
    ├── methods.zig   → EngineMethod union (19 methods)
    └── [method]/engine_[method].zig  (19 files)
```

**Total: 65 JSON-RPC methods** (41 eth + 5 debug + 19 engine)

Each method file pattern:
```zig
pub const method = "eth_chainId";  // method name string constant
pub const Params = struct { ... };  // with jsonStringify + jsonParseFromValue
pub const Result = struct { ... };  // with jsonStringify + jsonParseFromValue
```

---

## Current zevm build.zig Module Imports

```zig
const voltaire = b.dependency("voltaire", .{ .target = target, .optimize = optimize });
const primitives_mod = voltaire.module("primitives");
const state_manager_mod = voltaire.module("state-manager");
const blockchain_mod = voltaire.module("blockchain");
const crypto_mod = voltaire.module("crypto");
const precompiles_mod = voltaire.module("precompiles");
// jsonrpc_mod = voltaire.module("jsonrpc");  ← MISSING
```

The `guillotine_mini` dependency is also present and creates its own module using `primitives_mod`. It does **not** yet use jsonrpc.

---

## guillotine-mini Reference (../bench/guillotine-mini)

The `guillotine-mini` build.zig (in `../bench/`) already has the pattern for how to wire jsonrpc:

```zig
const jsonrpc_mod = b.addModule("jsonrpc", .{
    .root_source_file = primitives_dep.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "primitives", .module = primitives_mod },
        .{ .name = "crypto", .module = crypto_mod },
    },
});
```

> **Note:** guillotine-mini passes `primitives` and `crypto` as imports. However, inspection of the jsonrpc source shows it does NOT `@import("primitives")` or `@import("crypto")` anywhere — those imports may be forward-looking/unnecessary. The jsonrpc module only uses `std` and relative imports internally. Voltaire's build should add it without those extra imports unless a future method file requires them.

---

## Implementation Plan

1. **In `../voltaire/build.zig`** — Add after `primitives_mod` is declared (around line 73):
   ```zig
   const jsonrpc_mod = b.addModule("jsonrpc", .{
       .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
       .target = target,
       .optimize = optimize,
   });
   ```

2. **In `zevm/build.zig`** — After line 16 (`const precompiles_mod = voltaire.module("precompiles");`):
   ```zig
   const jsonrpc_mod = voltaire.module("jsonrpc");
   ```
   Then add `.{ .name = "jsonrpc", .module = jsonrpc_mod }` to the `zevm` module imports.

3. **Verify** with `zig build test` that existing tests still pass (no regressions).

---

## Notes / Gotchas

- **voltaire's `build.zig` does not need to add jsonrpc tests** to the test step — the jsonrpc module is pure type definitions with no native library dependencies, so `std.testing.refAllDecls` in `root.zig` is sufficient.
- The `jsonrpc` module is **self-contained** (no external deps beyond `std`). No `primitives` or `crypto` imports are needed in the module declaration.
- After this ticket, zevm source files can do `const jsonrpc = @import("jsonrpc");` and use `jsonrpc.eth.EthMethod`, `jsonrpc.JsonRpcMethod`, etc.
- Downstream tickets (HTTP server, RPC dispatch) will depend on this module being available.
