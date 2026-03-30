# Context: implement-http-server-route

> Archival snapshot note: this file is non-normative and may include historical upstream error-code examples.
> ZEVM authoritative error semantics are in `docs/specs/json-rpc-contract.md` section 5.

## Ticket Summary

Add HTTP server implementation in `src/rpc_server.zig` using `std.http.Server`. Ensure it handles POST requests appropriately and returns 405 for other methods.

**Category:** cat-1-rpc-server

---

## Upstream Dependencies (voltaire & guillotine-mini)

### Voltaire JSON-RPC Module (../voltaire/packages/voltaire-zig/src/jsonrpc/)

**Already exported in voltaire's build.zig (lines 76-84):**
```zig
const jsonrpc_mod = b.addModule("jsonrpc", .{
    .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

**Current structure:**
- `root.zig` — Re-exports: `JsonRpc`, `eth`, `debug`, `engine`, `types`, `JsonRpcMethod`
- `JsonRpc.zig` — Root `JsonRpcMethod` union(enum) combining all namespaces
- `eth/methods.zig` — `EthMethod` union with 39 methods + `fromMethodName()` StaticStringMap
- `debug/methods.zig` — `DebugMethod` union with 5 methods + `fromMethodName()`
- `engine/methods.zig` — `EngineMethod` union with 20 methods + `fromMethodName()`
- `types.zig` — Shared types: `Address`, `Hash`, `Quantity`, `BlockTag`, `BlockSpec`

**What's MISSING (must be added to voltaire):**
- JSON-RPC 2.0 envelope types (`Request`, `Response`, `Error`, `Id`)
- Error code constants (`PARSE_ERROR: -32700`, `INVALID_REQUEST: -32600`, etc.)
- These should go in a new file: `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`

### Guillotine-mini (../guillotine-mini/)

**What it is:** Pure EVM interpreter library
- `src/evm.zig` — EVM execution engine
- `src/host.zig` — Host interface for state access
- `src/opcode.zig` — Opcode definitions

**What it does NOT have:** HTTP server, JSON-RPC dispatch, envelope parsing

ZEVM's `host_adapter.zig` bridges voltaire's StateManager to guillotine-mini's HostInterface.

---

## ZEVM Current State

### Existing Files
```
src/main.zig              — Stub: prints "zevm - Ethereum local node"
src/root.zig              — Exports: database, blockchain, host_adapter, tx_processor,
                             block_builder, consensus_verifier, beacon_api, consensus_sync, checkpoint
build.zig                 — Imports voltaire modules (primitives, state-manager, blockchain, 
                             crypto, precompiles) and guillotine-mini. Does NOT import jsonrpc yet.
build.zig.zon             — Dependencies: voltaire (../voltaire), guillotine-mini (../guillotine-mini)
```

### Build System
- zevm imports from voltaire: `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles`
- zevm imports from guillotine-mini: `guillotine_mini` module
- **Must add:** `jsonrpc` module import from voltaire

---

## Implementation Requirements

### HTTP Server Route (src/rpc_server.zig)

**Core functionality:**
1. Use `std.http.Server` for HTTP handling
2. Listen on configurable port (default 8545)
3. Accept only POST requests — return 405 Method Not Allowed for others
4. Parse JSON-RPC 2.0 request from POST body
5. Return JSON-RPC 2.0 response with appropriate Content-Type header

**Key API pattern (Zig 0.15 std.http.Server):**
```zig
const address = try std.net.Address.parseIp4(host, port);
var server = try address.listen(.{ .reuse_address = true });
defer server.deinit();

