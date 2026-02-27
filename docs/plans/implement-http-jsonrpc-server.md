# Plan: implement-http-jsonrpc-server

## Overview of the approach

Implement the missing HTTP JSON-RPC 2.0 server in ZEVM by composing existing upstream building blocks instead of introducing parallel infrastructure:

1. Add JSON-RPC envelope primitives in `voltaire` (`jsonrpc/envelope.zig`).
2. Import voltaire's `jsonrpc` module into ZEVM build wiring.
3. Implement ZEVM's integration layer in `src/rpc_server.zig`:
   - JSON-RPC envelope parsing/serialization usage
   - method dispatch via `jsonrpc.eth.EthMethod.fromMethodName`, `jsonrpc.debug.DebugMethod.fromMethodName`, `jsonrpc.engine.EngineMethod.fromMethodName`
   - HTTP POST server route
4. Wire CLI args in `src/main.zig` (`--host`, `--port`, `--chain-id`) and launch server.

Scope for this ticket is foundational wiring only: all recognized methods still return JSON-RPC `-32601` until handler tickets land.

## TDD step order (tests before implementation)

### Phase 1: Upstream envelope types in voltaire

1. Test: add `test "Id jsonParse supports integer/string/null"` in `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`.
2. Implement: `pub const Id` and `pub fn Id.jsonParse(...) !Id`.
3. Test: add `test "Id jsonStringify emits integer/string/null"` in same file.
4. Implement: `pub fn Id.jsonStringify(...) !void`.

5. Test: add `test "Request jsonParseFromValue accepts jsonrpc 2.0 object"` in same file.
6. Implement: `pub const Request` and `pub fn Request.jsonParseFromValue(...) !Request`.

7. Test: add `test "parseRequest returns parse error for malformed JSON"` in same file.
8. Implement: `pub fn parseRequest(allocator: std.mem.Allocator, json_bytes: []const u8) !Request`.

9. Test: add `test "parseBatchOrSingle parses single and batch"` in same file.
10. Implement: `pub const BatchOrSingle` and `pub fn parseBatchOrSingle(allocator: std.mem.Allocator, json_bytes: []const u8) !BatchOrSingle`.

11. Test: add `test "serializeResponse writes success envelope"` in same file.
12. Implement: `pub const ErrorCode`, `pub const Error`, `pub const Response`, and `pub fn serializeResponse(allocator: std.mem.Allocator, response: Response) ![]u8`.

13. Test: add `test "makeError builds jsonrpc error payload"` in same file.
14. Implement: `pub fn Response.makeError(id: ?Id, code: i32, message: []const u8) Response`.

15. Test: add `test "jsonrpc root re-exports envelope"` in `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`.
16. Implement: add `pub const envelope = @import("envelope.zig");` to `jsonrpc/root.zig`.

### Phase 2: ZEVM build wiring for cross-module imports

17. Test: add compile-level test `test "rpc_server imports jsonrpc module"` in `src/rpc_server_test.zig`.
18. Implement: update `build.zig` to load `const jsonrpc_mod = voltaire.module("jsonrpc");` and import it into ZEVM module + executable root module.

19. Test: extend ZEVM test aggregator with placeholder import for `rpc_server_test.zig` in `src/root.zig` test block.
20. Implement: add `pub const rpc_server = @import("rpc_server.zig");` and `_ = @import("rpc_server_test.zig");` to `src/root.zig`.

### Phase 3: JSON-RPC dispatcher in `src/rpc_server.zig` (pure logic first)

21. Test: `test "handleJsonRpc malformed JSON returns -32700"` in `src/rpc_server_test.zig`.
22. Implement: `pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8` parse-error path using `jsonrpc.envelope`.

23. Test: `test "handleJsonRpc invalid request object returns -32600"`.
24. Implement: `fn handleSingleValue(allocator: std.mem.Allocator, value: std.json.Value) !jsonrpc.envelope.Response` with request-shape validation.

25. Test: `test "dispatchMethod unknown method returns -32601"`.
26. Implement: `fn dispatchMethod(allocator: std.mem.Allocator, id: ?jsonrpc.envelope.Id, method_name: []const u8, params: ?std.json.Value) !jsonrpc.envelope.Response` fallback branch.

