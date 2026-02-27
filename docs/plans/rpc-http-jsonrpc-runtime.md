# Plan: rpc-http-jsonrpc-runtime

## Overview of the approach

Build a production JSON-RPC 2.0 HTTP runtime in ZEVM as a thin integration layer, while keeping JSON-RPC envelope typing and serde in `voltaire`.

- Use `voltaire` JSON-RPC method unions (`jsonrpc.eth.EthMethod`, `jsonrpc.debug.DebugMethod`, `jsonrpc.engine.EngineMethod`) as the dispatch source of truth.
- Add missing envelope-level JSON-RPC request/response types to `voltaire` (upstream we own), instead of duplicating envelope models in ZEVM.
- Implement ZEVM runtime in small layers:
1. `src/rpc/dispatcher.zig`: route method names and validate params shape at the integration boundary.
2. `src/rpc/server.zig`: HTTP transport, body parsing, single/batch orchestration, canonical error mapping.
3. `src/main.zig`: runtime config wiring only (host/port defaults and startup).

Decision for this ticket: choose option (b) from the description and wire ZEVM dispatch directly to `voltaire` method unions, since the expected `guillotine-mini` RPC dispatch modules are not present in this checkout.

## TDD step order (tests first, then implementation)

### Phase 1: Upstream envelope support in voltaire

1. Test (`../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`): `test "Id parses integer|string|null"`.
2. Implement: `pub const Id` with `pub fn jsonParse(...) !Id`.

3. Test: `test "Id serializes integer|string|null"`.
4. Implement: `pub fn jsonStringify(self: Id, jws: *std.json.Stringify) !void`.

5. Test: `test "RequestEnvelope parses valid JSON-RPC 2.0 object"`.
6. Implement: `pub const RequestEnvelope` and `pub fn RequestEnvelope.jsonParseFromValue(...) !RequestEnvelope`.

7. Test: `test "RequestEnvelope rejects invalid jsonrpc version and missing method"`.
8. Implement: request-shape validation inside `jsonParseFromValue` and return `error.InvalidRequest`.

9. Test: `test "ResponseEnvelope serializes success and error payloads"`.
10. Implement: `pub const JsonRpcError`, `pub const ResponseEnvelope`, `pub fn ResponseEnvelope.makeSuccess(...) ResponseEnvelope`, `pub fn ResponseEnvelope.makeError(...) ResponseEnvelope`.

11. Test: `test "parseSingleOrBatch handles object and array"`.
12. Implement: `pub const RequestBatch = union(enum) { single: RequestEnvelope, batch: []RequestEnvelope }` and `pub fn parseSingleOrBatch(allocator: std.mem.Allocator, json_bytes: []const u8) !RequestBatch`.

13. Test (`../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`): `test "jsonrpc root exports envelope"`.
14. Implement: add `pub const envelope = @import("envelope.zig");`.

### Phase 2: ZEVM build and module wiring

15. Test (`src/rpc/dispatcher_test.zig`): `test "zevm imports voltaire jsonrpc module"` (compile-time declaration check).
16. Implement (`build.zig`): import `const jsonrpc_mod = voltaire.module("jsonrpc");` and add it to ZEVM module imports.

17. Test (`src/root.zig` test block): include `dispatcher_test` and `server_test` imports (failing until files exist).
18. Implement (`src/root.zig`): export `pub const rpc = @import("rpc/root.zig");` and import new test files.

### Phase 3: Dispatcher behavior (pure unit tests)

19. Test (`src/rpc/dispatcher_test.zig`): `test "dispatch unknown method returns -32601"`.
20. Implement (`src/rpc/dispatcher.zig`): `pub fn dispatch(allocator: std.mem.Allocator, request: jsonrpc.envelope.RequestEnvelope, handlers: *const HandlerRegistry) !jsonrpc.envelope.ResponseEnvelope` unknown-method fallback.

21. Test: `test "dispatch recognized eth/debug/engine method with no handler returns -32601"`.
22. Implement: method namespace recognition using `fromMethodName()` for all three namespaces.

23. Test: `test "dispatch invalid params shape returns -32602"`.
24. Implement: add `fn validateParamsForMethod(...) !void` that maps parse failures of method `Params` into invalid params.

25. Test: `test "dispatch handler failure maps to -32603"`.
26. Implement: map unexpected handler errors to internal error while preserving request id.

