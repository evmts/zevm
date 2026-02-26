# RPC-2: Implement HTTP JSON-RPC Server

## Ticket Summary

**Title:** Implement HTTP JSON-RPC Server  
**Category:** specCompliance  
**Goal:** Create an HTTP server in zevm (e.g., `src/rpc_server.zig`) that parses incoming JSON-RPC requests, supports batch requests, and dispatches them to the appropriate handlers.

---

## Prerequisites

This ticket depends on **RPC-1** (Import jsonrpc module from voltaire in build.zig) which:
- Adds `jsonrpc` module export to voltaire's build.zig
- Imports `jsonrpc` module in zevm's build.zig

---

## What Already Exists

### Voltaire (upstream dependency)

**Location:** `../voltaire/packages/voltaire-zig/src/jsonrpc/`

| File | What it provides |
|------|-----------------|
| `root.zig` | Module entry point, re-exports all jsonrpc types |
| `JsonRpc.zig` | Root `JsonRpcMethod` union(enum) { engine, eth, debug } |
| `types.zig` | Shared types: `Address`, `Hash`, `Quantity`, `BlockTag`, `BlockSpec` |
| `eth/methods.zig` | `EthMethod` union with 41 eth_* methods, `fromMethodName()` for O(1) lookup |
| `debug/methods.zig` | `DebugMethod` union with 5 debug_* methods |
| `engine/methods.zig` | `EngineMethod` union with 19 engine_* methods |

**Each method file pattern** (e.g., `eth/chainId/eth_chainId.zig`):
```zig
pub const method = "eth_chainId";           // Method name constant
pub const Params = struct { ... };          // With jsonParseFromValue + jsonStringify
pub const Result = struct { ... };          // With jsonParseFromValue + jsonStringify
```

**Method lookup via StaticStringMap:**
```zig
const tag = try jsonrpc.eth.EthMethod.fromMethodName("eth_chainId");
// Returns enum tag: .eth_chainId
```

### ZEVM Current State

**Files:**
- `src/main.zig` — Stub that prints "zevm - Ethereum local node"
- `src/root.zig` — Exports: database, blockchain, host_adapter, tx_processor, block_builder, consensus_verifier, beacon_api, consensus_sync, checkpoint
- `build.zig` — Imports voltaire modules + guillotine_mini
- `build.zig.zon` — Declares voltaire and guillotine-mini dependencies

**No HTTP server or RPC handling currently exists in zevm.**

---

## What's Missing (Must Be Implemented)

### 1. JSON-RPC 2.0 Envelope Types

Voltaire has method types but **no transport envelope types**. These need to be added to voltaire's jsonrpc module (or defined in zevm if voltaire prefers):

```zig
/// JSON-RPC 2.0 Request envelope
pub const Request = struct {
    jsonrpc: []const u8,      // Must be "2.0"
    method: []const u8,
    params: ?std.json.Value,  // Array or object
    id: ?Id,                  // null for notifications
};

/// JSON-RPC 2.0 Response envelope
pub const Response = struct {
    jsonrpc: []const u8,
    result: ?std.json.Value,
    @"error": ?Error,
    id: ?Id,
};

/// JSON-RPC 2.0 Error object
pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value,
};

/// JSON-RPC 2.0 Request ID (string, number, or null)
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,
    null_value: void,
};
```

**Standard JSON-RPC 2.0 Error Codes:**
| Code | Name | Meaning |
|------|------|---------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid Request | JSON is not a valid Request object |
| -32601 | Method not found | Method does not exist |
| -32602 | Invalid params | Invalid method parameters |
| -32603 | Internal error | Internal JSON-RPC error |
| -32000 | Server error | Generic server error |
| -32001 | Resource not found | Requested resource not found |
| -32002 | Resource unavailable | Resource temporarily unavailable |

### 2. HTTP Server Infrastructure

Zig's `std.http.Server` provides:
- `Server.init(allocator, connection)` — Create server from TCP connection
- `server.receiveHead()` — Read HTTP request headers
- `server.nextRequest()` — Get next request for keep-alive
- Response via `try res.do()` + `try res.writeAll(body)` + `try res.finish()`

