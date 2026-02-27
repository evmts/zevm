# Plan: add-rpc-server-infrastructure

## Overview of the approach

Implement ZEVM's RPC server as a thin integration layer that reuses upstream components and keeps ZEVM-specific logic limited to transport and wiring.

1. Reuse `voltaire` JSON-RPC method typing (`jsonrpc.eth`, `jsonrpc.debug`, `jsonrpc.engine`) as the method authority.
2. Check for reusable `guillotine-mini` RPC dispatch in `../bench/guillotine-mini/client/rpc/` during implementation; if absent, keep a local dispatch adapter seam and use ZEVM-local routing.
3. Add a small `src/rpc/` package for:
   - JSON-RPC envelope parsing/serialization
   - method routing and handler dispatch
   - HTTP server request/response handling
4. Keep this ticket infrastructure-only: recognized methods can remain stubbed (`-32601`) while still proving end-to-end routing.

Constraints to enforce in implementation:
- No local type aliases.
- No stored allocators.
- Pass allocator explicitly to methods that allocate.

## TDD step order (tests before implementation)

Each step is atomic: one test, then the minimum implementation to make that test pass.

### Phase 0: Build wiring and test harness

1. Test: `src/rpc/router_test.zig` compile test verifies `@import("jsonrpc")` and `jsonrpc.eth.EthMethod.fromMethodName` are available in ZEVM.
2. Implement: update `build.zig` to import voltaire `jsonrpc` module into ZEVM module and executable module.
3. Test: `src/root.zig` test block imports new RPC test files.
4. Implement: add RPC module exports/imports in `src/root.zig`.

### Phase 1: JSON-RPC envelope parsing and serialization (pure unit tests)

5. Test: parse valid single request object (`jsonrpc`, `id`, `method`, optional `params`).
6. Implement: `src/rpc/envelope.zig` `pub fn parseRequestObject(value: std.json.Value) !Request`.
7. Test: malformed JSON maps to parse error (`-32700`, `id: null`).
8. Implement: `pub fn parseBody(allocator: std.mem.Allocator, bytes: []const u8) !ParsedBody` with parse-error mapping.
9. Test: invalid request object shape maps to `-32600`.
10. Implement: `pub fn validateRequestObject(value: std.json.Value) !void` and use in parser.
11. Test: `id` preserves number/string/null round-trip.
12. Implement: `pub fn parseId(value: std.json.Value) !Id` and `pub fn writeId(writer: anytype, id: ?Id) !void`.
13. Test: serialize success response envelope with `result`.
14. Implement: `pub fn writeSuccess(allocator: std.mem.Allocator, id: ?Id, result: std.json.Value) ![]u8`.
15. Test: serialize error response envelope with standard codes.
16. Implement: `pub fn writeError(allocator: std.mem.Allocator, id: ?Id, code: i32, message: []const u8) ![]u8`.
17. Test: non-empty batch parses as batch list.
18. Implement: batch branch in `parseBody` for `[]std.json.Value`.
19. Test: empty batch returns `-32600` invalid request.
20. Implement: explicit empty-array guard in batch parser.

### Phase 2: Router and dispatch wiring (unit tests, no HTTP yet)

21. Test: unknown method returns `-32601`.
22. Implement: `src/rpc/router.zig` `pub fn route(...) ![]u8` unknown-method path.
23. Test: known `eth_*` method name is recognized via voltaire `fromMethodName`, then stubbed `-32601`.
24. Implement: `try jsonrpc.eth.EthMethod.fromMethodName(method_name)` branch.
25. Test: known `debug_*` method recognition path.
26. Implement: `jsonrpc.debug.DebugMethod.fromMethodName` branch.
27. Test: known `engine_*` method recognition path.
28. Implement: `jsonrpc.engine.EngineMethod.fromMethodName` branch.
29. Test: route passes parsed params and id into handler adapter interface.
30. Implement: `src/rpc/handlers.zig` `pub const HandlerContext` + `pub fn dispatch(...) !HandlerResult` adapter seam.
31. Test: batch routing returns one response per request element (including mixed valid/invalid entries).
32. Implement: `routeBatch(...)` and aggregation order preservation.