27. Test: `test "dispatch preserves integer|string|null id in error responses"`.
28. Implement: ensure all dispatcher error builders pass through envelope `id`.

### Phase 4: HTTP JSON-RPC runtime behavior

29. Test (`src/rpc/server_test.zig`): `test "POST single request returns HTTP 200 + JSON-RPC envelope"`.
30. Implement (`src/rpc/server.zig`): `pub const ServerConfig` and `pub fn run(allocator: std.mem.Allocator, config: ServerConfig, handlers: *const dispatcher.HandlerRegistry) !void` with basic POST flow.

31. Test: `test "batch request returns per-item result/error array"`.
32. Implement: `fn handleBatch(...) ![]u8` with one response per request item.

33. Test: `test "malformed JSON returns -32700"`.
34. Implement: parse-error branch mapping invalid JSON parse to canonical parse error response.

35. Test: `test "invalid request object returns -32600"`.
36. Implement: request validation failure mapping from envelope parser to invalid request response.

37. Test: `test "unknown method returns -32601"`.
38. Implement: delegate unknown-method behavior through dispatcher.

39. Test: `test "bad params returns -32602"`.
40. Implement: propagate dispatcher invalid-params response through HTTP runtime.

41. Test: `test "non-POST request returns 405"`.
42. Implement: HTTP method gate before JSON parsing.

43. Test: `test "content-type application/json for JSON-RPC responses"`.
44. Implement: set response header and keep HTTP status 200 for JSON-RPC responses.

### Phase 5: Main entrypoint wiring

45. Test (`src/rpc/server_test.zig` or `src/main_test.zig`): `test "parseConfig defaults to 127.0.0.1:8545"`.
46. Implement (`src/rpc/server.zig`): `pub fn parseConfig(allocator: std.mem.Allocator, args: []const []const u8) !ServerConfig` with defaults.

47. Test: `test "parseConfig parses --host and --port"`.
48. Implement: argument parsing branches and port validation.

49. Test (`src/main_test.zig`): `test "main wiring passes parsed config to server runtime"`.
50. Implement (`src/main.zig`): delegate startup to `rpc.server.run` with minimal glue.

### Phase 6: End-to-end validation

51. Run `zig build test`.
52. Add/update failing-path integration coverage if any acceptance criterion is not explicitly asserted.

## Files to create/modify (with specific function signatures)