**Key patterns:**
```zig
const std = @import("std");
const jsonrpc = @import("jsonrpc");

pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RpcServer {
        const address = try std.net.Address.parseIp4(host, port);
        return .{ .allocator = allocator, .address = address };
    }

    pub fn listen(self: *RpcServer) !void {
        var tcp_server = try self.address.listen(.{});
        defer tcp_server.deinit();

        while (true) {
            const conn = try tcp_server.accept();
            try self.handleConnection(conn);
        }
    }
};
```

### 3. Request Parsing & Batch Detection

**Single vs Batch detection:**
```zig
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
defer parsed.deinit();

if (parsed.value == .array) {
    // Batch request: process each element
    for (parsed.value.array.items) |item| {
        // Process individual request
    }
} else if (parsed.value == .object) {
    // Single request
}
```

### 4. Method Dispatch

**Dispatch strategy:**
1. Extract `method` string from request
2. Try `jsonrpc.eth.EthMethod.fromMethodName(method_name)`
3. Try `jsonrpc.debug.DebugMethod.fromMethodName(method_name)`
4. Try `jsonrpc.engine.EngineMethod.fromMethodName(method_name)`
5. If all fail → return `-32601 Method not found`

**For RPC-2 (initial implementation):**
- Return `-32601 Method not found` for ALL recognized methods
- This allows running hive rpc-compat tests immediately
- Subsequent tickets add actual handler implementations

---

## Reference Implementations

### Foundry Anvil (Rust)

**Location:** `foundry/crates/anvil/server/src/`

Key files:
- `handler.rs` — HTTP request handling, single/batch routing
- `config.rs` — CLI args: `--port 8545`, `--host 127.0.0.1`

**Pattern:**
```rust
// Axum-based HTTP server
let app = Router::new()
    .route("/", post(handle_request))
    .layer(cors);

// Single/Batch discrimination
enum Request { Single(RpcCall), Batch(Vec<RpcCall>) }

// Two-stage dispatch:
// 1. Parse generic envelope -> extract method name
// 2. Deserialize params into typed EthRequest enum
```

### Hardhat EDR (Rust)

**Location:** `edr/crates/edr_provider/src/`

Key observations:
- EDR has NO HTTP server — it's a library called via FFI from Node.js
- The HTTP layer is external (Hardhat's Node.js HTTP server)
- Provider handles: `ProviderRequest::Single` | `ProviderRequest::Batch`
- Sequential batch processing for state consistency

### TEVM (TypeScript)

**Location:** `../tevm-monorepo/packages/actions/src/`

**Pattern:**
```typescript
// Hash map dispatch
const handlers: Record<string, Handler> = {
    'eth_chainId': handleChainId,
    'eth_blockNumber': handleBlockNumber,
    // ... 120+ methods
};

// Three-layer architecture:
// 1. Procedure — JSON-RPC adapter (hex conversion, envelope wrapping)
// 2. Handler — Business logic (StateManager/Blockchain)
// 3. Core — VM, StateManager, Blockchain
```

---

## Implementation Plan

### Step 1: Add envelope types to voltaire

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` (new)

Add `Request`, `Response`, `Error`, `Id` types and `ErrorCode` constants.
Export from `root.zig`.

### Step 2: Create rpc_server.zig in zevm

**File:** `src/rpc_server.zig`

```zig
const std = @import("std");
const jsonrpc = @import("jsonrpc");

pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RpcServer;
    pub fn listen(self: *RpcServer) !void;
    pub fn stop(self: *RpcServer) void;
};

// Request parsing
fn parseRequest(body: []const u8) !jsonrpc.envelope.Request;
fn isBatchRequest(body: []const u8) bool;

// Dispatch
fn dispatch(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.Response;
fn handleSingle(request: jsonrpc.envelope.Request) !jsonrpc.envelope.Response;
fn handleBatch(requests: []jsonrpc.envelope.Request) ![]jsonrpc.envelope.Response;

// Error helpers
fn errorResponse(code: i32, message: []const u8, id: ?jsonrpc.envelope.Id) jsonrpc.envelope.Response;
```

### Step 3: Add CLI args to main.zig

**File:** `src/main.zig`

```zig
const std = @import("std");
const RpcServer = @import("rpc_server.zig").RpcServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    const args = try parseArgs(allocator);
    
    // Start server
    var server = try RpcServer.init(allocator, args.host, args.port);
    try server.listen();
}

