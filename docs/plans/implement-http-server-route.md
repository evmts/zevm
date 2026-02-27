# Plan: implement-http-server-route

## Overview of the approach

Implement ZEVM's HTTP JSON-RPC route as a thin integration layer over upstream capabilities:

1. Add missing JSON-RPC 2.0 envelope types in `voltaire` (upstream we own).
2. Wire `jsonrpc` into ZEVM build imports.
3. Build `src/rpc_server.zig` with `std.http.Server` and explicit POST-only routing.
4. Return HTTP `405 Method Not Allowed` for non-POST methods.
5. For POST requests, parse JSON-RPC envelope and return `-32601 Method not found` (stub dispatch for now).

Scope stays focused on route behavior and wiring. Method business logic is intentionally out of scope for this ticket.

## TDD step order (tests before implementation)

### Phase 1: Upstream JSON-RPC envelope primitives (`../voltaire`)

1. Test: `envelope.zig` `test "Id parses integer/string/null"`.
2. Implement: `pub const Id` and `pub fn Id.jsonParse(...) !Id`.

3. Test: `envelope.zig` `test "Id stringifies integer/string/null"`.
4. Implement: `pub fn Id.jsonStringify(...) !void`.

5. Test: `envelope.zig` `test "Request parses valid jsonrpc 2.0 object"`.
6. Implement: `pub const Request` and `pub fn Request.jsonParseFromValue(...) !Request`.

7. Test: `envelope.zig` `test "parseBatchOrSingle parses object and array"`.
8. Implement: `pub const BatchOrSingle` and `pub fn parseBatchOrSingle(allocator: std.mem.Allocator, json_bytes: []const u8) !BatchOrSingle`.

9. Test: `envelope.zig` `test "serializeResponse emits success and error envelopes"`.
10. Implement: `pub const ErrorCode`, `pub const ErrorObject`, `pub const Response`, `pub fn serializeResponse(allocator: std.mem.Allocator, response: Response) ![]u8`.

11. Test: `jsonrpc/root.zig` `test "jsonrpc exports envelope"`.
12. Implement: add `pub const envelope = @import("envelope.zig");`.

### Phase 2: ZEVM module wiring

13. Test: add compile test in `src/rpc_server_test.zig` that imports `@import("jsonrpc")` and references `jsonrpc.envelope` symbols.
14. Implement: update `build.zig` to import voltaire `jsonrpc` into ZEVM module (and executable via `zevm` import chain).

15. Test: add `src/root.zig` test import coverage for `rpc_server_test.zig`.
16. Implement: add `pub const rpc_server = @import("rpc_server.zig");` and `_ = @import("rpc_server_test.zig");`.

### Phase 3: JSON-RPC route logic (pure functions first)

17. Test: `rpc_server_test.zig` `test "handleJsonRpc malformed JSON returns -32700"`.
18. Implement: `pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8` parse-error path.

19. Test: `test "handleJsonRpc invalid request returns -32600"` (missing `method`, bad `jsonrpc`, non-object item).
20. Implement: `fn handleSingleRequest(allocator: std.mem.Allocator, request: jsonrpc.envelope.Request) !jsonrpc.envelope.Response` with shape validation and invalid-request response.

21. Test: `test "dispatchMethod unknown method returns -32601"`.
22. Implement: `fn dispatchMethod(id: ?jsonrpc.envelope.Id, method_name: []const u8) jsonrpc.envelope.Response` default error response.

23. Test: `test "dispatchMethod recognizes eth/debug/engine names but still stubs -32601"`.
24. Implement: method recognition with `jsonrpc.eth.EthMethod.fromMethodName`, `jsonrpc.debug.DebugMethod.fromMethodName`, `jsonrpc.engine.EngineMethod.fromMethodName`.

25. Test: `test "handleJsonRpc preserves id in error responses"` for numeric/string/null ids.
26. Implement: response construction paths preserve request id except parse error.

27. Test: `test "handleJsonRpc batch returns array of responses"`.
28. Implement: batch loop in `handleJsonRpc` for `BatchOrSingle.batch`.

29. Test: `test "handleJsonRpc empty batch returns -32600"`.
30. Implement: explicit empty-array check per JSON-RPC spec.

### Phase 4: HTTP server route (`std.http.Server`)

31. Test: integration `test "HTTP POST returns JSON-RPC response with application/json"`.
32. Implement: `pub const ServerConfig` and `pub fn run(allocator: std.mem.Allocator, config: ServerConfig) !void` with listener + request loop + POST handling.

33. Test: integration `test "HTTP GET returns 405"`.
34. Implement: method gate in request handler (`if req.head.method != .POST` -> respond status `.method_not_allowed`).

35. Test: integration `test "HTTP PUT/DELETE return 405"`.
36. Implement: ensure same method gate applies to all non-POST methods.

37. Test: integration `test "HTTP malformed POST body returns -32700 envelope"`.
38. Implement: read request body and pass bytes to `handleJsonRpc`; respond body with serialized JSON-RPC error.

39. Test: integration `test "HTTP batch POST returns JSON array"`.
40. Implement: ensure `handleJsonRpc` batch result is returned as-is over HTTP.

### Phase 5: Entrypoint wiring (`src/main.zig`)

41. Test: `test "parseServerConfig defaults host and port"`.
42. Implement: `pub fn parseServerConfig(args: []const []const u8) !ServerConfig` in `src/rpc_server.zig`.

43. Test: `test "parseServerConfig parses --host and --port"`.
44. Implement: CLI parsing branches and numeric validation.

45. Test: smoke test for main wiring through extracted helper.
46. Implement: `fn runWithArgs(allocator: std.mem.Allocator, args: []const []const u8) !void` in `src/main.zig`, then `main()` delegates.