while (true) {
    const conn = try server.accept();
    defer conn.stream.close();
    
    var buf: [8192]u8 = undefined;
    var http = std.http.Server.init(conn, &buf);
    var req = try http.receiveHead();
    
    // Check method
    if (req.method != .POST) {
        try req.respond("Method Not Allowed", .{ .status = .method_not_allowed });
        continue;
    }
    
    // Read body
    const body = try req.reader().readAllAlloc(allocator, max_body_size);
    defer allocator.free(body);
    
    // Process and respond
    const response = try handleJsonRpc(allocator, body);
    try req.respond(response, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
```

**Method dispatch:**
- Parse JSON body into `std.json.Value`
- Detect single vs batch (object vs array at top level)
- For each request: extract `method` field
- Use `jsonrpc.eth.EthMethod.fromMethodName()`, `jsonrpc.debug.DebugMethod.fromMethodName()`, etc.
- Return `-32601 Method not found` for all methods (stubs)

---

## Reference Implementations

### Foundry Anvil (foundry/crates/anvil/server/src/)

**handler.rs:**
- Axum-based HTTP routing
- POST handler for JSON-RPC
- Single/Batch request handling
- Parallel batch processing via `futures::join_all`

```rust
pub async fn handle<Http: RpcHandler, Ws>(
    State((handler, _)): State<(Http, Ws)>,
    request: Result<Json<Request>, JsonRejection>,
) -> Json<Response> {
    Json(match request {
        Ok(Json(req)) => handle_request(req, handler)
            .await
            .unwrap_or_else(|| Response::error(RpcError::invalid_request())),
        Err(err) => Response::error(RpcError::invalid_request())
    })
}
```

**lib.rs:**
- `http_router()` — configures axum Router with POST handler
- `RpcHandler` trait — async dispatch to method handlers
- CORS layer support

### EDR (edr/crates/edr_provider/src/requests/)

**jsonrpc.rs:**
```rust
struct Request<MethodT> { version: Version, method: MethodT, id: Id }
enum ResponseData<SuccessT> { Error { error: Error }, Success { result: SuccessT } }
struct Error { code: i16, message: String, data: Option<Value> }
enum Id { Num(u64), Str(String) }
```

**methods.rs:**
- `ProviderRequest` enum: `Single(Box<MethodInvocation>)` | `Batch(Vec<MethodInvocation>)`
- Custom deserializer distinguishes single (map) vs batch (array)
- 73 RPC methods including eth_, debug_, hardhat_, evm_, web3_, net_

### TEVM (../tevm-monorepo/packages/actions/src/)

**Pattern:**
- Hash map lookup for dispatch: `handlers[method](request)`
- Three-layer architecture: Procedure (JSON-RPC adapter) -> Handler -> Core operations
- Namespace aliasing: same handler for `anvil_*`, `hardhat_*`, `ganache_*`

---

## JSON-RPC 2.0 Specification

### Request Envelope
```json
{
    "jsonrpc": "2.0",
    "method": "eth_chainId",
    "params": [],
    "id": 1
}
```

### Response Envelope
```json
{
    "jsonrpc": "2.0",
    "result": "0x1",
    "id": 1
}
```

### Error Envelope
```json
{
    "jsonrpc": "2.0",
    "error": {
        "code": -32601,
        "message": "Method not found"
    },
    "id": 1
}
```

### Error Codes
| Code | Constant | Meaning |
|------|----------|---------|
| -32700 | PARSE_ERROR | Invalid JSON received |
| -32600 | INVALID_REQUEST | Not a valid Request object |
| -32601 | METHOD_NOT_FOUND | Method does not exist |
| -32602 | INVALID_PARAMS | Invalid method parameters |
| -32603 | INTERNAL_ERROR | Internal JSON-RPC error |

---

## Files to Create/Modify

### New Files
| File | Description |
|------|-------------|
| `src/rpc_server.zig` | HTTP server using std.http.Server, POST-only route, 405 for others |
| `src/rpc_server_test.zig` | HTTP server tests (POST handling, 405 rejection, integration) |

### Modified Files
| File | Change |
|------|--------|
| `build.zig` | Import `jsonrpc` module from voltaire, add to zevm + exe + test imports |
| `src/root.zig` | Add `pub const rpc_server = @import("rpc_server.zig");` + test import |
| `src/main.zig` | Replace stub with CLI parsing + server startup |

### Upstream Files (voltaire)
| File | Change |
|------|--------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` | NEW: Request, Response, Error, Id types with JSON serde |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig` | Add `pub const envelope = @import("envelope.zig");` |

---

## Key Design Decisions

### Use std.http.Server (Zig stdlib)
- No external HTTP library needed (httpz, zap)
- Sufficient for dev node use case
- Single-threaded event loop acceptable for Hive tests

### POST-only with 405 response
- Per JSON-RPC spec over HTTP
- Return HTTP 405 Method Not Allowed for GET, PUT, DELETE, etc.

### Sequential batch processing
- Simpler implementation (no async/threading needed)
- Matches EDR's approach for state consistency
- Can optimize to parallel later if needed

### Method dispatch via fromMethodName()
- Use `EthMethod.fromMethodName()` (StaticStringMap = O(1) lookup)
- Same pattern for debug and engine namespaces
- Return -32601 for all recognized methods (stub behavior)

---

## Testing Strategy

### Unit Tests (src/rpc_server_test.zig)
1. `test "HTTP server responds to POST with JSON-RPC"` — start server, POST, verify response
2. `test "HTTP server rejects GET with 405"` — verify 405 status
3. `test "HTTP server rejects PUT with 405"` — verify 405 status
4. `test "HTTP server rejects DELETE with 405"` — verify 405 status
5. `test "JSON-RPC parse error returns -32700"` — malformed JSON
6. `test "JSON-RPC invalid request returns -32600"` — missing method field
7. `test "JSON-RPC method not found returns -32601"` — unknown method
8. `test "Batch request returns array of responses"` — array input/output

### Existing Tests (must continue passing)
- tx_processor_test.zig
- host_adapter_test.zig
- block_builder_test.zig
- consensus_verifier_test.zig
- beacon_api_test.zig
- consensus_sync_test.zig
- checkpoint_test.zig
- database_test.zig

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|--------------|
| 1 | HTTP server listens on configurable port | `zig build run -- --port 9545` works |
| 2 | POST requests accepted and processed | curl POST returns JSON-RPC response |
| 3 | Non-POST requests return 405 | curl GET returns HTTP 405 |
| 4 | Content-Type: application/json on responses | Response headers verified |
| 5 | JSON-RPC 2.0 envelope parsed correctly | Valid requests processed |
| 6 | Batch requests handled as array | Array input -> array output |
| 7 | All existing tests pass | `zig build test` succeeds |

---

## Risk Analysis

| Risk | Mitigation |
|------|------------|
| Zig 0.15 std.http.Server API changes | Researched exact API; use `receiveHead()` pattern |
| Request body size limits | Use `readAllAlloc()` with 10MB max |
| Single-threaded blocking | Acceptable for dev node; Hive sends sequential requests |
| Missing envelope types in voltaire | Add envelope.zig upstream first |

---

## Path Reference Summary

### ZEVM (this repo)
- `src/main.zig` — Entry point (stub)
- `src/root.zig` — Module exports
- `src/rpc_server.zig` — TO CREATE: HTTP server
- `src/rpc_server_test.zig` — TO CREATE: Tests
- `build.zig` — Build configuration

### Voltaire (../voltaire)
- `packages/voltaire-zig/src/jsonrpc/root.zig` — Module entry
- `packages/voltaire-zig/src/jsonrpc/envelope.zig` — TO CREATE: Envelope types
- `packages/voltaire-zig/src/jsonrpc/eth/methods.zig` — EthMethod union
- `packages/voltaire-zig/src/jsonrpc/debug/methods.zig` — DebugMethod union
- `packages/voltaire-zig/src/jsonrpc/engine/methods.zig` — EngineMethod union
- `build.zig` — Already exports jsonrpc module

### Reference Implementations
- `foundry/crates/anvil/server/src/handler.rs` — Axum HTTP handler
- `foundry/crates/anvil/server/src/lib.rs` — Router setup
- `edr/crates/edr_rpc_client/src/jsonrpc.rs` — JSON-RPC types
- `edr/crates/edr_provider/src/requests/methods.rs` — Method dispatch