### Create

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`
- `pub const Id = union(enum) { integer: i64, string: []const u8, null_value: void, pub fn jsonParse(...), pub fn jsonStringify(...) }`
- `pub const RequestEnvelope = struct { id: ?Id, method: []const u8, params: ?std.json.Value, pub fn jsonParseFromValue(...) !RequestEnvelope }`
- `pub const JsonRpcError = struct { code: i32, message: []const u8, data: ?std.json.Value }`
- `pub const ResponseEnvelope = struct { id: ?Id, result: ?std.json.Value, error_value: ?JsonRpcError, pub fn makeSuccess(...), pub fn makeError(...) }`
- `pub const RequestBatch = union(enum) { single: RequestEnvelope, batch: []RequestEnvelope }`
- `pub fn parseSingleOrBatch(allocator: std.mem.Allocator, json_bytes: []const u8) !RequestBatch`

2. `src/rpc/root.zig`
- `pub const dispatcher = @import("dispatcher.zig");`
- `pub const server = @import("server.zig");`

3. `src/rpc/dispatcher.zig`
- `pub const HandlerRegistry = struct { ... }`
- `pub fn dispatch(allocator: std.mem.Allocator, request: jsonrpc.envelope.RequestEnvelope, handlers: *const HandlerRegistry) !jsonrpc.envelope.ResponseEnvelope`
- `fn validateParamsForMethod(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) !void`

4. `src/rpc/server.zig`
- `pub const ServerConfig = struct { host: []const u8 = "127.0.0.1", port: u16 = 8545 }`
- `pub fn parseConfig(allocator: std.mem.Allocator, args: []const []const u8) !ServerConfig`
- `pub fn run(allocator: std.mem.Allocator, config: ServerConfig, handlers: *const dispatcher.HandlerRegistry) !void`
- `fn handleSingleRequest(allocator: std.mem.Allocator, body: []const u8, handlers: *const dispatcher.HandlerRegistry) ![]u8`
- `fn handleBatch(allocator: std.mem.Allocator, batch: []jsonrpc.envelope.RequestEnvelope, handlers: *const dispatcher.HandlerRegistry) ![]u8`

5. `src/rpc/dispatcher_test.zig`
6. `src/rpc/server_test.zig`
7. `src/main_test.zig` (if needed to keep main wiring test isolated)

### Modify

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- Add envelope export.

2. `build.zig`
- Import and wire `jsonrpc` module from voltaire into ZEVM module graph.

3. `src/root.zig`
- Export `rpc` namespace and include new RPC test files in root test block.

4. `src/main.zig`
- Replace print-only stub with config parse + runtime startup wiring.

## Tests to write

### Unit tests

1. `voltaire/jsonrpc/envelope.zig`: ID parse and stringify coverage for integer, string, null.
2. `voltaire/jsonrpc/envelope.zig`: request validation (`jsonrpc == "2.0"`, method required).
3. `voltaire/jsonrpc/envelope.zig`: response success/error envelope serialization.
4. `src/rpc/dispatcher_test.zig`: unknown method -> `-32601`.
5. `src/rpc/dispatcher_test.zig`: recognized method with missing handler -> `-32601`.
6. `src/rpc/dispatcher_test.zig`: params decode failure -> `-32602`.
7. `src/rpc/dispatcher_test.zig`: handler runtime failure -> `-32603`.
8. `src/rpc/dispatcher_test.zig`: id passthrough across error cases.
9. `src/rpc/server_test.zig`: request parsing error map (`-32700`, `-32600`).
10. `src/rpc/server_test.zig`: batch response count and per-item isolation.
11. `src/rpc/server_test.zig`: config defaults and overrides.

### Integration tests

1. `src/rpc/server_test.zig`: HTTP POST single request happy path (`200`, JSON body).
2. `src/rpc/server_test.zig`: HTTP POST batch with mixed outcomes.
3. `src/rpc/server_test.zig`: malformed JSON payload returns parse error envelope.
4. `src/rpc/server_test.zig`: unknown method and invalid params paths.
5. `src/rpc/server_test.zig`: non-POST returns `405`.
6. Final integration gate: `zig build test` from ZEVM root.

## Risks and mitigations

1. Envelope type lifetime/ownership bugs across parse + serialize.
- Mitigation: keep envelope data immutable after parse, and assert cleanup in tests with `defer` paths.

2. Divergence from canonical JSON-RPC error mapping.
- Mitigation: isolate mapping in one helper and enforce per-code tests (`-32700`, `-32600`, `-32601`, `-32602`, `-32603`).

3. Batch semantics edge cases (empty array, partially invalid members).
- Mitigation: dedicated tests for empty and mixed batches before implementing batch code.

4. HTTP behavior mismatch for clients expecting `200` on JSON-RPC errors.
- Mitigation: explicit integration assertions on status code and `content-type` for all JSON-RPC responses.

5. Upstream dependency drift in method definitions.
- Mitigation: always route via `fromMethodName()` from `voltaire`; no duplicated ZEVM method lists.

6. Potential future switch to guillotine-mini dispatcher.
- Mitigation: keep `dispatcher.HandlerRegistry` boundary thin so transport and dispatch can be swapped without touching HTTP tests.

## How to verify against acceptance criteria

1. AC1 (listen on configurable host/port with defaults)
- Verify with `parseConfig` tests and integration server startup using default `127.0.0.1:8545`.

2. AC2 (single-request flow)
- Verify with HTTP POST single-request integration test returning JSON-RPC envelope.

3. AC3 (batch support)
- Verify with batch integration test asserting one response per item.

4. AC4 (canonical error codes)
- Verify via targeted unit/integration tests for `-32700`, `-32600`, `-32601`, `-32602`, `-32603`.

5. AC5 (route by method string using voltaire typing)
- Verify dispatcher tests proving `fromMethodName()` paths for eth/debug/engine.

6. AC6 (content-type and HTTP status behavior)
- Verify integration tests: `POST => 200 + application/json`, non-POST => `405`.

7. AC7 (failing-path integration coverage)
- Verify malformed payload, unknown method, invalid params integration cases are present.

8. AC8 (`zig build test` passes)
- Verify by running `zig build test` after implementing all planned steps.