### Phase 6: Verification

47. Run ZEVM tests: `zig build test`.
48. Manual route checks:
   - `curl -X POST` returns JSON-RPC envelope.
   - `curl -X GET` returns HTTP 405.
   - malformed JSON returns `-32700`.
49. If upstream envelope tests were added, run `zig build test` in `../voltaire`.

## Files to create/modify (with specific function signatures)

### Create

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`
   - `pub const Id = union(enum) { integer: i64, string: []const u8, null_value: void, ... }`
   - `pub fn Id.jsonParse(...) !Id`
   - `pub fn Id.jsonStringify(...) !void`
   - `pub const Request = struct { jsonrpc: []const u8, method: []const u8, params: ?std.json.Value, id: ?Id, ... }`
   - `pub fn Request.jsonParseFromValue(allocator: std.mem.Allocator, value: std.json.Value) !Request`
   - `pub const BatchOrSingle = union(enum) { single: Request, batch: []Request }`
   - `pub fn parseBatchOrSingle(allocator: std.mem.Allocator, json_bytes: []const u8) !BatchOrSingle`
   - `pub const ErrorCode = struct { pub const PARSE_ERROR: i32 = -32700; pub const INVALID_REQUEST: i32 = -32600; pub const METHOD_NOT_FOUND: i32 = -32601; pub const INVALID_PARAMS: i32 = -32602; pub const INTERNAL_ERROR: i32 = -32603; }`
   - `pub const ErrorObject = struct { code: i32, message: []const u8 }`
   - `pub const Response = struct { jsonrpc: []const u8, id: ?Id, result: ?std.json.Value, error: ?ErrorObject, ... }`
   - `pub fn serializeResponse(allocator: std.mem.Allocator, response: Response) ![]u8`

2. `src/rpc_server.zig`
   - `pub const ServerConfig = struct { host: []const u8 = "127.0.0.1", port: u16 = 8545, max_body_bytes: usize = 1048576 };`
   - `pub fn parseServerConfig(args: []const []const u8) !ServerConfig`
   - `pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8`
   - `fn handleSingleRequest(allocator: std.mem.Allocator, request: jsonrpc.envelope.Request) !jsonrpc.envelope.Response`
   - `fn dispatchMethod(id: ?jsonrpc.envelope.Id, method_name: []const u8) jsonrpc.envelope.Response`
   - `pub fn run(allocator: std.mem.Allocator, config: ServerConfig) !void`

3. `src/rpc_server_test.zig`
   - Unit tests for envelope handling, dispatch behavior, batch handling, and CLI config parsing.
   - Integration tests for HTTP POST success and non-POST 405 behavior.

### Modify

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
   - Add `pub const envelope = @import("envelope.zig");`

2. `build.zig`
   - Add `const jsonrpc_mod = voltaire.module("jsonrpc");`
   - Add `. { .name = "jsonrpc", .module = jsonrpc_mod }` to ZEVM module imports.

3. `src/root.zig`
   - Add `pub const rpc_server = @import("rpc_server.zig");`
   - Add `_ = @import("rpc_server_test.zig");` in `test` block.

4. `src/main.zig`
   - Replace stub print with argument parsing and `zevm.rpc_server.run(...)` startup.

## Tests to write (unit + integration)

### Unit tests

1. `../voltaire/.../jsonrpc/envelope.zig`
   - `Id` parse/stringify coverage.
   - `Request` validation for JSON-RPC 2.0 object shape.
   - `parseBatchOrSingle` for single, batch, and empty batch handling.
   - `serializeResponse` for success/error envelope formatting.

2. `src/rpc_server_test.zig`
   - `handleJsonRpc` parse error `-32700`.
   - invalid request `-32600`.
   - method not found `-32601`.
   - id propagation for int/string/null.
   - batch returns response array.
   - config parser defaults/overrides.

### Integration tests

1. `src/rpc_server_test.zig`
   - POST request returns HTTP 200 with JSON-RPC body and `content-type: application/json`.
   - GET/PUT/DELETE return HTTP 405.
   - malformed POST body returns JSON-RPC parse error envelope.
   - batch POST returns JSON array response.

2. Full suite regression
   - `zig build test` must keep existing integration-layer tests passing.

## Risks and mitigations

1. `std.http.Server` API details in Zig 0.15 can be easy to misuse.
   - Mitigation: add integration tests before route implementation and keep request handling minimal.

2. Server loop testability (infinite `run()` loop) can make tests flaky.
   - Mitigation: use per-test ephemeral port and a controlled server thread lifecycle with deterministic shutdown hooks.

3. JSON ownership/lifetime issues when parsing and re-serializing.
   - Mitigation: allocator-explicit APIs, clear ownership rules, and tests with leak checks enabled.

4. Drift between ZEVM and upstream `voltaire` envelope definitions.
   - Mitigation: add envelope tests upstream first, then consume only exported symbols from ZEVM.

5. Scope creep into full RPC method handling.
   - Mitigation: keep this ticket at route + envelope + dispatch stub (`-32601`) only.

## How to verify against acceptance criteria

1. **HTTP server implementation uses `std.http.Server`**
   - Verified by `src/rpc_server.zig` implementation and integration tests exercising real HTTP requests.

2. **POST requests handled appropriately**
   - POST integration tests validate JSON-RPC parsing and JSON response body.

3. **Non-POST returns 405**
   - GET/PUT/DELETE integration tests assert HTTP 405 status.

4. **No regression in ZEVM integration layer**
   - `zig build test` remains green for existing tests (`tx_processor`, `host_adapter`, `block_builder`, consensus/beacon/checkpoint/database tests).

5. **Wiring completeness**
   - Build compiles with `jsonrpc` module import and `main.zig` route startup path.