### Phase 3: HTTP server integration tests

33. Test: HTTP `POST /` with valid JSON-RPC body returns HTTP 200 + `application/json` + JSON-RPC response.
34. Implement: `src/rpc/server.zig` `pub fn serve(...) !void` plus `handlePost(...)` calling router.
35. Test: HTTP non-POST (`GET /`) returns 405.
36. Implement: method gate in server request handler.
37. Test: malformed POST body returns JSON-RPC parse error (`-32700`).
38. Implement: map envelope parse errors to JSON-RPC error body at HTTP layer.
39. Test: batch POST body returns JSON array response.
40. Implement: server path for batch response emission.
41. Test: HTTP preflight/options behavior and CORS headers (if enabled by config).
42. Implement: optional CORS handling in server config and response headers.

### Phase 4: Node and main wiring (integration boundary)

43. Test: default server config resolves to host `127.0.0.1`, port `8545`.
44. Implement: `src/node.zig` `pub const RpcConfig` and default init path.
45. Test: CLI flags override host/port.
46. Implement: `src/main.zig` argument parsing for `--host` and `--port`.
47. Test: startup wiring constructs node context and starts RPC server with parsed config.
48. Implement: main startup flow calling `rpc.server.serve(...)`.

### Phase 5: End-to-end verification

49. Run `zig build test`.
50. Manual smoke checks:
   - valid request -> JSON-RPC response
   - malformed JSON -> `-32700`
   - unknown method -> `-32601`
   - batch payload -> response array

## Files to create/modify (with specific function signatures)

### Create

1. `src/rpc/root.zig`
- `pub const envelope = @import("envelope.zig");`
- `pub const router = @import("router.zig");`
- `pub const handlers = @import("handlers.zig");`
- `pub const server = @import("server.zig");`

2. `src/rpc/envelope.zig`
- `pub const Id = union(enum) { number: i64, string: []const u8, null_value: void }`
- `pub const Request = struct { id: ?Id, method: []const u8, params: ?std.json.Value }`
- `pub const ParsedBody = union(enum) { single: Request, batch: []Request }`
- `pub fn parseId(value: std.json.Value) !Id`
- `pub fn parseRequestObject(value: std.json.Value) !Request`
- `pub fn validateRequestObject(value: std.json.Value) !void`
- `pub fn parseBody(allocator: std.mem.Allocator, bytes: []const u8) !ParsedBody`
- `pub fn writeSuccess(allocator: std.mem.Allocator, id: ?Id, result: std.json.Value) ![]u8`
- `pub fn writeError(allocator: std.mem.Allocator, id: ?Id, code: i32, message: []const u8) ![]u8`

3. `src/rpc/handlers.zig`
- `pub const HandlerContext = struct { state_manager: *state_manager.StateManager, blockchain: *blockchain.Blockchain, chain_id: u64 }`
- `pub const HandlerResult = union(enum) { success: std.json.Value, rpc_error: struct { code: i32, message: []const u8 } }`
- `pub fn dispatch(allocator: std.mem.Allocator, context: *const HandlerContext, method_name: []const u8, params: ?std.json.Value, id: ?envelope.Id) !HandlerResult`

4. `src/rpc/router.zig`
- `pub fn route(allocator: std.mem.Allocator, context: *const handlers.HandlerContext, request: envelope.Request) ![]u8`
- `pub fn routeBatch(allocator: std.mem.Allocator, context: *const handlers.HandlerContext, requests: []const envelope.Request) ![]u8`