const Args = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8545,
    chain_id: u64 = 31337,
    fork_url: ?[]const u8 = null,
};
```

### Step 4: Export from root.zig

**File:** `src/root.zig`

```zig
pub const rpc_server = @import("rpc_server.zig");
```

### Step 5: Add tests

**File:** `src/rpc_server_test.zig`

```zig
test "single request parsing" { ... }
test "batch request parsing" { ... }
test "method not found error" { ... }
test "invalid json error" { ... }
test "http server responds" { ... }
```

---

## Key Design Decisions

### Use `std.http.Server`
- Zig's stdlib HTTP server is sufficient for a dev node
- No external HTTP library (httpz, zap) needed
- Single-threaded event loop is fine for dev use

### Sequential Batch Processing
- Match EDR's approach (state consistency within batch)
- Simpler to implement in Zig (no async/threading needed)
- Anvil does concurrent batches but that's an optimization

### Return -32601 for All Methods Initially
- Allows immediately running hive rpc-compat tests
- All 199 tests will get proper error responses
- Progress is measurable: count passing hive tests

### JSON-RPC Envelope in Voltaire
- These are fundamental JSON-RPC 2.0 types needed by any consumer
- voltaire-ts already has them; Zig should mirror
- Location: `voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`

---

## File Inventory

### zevm (this repo) — TO CREATE/MODIFY

| File | Purpose |
|------|---------|
| `src/rpc_server.zig` | HTTP server, request parsing, batch handling, dispatch |
| `src/rpc_server_test.zig` | Unit tests for RPC server |
| `src/main.zig` | **MODIFY** — Add CLI arg parsing, server startup |
| `src/root.zig` | **MODIFY** — Add rpc_server export |

### voltaire upstream (`../voltaire`) — TO CREATE

| File | Purpose |
|------|---------|
| `packages/voltaire-zig/src/jsonrpc/envelope.zig` | JSON-RPC 2.0 envelope types (Request, Response, Error, Id) |
| `packages/voltaire-zig/src/jsonrpc/root.zig` | **MODIFY** — Re-export envelope types |

### Reference Files (read-only)

| File | What it shows |
|------|--------------|
| `foundry/crates/anvil/server/src/handler.rs` | HTTP request handling, single/batch routing |
| `foundry/crates/anvil/rpc/src/request.rs` | Request/RpcCall/RpcMethodCall/RequestParams/Id types |
| `foundry/crates/anvil/rpc/src/error.rs` | RpcError/ErrorCode types |
| `edr/crates/edr_provider/src/requests.rs` | Single/Batch request discrimination |
| `hive/simulators/ethereum/rpc-compat/main.go` | Hive test runner pattern |
| `execution-apis/tests/eth_blockNumber/simple-test.io` | `.io` test format example |

---

## Testing Strategy

### Unit Tests
- Request parsing (single vs batch)
- Method dispatch (known vs unknown methods)
- Error response formatting
- ID preservation (number, string, null)

### Integration Tests
- Start server, send HTTP POST, verify response
- Test batch requests with mixed valid/invalid methods

### Hive rpc-compat
Once the server returns `-32601` for all methods:
```bash
# Build zevm as a docker image for hive
# Run rpc-compat simulator
./hive --sim ethereum/rpc-compat --client zevm
```

All 199 tests should get proper error responses (not crashes/timeouts).

---

## Zig Style Compliance

- **No local type aliases** — Use `jsonrpc.envelope.Request`, not `const Request = jsonrpc.envelope.Request`
- **No stored allocators** — Pass `std.mem.Allocator` explicitly to methods
- **Fully qualified paths** — `std.json.Value`, `std.net.Address`, etc.
- **Zig 0.15** — Use lowercase `@typeInfo` variants (`.int`, `.bool`)

