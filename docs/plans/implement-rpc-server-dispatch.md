# Implementation Plan: implement-rpc-server-dispatch

## Overview of the approach
Implement `src/rpc_server.zig` as a pure JSON-RPC dispatcher layer (no HTTP server in this ticket). The implementation will parse request JSON, validate JSON-RPC envelope shape, dispatch method names via upstream voltaire method maps, and return canonical JSON-RPC error responses for parse/invalid/method-not-found cases.

The plan is intentionally TDD-first and atomic: each step adds one failing test, then the minimum implementation to pass it.

## TDD step order (tests before implementation)

### Phase 1: Dispatcher skeleton and parse error path
1. Test: create `test "handleJsonRpc: malformed JSON returns -32700 with null id"` in `src/rpc_server_test.zig`.
2. Implementation: create `src/rpc_server.zig` with `pub fn handleJsonRpc(...)` and only the parse-failure branch returning JSON-RPC parse error.

### Phase 2: Single-request structural validation
3. Test: add `test "handleJsonRpc: top-level scalar returns -32600"`.
4. Implementation: add top-level kind gate (only object or array accepted).
5. Test: add `test "handleJsonRpc: object missing method returns -32600"`.
6. Implementation: add single-request object validation for required `method` string.
7. Test: add `test "handleJsonRpc: jsonrpc != 2.0 returns -32600"`.
8. Implementation: add `jsonrpc == \"2.0\"` validation.

### Phase 3: Method resolution and -32601 mapping
9. Test: add `test "handleJsonRpc: unknown method returns -32601"`.
10. Implementation: add `dispatchMethod(...)` unknown-method fallback.
11. Test: add `test "handleJsonRpc: known eth/debug/engine method still returns -32601 stub"`.
12. Implementation: add `isKnownMethod(...)` using `jsonrpc.eth.EthMethod.fromMethodName`, `jsonrpc.debug.DebugMethod.fromMethodName`, and `jsonrpc.engine.EngineMethod.fromMethodName`; keep all recognized methods stubbed to `-32601` for this ticket.

### Phase 4: Batch handling
13. Test: add `test "handleJsonRpc: empty batch returns single -32600 error object"`.
14. Implementation: add explicit `[]` batch guard.
15. Test: add `test "handleJsonRpc: batch of two valid requests returns two responses"`.
16. Implementation: add `handleBatch(...)` to iterate requests and aggregate responses in input order.
17. Test: add `test "handleJsonRpc: batch with mixed valid and invalid entries returns mixed responses"`.
18. Implementation: reuse single-request validation per element inside batch processing.

### Phase 5: ID handling correctness
19. Test: add `test "handleJsonRpc: preserves numeric and string id for non-parse errors"`.
20. Implementation: add `extractResponseId(...)` and plumb id preservation into invalid-request and method-not-found responses.
21. Test: add `test "handleJsonRpc: invalid id type is treated as null"`.
22. Implementation: normalize unsupported id shapes to JSON `null` for error responses.

### Phase 6: Project wiring and verification
23. Test: add `test "rpc_server module is reachable from root test build"`.
24. Implementation: update `src/root.zig` to export/import `rpc_server` and `rpc_server_test`.
25. Test: run `zig build test` and confirm all new and existing tests pass.
26. Implementation: if build wiring fails, update `build.zig` to import voltaire `jsonrpc` module into ZEVM module imports.

## Files to create/modify (with specific function signatures)

### Create
1. `src/rpc_server.zig`
- `pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8`
- `fn handleSingleValue(allocator: std.mem.Allocator, request_value: std.json.Value) !std.json.Value`
- `fn handleBatch(allocator: std.mem.Allocator, batch_values: []const std.json.Value) !std.json.Value`
- `fn dispatchMethod(allocator: std.mem.Allocator, request_id: std.json.Value, method_name: []const u8) !std.json.Value`
- `fn isKnownMethod(method_name: []const u8) bool`
- `fn extractResponseId(allocator: std.mem.Allocator, request_value: std.json.Value) !std.json.Value`
- `fn makeErrorResponseValue(allocator: std.mem.Allocator, request_id: std.json.Value, code: i32, message: []const u8) !std.json.Value`
- `fn serializeResponse(allocator: std.mem.Allocator, response_value: std.json.Value) ![]u8`

2. `src/rpc_server_test.zig`
- End-to-end tests that call only `handleJsonRpc(...)` and assert parsed JSON response structure.
- Focus on acceptance behavior: single request, batch request, and error-code mapping.

### Modify
1. `src/root.zig`
- `pub const rpc_server = @import("rpc_server.zig");`
- Add `_ = @import("rpc_server_test.zig");` to root `test` block.

2. `build.zig` (if needed by compile failures)
- Add voltaire module import: `const jsonrpc_mod = voltaire.module("jsonrpc");`
- Add `. { .name = "jsonrpc", .module = jsonrpc_mod }` to ZEVM module imports.

## Tests to write (unit + integration)

### Unit tests (`src/rpc_server.zig`)
1. `test "isKnownMethod: recognizes eth/debug/engine method names"`
2. `test "extractResponseId: numeric/string/null ids are preserved"`
3. `test "extractResponseId: invalid id shapes become null"`
4. `test "makeErrorResponseValue: emits jsonrpc/id/error envelope"`

### Integration tests (`src/rpc_server_test.zig`)
1. `test "handleJsonRpc: malformed JSON returns -32700"`
2. `test "handleJsonRpc: top-level scalar returns -32600"`
3. `test "handleJsonRpc: invalid request object returns -32600"`
4. `test "handleJsonRpc: unknown method returns -32601"`
5. `test "handleJsonRpc: recognized method currently returns -32601"`
6. `test "handleJsonRpc: empty batch returns single -32600"`
7. `test "handleJsonRpc: batch valid entries returns response array"`
8. `test "handleJsonRpc: batch mixed entries returns mixed errors"`
9. `test "handleJsonRpc: id preservation for integer/string/null"`

## Risks and mitigations
1. Risk: notification semantics (missing `id`) are ambiguous for this ticket scope.
- Mitigation: lock behavior in tests now (treat missing/invalid id as `null` in error responses), then adjust in HTTP-server ticket if notification suppression is required.

2. Risk: output string comparisons become brittle because JSON key order is not guaranteed.
- Mitigation: parse response JSON in tests and assert structural fields (`jsonrpc`, `id`, `error.code`, `error.message`) rather than raw string equality.

3. Risk: memory leaks while constructing `std.json.Value` trees.
- Mitigation: use `std.testing.allocator` in tests and always deinit parsed/allocated JSON values.

4. Risk: build wiring for `jsonrpc` module may be incomplete in ZEVM.
- Mitigation: include an explicit compile-path test and update `build.zig` only if compile fails.

## How to verify against acceptance criteria
1. `-32700` parse error:
- Verified by `handleJsonRpc: malformed JSON returns -32700`.

2. `-32600` invalid request:
- Verified by top-level scalar, invalid object, and empty batch tests.

3. `-32601` method not found:
- Verified by unknown method and recognized-but-unimplemented method tests.

4. Single and batch support:
- Verified by single-request tests and batch tests (valid, empty, mixed).

5. Payload structure validation:
- Verified by tests for invalid `jsonrpc`, missing `method`, and id handling.

6. Full regression safety:
- Verified by `zig build test` with existing ZEVM test suite plus new rpc_server tests.