5. `src/rpc/server.zig`
- `pub const ServerConfig = struct { host: []const u8, port: u16, cors_enabled: bool }`
- `pub fn serve(allocator: std.mem.Allocator, config: ServerConfig, context: *const handlers.HandlerContext) !void`
- `fn handlePost(allocator: std.mem.Allocator, context: *const handlers.HandlerContext, body: []const u8) ![]u8`

6. `src/node.zig`
- `pub const RpcConfig = struct { host: []const u8 = "127.0.0.1", port: u16 = 8545, cors_enabled: bool = true }`
- `pub const Node = struct { state_manager: *state_manager.StateManager, blockchain: *blockchain.Blockchain, rpc_config: RpcConfig, chain_id: u64 }`

7. `src/rpc/envelope_test.zig`
8. `src/rpc/router_test.zig`
9. `src/rpc/server_test.zig`

### Modify

1. `build.zig`
- Add voltaire `jsonrpc` module import and wire into ZEVM imports.

2. `src/root.zig`
- Export `pub const rpc = @import("rpc/root.zig");`
- Import RPC test files in root `test` block.

3. `src/main.zig`
- Parse CLI args (`--host`, `--port`).
- Construct node/context and start server.

## Tests to write (unit + integration)

### Unit tests

1. `envelope_test.zig`: request object parsing success/failure.
2. `envelope_test.zig`: `id` parsing for integer/string/null.
3. `envelope_test.zig`: parse-error vs invalid-request differentiation.
4. `envelope_test.zig`: success/error response serialization.
5. `envelope_test.zig`: batch parsing and empty-batch invalid request.
6. `router_test.zig`: unknown method -> `-32601`.
7. `router_test.zig`: eth/debug/engine recognition via voltaire `fromMethodName`.
8. `router_test.zig`: id preservation in routed error responses.
9. `router_test.zig`: batch request routing order and mixed validity handling.
10. `router_test.zig`: handler adapter receives method + params unchanged.

### Integration tests

1. `server_test.zig`: start HTTP server on test port; POST valid JSON-RPC and assert 200 + JSON body.
2. `server_test.zig`: GET returns 405.
3. `server_test.zig`: malformed JSON returns `-32700` payload.
4. `server_test.zig`: batch POST returns response array with per-item errors.
5. `server_test.zig`: optional CORS headers for OPTIONS/POST.
6. `src/main.zig` startup smoke test through extracted `runWithArgs` helper.

## Risks and mitigations

1. `std.http.Server` API complexity in Zig 0.15 can cause flaky tests.
- Mitigation: keep parser/router pure and heavily unit tested; keep server tests narrow and deterministic.

2. JSON value ownership/lifetimes across parse and serialization can leak memory.
- Mitigation: use allocator-explicit ownership boundaries and explicit `defer` cleanup in every test.

3. Notification semantics (`id` absent) may differ across clients.
- Mitigation: decide behavior explicitly in tests before implementation (respond with `id:null` or suppress response).

4. Upstream availability mismatch for guillotine-mini RPC dispatch path.
- Mitigation: keep a dispatch adapter seam; if upstream path is absent, use local router without blocking ticket.

5. Method recognition drift if method lists are duplicated.
- Mitigation: rely only on voltaire `fromMethodName` helpers and avoid local method tables.

## How to verify against acceptance criteria

1. HTTP endpoint listens on configurable host/port.
- Verify with integration test and manual `curl` to configured address.

2. JSON-RPC 2.0 envelope parsing is correct.
- Verify unit tests for valid object, malformed JSON, invalid request object, and batch handling.

3. Request `method` and `params` are extracted and routed.
- Verify router tests asserting adapter receives exact method + params.

4. Unknown methods return JSON-RPC method-not-found.
- Verify unit/integration assertions for `-32601` responses.

5. Infrastructure integrates with upstream method typing and keeps ZEVM thin.
- Verify compile test uses voltaire `jsonrpc.*.fromMethodName` and no duplicate local method map.

6. ZEVM test suite remains green.
- Run `zig build test`.