27. Test: `test "dispatchMethod recognizes eth_/debug_/engine_ namespaces but still returns -32601 stubs"`.
28. Implement: namespace recognition using `fromMethodName()` from the three voltaire enums.

29. Test: `test "handleJsonRpc preserves integer/string/null id in error responses"`.
30. Implement: propagate `id` into response constructors for all non-parse errors.

31. Test: `test "handleJsonRpc batch request returns array of responses"` and `test "handleJsonRpc empty batch returns -32600"`.
32. Implement: batch branch in `handleJsonRpc` (single array payload, per-element processing, invalid empty batch handling).

### Phase 4: HTTP server route in `src/rpc_server.zig`

33. Test: integration test `test "HTTP POST / returns JSON-RPC response"` using random port and `std.http.Client`.
34. Implement: `pub const ServerConfig` and `pub fn run(allocator: std.mem.Allocator, config: ServerConfig) !void` with accept loop and POST body handling.

35. Test: integration test `test "HTTP non-POST returns 405"`.
36. Implement: method gate in request handler path (`.method_not_allowed` status).

37. Test: integration test `test "HTTP malformed JSON returns parse error envelope"` (via POST raw body).
38. Implement: connect HTTP body to `handleJsonRpc` and set `content-type: application/json`.

### Phase 5: CLI arg wiring in `src/main.zig`

39. Test: `test "parseServerConfig defaults host=127.0.0.1 port=8545 chain_id=31337"` in `src/rpc_server_test.zig`.
40. Implement: `pub fn parseServerConfig(allocator: std.mem.Allocator, args: []const []const u8) !ServerConfig` in `src/rpc_server.zig`.

41. Test: `test "parseServerConfig parses --host --port --chain-id"` in `src/rpc_server_test.zig`.
42. Implement: flag parsing branches and integer parsing/validation.

43. Test: integration-level smoke test wrapper `test "main wiring uses parsed config and starts rpc server"` (no infinite loop; use extracted launcher function).
44. Implement: `fn runWithArgs(allocator: std.mem.Allocator, args: []const []const u8) !void` in `src/main.zig`; `main()` delegates to it.

### Phase 6: Final verification

45. Run ZEVM tests: `zig build test`.
46. Manual smoke checks:
   - `curl` POST valid JSON-RPC method -> `-32601`
   - malformed JSON -> `-32700`
   - batch payload -> JSON array response
47. If new upstream tests were added in `voltaire`, run `zig build test` in `../voltaire` before finalizing.

## Files to create/modify (with specific function signatures)

### Create

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`
   - `pub const Id = union(enum) { integer: i64, string: []const u8, null_value: void, pub fn jsonParse(...), pub fn jsonStringify(...) }`
   - `pub const ErrorCode = struct { pub const PARSE_ERROR: i32 = -32700; ... }`
   - `pub const Error = struct { code: i32, message: []const u8, data: ?std.json.Value }`
   - `pub const Request = struct { id: ?Id, method: []const u8, params: ?std.json.Value, pub fn jsonParseFromValue(...) !Request }`
   - `pub const Response = struct { id: ?Id, result: ?std.json.Value, error_value: ?Error, pub fn makeSuccess(...), pub fn makeError(...) }`
   - `pub const BatchOrSingle = union(enum) { single: Request, batch: []Request }`
   - `pub fn parseRequest(allocator: std.mem.Allocator, json_bytes: []const u8) !Request`
   - `pub fn parseBatchOrSingle(allocator: std.mem.Allocator, json_bytes: []const u8) !BatchOrSingle`
   - `pub fn serializeResponse(allocator: std.mem.Allocator, response: Response) ![]u8`

2. `src/rpc_server.zig`
   - `pub const ServerConfig = struct { host: []const u8, port: u16, chain_id: u64 }`
   - `pub fn parseServerConfig(allocator: std.mem.Allocator, args: []const []const u8) !ServerConfig`
   - `pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8`
   - `pub fn run(allocator: std.mem.Allocator, config: ServerConfig) !void`
   - `fn handleSingleValue(allocator: std.mem.Allocator, value: std.json.Value) !jsonrpc.envelope.Response`
   - `fn dispatchMethod(allocator: std.mem.Allocator, id: ?jsonrpc.envelope.Id, method_name: []const u8, params: ?std.json.Value) !jsonrpc.envelope.Response`

3. `src/rpc_server_test.zig`
   - Unit tests for envelope integration, dispatch, batch behavior, CLI parse behavior.
   - Integration tests for HTTP server route behavior.

### Modify

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
   - Add: `pub const envelope = @import("envelope.zig");`

2. `build.zig`
   - Add `jsonrpc` module import from dependency and inject into ZEVM module imports.
   - Ensure executable root module gets access to `jsonrpc` via `zevm` import chain.

3. `src/root.zig`
   - Add `pub const rpc_server = @import("rpc_server.zig");`
   - Add `_ = @import("rpc_server_test.zig");` in the root `test` block.

4. `src/main.zig`
   - Replace stub with argument collection, `rpc_server.parseServerConfig`, and `rpc_server.run`.
   - Keep main wiring thin (no stored allocator, no unnecessary wrappers).

## Tests to write (unit + integration)

### Unit tests

1. `envelope.zig`: `Id` parse/stringify coverage for integer, string, null.
2. `envelope.zig`: request validation (`jsonrpc` must be `"2.0"`, `method` must be string).
3. `envelope.zig`: error/success response serialization including standard error codes.
4. `rpc_server_test.zig`: parse error (`-32700`) for malformed JSON.
5. `rpc_server_test.zig`: invalid request (`-32600`) for malformed request objects.
6. `rpc_server_test.zig`: method not found (`-32601`) for unknown methods.
7. `rpc_server_test.zig`: recognized methods in `eth_`, `debug_`, `engine_` still return `-32601` stubs.
8. `rpc_server_test.zig`: request ID preservation across `i64`, string, and null.
9. `rpc_server_test.zig`: batch behavior (normal batch, mixed-valid batch, empty batch).
10. `rpc_server_test.zig`: CLI parsing defaults and overrides.

### Integration tests

1. `rpc_server_test.zig`: start server on random port, POST JSON-RPC body, assert JSON envelope response.
2. `rpc_server_test.zig`: GET request returns HTTP 405.
3. `rpc_server_test.zig`: malformed POST body returns JSON-RPC parse error response.
4. Manual `curl` smoke tests against `zig build run`.

## Risks and mitigations

1. Zig 0.15 HTTP API mismatches.
   - Mitigation: keep HTTP tests in lockstep with implementation; validate using `std.http.Server` + `std.net.Address.listen`.

2. JSON value lifetime and allocations across parse/serialize.
   - Mitigation: use allocator-explicit APIs, free parsed trees/slices in tests, keep response builders ownership-simple.

3. Batch semantics drift from JSON-RPC 2.0.
   - Mitigation: explicit tests for empty batch and mixed batch payloads before implementing batch branch.

4. Dispatch false positives/negatives.
   - Mitigation: tests for both recognized and unrecognized method names; use voltaire's `fromMethodName()` as the source of truth.

5. Upstream/downstream coupling between voltaire and ZEVM.
   - Mitigation: add compile-level test for `jsonrpc` import immediately after build wiring changes.

6. CLI parser regressions.
   - Mitigation: keep parser pure and testable (`parseServerConfig`), main only wires parsed config to `run`.

## How to verify against acceptance criteria

1. Server listens on default `127.0.0.1:8545` and respects `--host`/`--port`.
   - Verify with CLI parser tests + manual start logs and `curl`.

2. Valid JSON-RPC 2.0 envelope parsing/serialization exists in voltaire.
   - Verify via `envelope.zig` unit tests and exported symbol from `jsonrpc/root.zig`.

3. Malformed JSON returns `-32700`.
   - Verify `handleJsonRpc` unit test and HTTP malformed-body integration test.

4. Invalid request object returns `-32600`.
   - Verify `handleJsonRpc` unit test for missing/invalid fields.

5. Unknown/unimplemented methods return `-32601`.
   - Verify unknown method and recognized-stub method tests.

6. Batch requests are supported.
   - Verify batch unit tests for normal, mixed, and empty array cases.

7. Build wiring is complete for cross-module imports.
   - Verify ZEVM compiles/tests after adding `jsonrpc` module import in `build.zig`.

8. End-to-end behavior is reachable from ZEVM entrypoint.
   - Verify `src/main.zig` wiring test + manual `curl` smoke checks.
