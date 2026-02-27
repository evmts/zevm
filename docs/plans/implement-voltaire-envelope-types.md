# TDD Plan: implement-voltaire-envelope-types

## Overview of the approach

Implement JSON-RPC 2.0 envelope primitives upstream in Voltaire at `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`, then re-export them from `jsonrpc/root.zig`.

Scope of this ticket:
1. `Id`, `Request`, `Response`, `Error`, `BatchOrSingle` data models.
2. Strict JSON-RPC 2.0 parse/serialize behavior for those models.
3. Test-first development with atomic steps (one failing test, then one implementation change).

Out of scope:
1. ZEVM handler dispatch logic.
2. HTTP transport and RPC method execution.

Decision on unexpected context file:
1. `docs/context/implement-rpc-server-dispatch.md` is unrelated to this ticket and will be left unchanged/excluded from this ticket work.

## TDD step order (tests first, then implementation)

### Phase 1: `Id`

1. Test: add `test "Id parses integer id"` in `envelope.zig`.
2. Implement: `pub const Id` with variant for integer and `pub fn jsonParseFromValue(...) !Id`.

3. Test: add `test "Id parses string id"`.
4. Implement: extend `Id.jsonParseFromValue` for string ids.

5. Test: add `test "Id parses explicit null id"`.
6. Implement: add null variant handling in `Id.jsonParseFromValue`.

7. Test: add `test "Id rejects non-integer numeric ids and non-scalar ids"` (fractional number, bool, object, array).
8. Implement: reject unsupported JSON value shapes for `Id`.

9. Test: add `test "Id stringify roundtrip for integer string and null"`.
10. Implement: `pub fn jsonStringify(self: Id, jws: *std.json.Stringify) !void`.

### Phase 2: `Error`

11. Test: add `test "Error parses code message and optional data"`.
12. Implement: `pub const Error` and `pub fn jsonParseFromValue(...) !Error`.

13. Test: add `test "Error parse fails when code or message missing/invalid"`.
14. Implement: required-field validation in `Error.jsonParseFromValue`.

15. Test: add `test "Error stringify omits data when null and includes when set"`.
16. Implement: `pub fn jsonStringify(self: Error, jws: *std.json.Stringify) !void`.

### Phase 3: `Request`

17. Test: add `test "Request parses valid method call with id and params"`.
18. Implement: `pub const Request` and `pub fn jsonParseFromValue(...) !Request`.

19. Test: add `test "Request parses notification when id field is absent"`.
20. Implement: ensure `id` is optional and absent-id is distinguishable from explicit null id.

21. Test: add `test "Request parses explicit null id as non-notification id value"`.
22. Implement: map `"id": null` to explicit null-id variant.

23. Test: add `test "Request rejects invalid jsonrpc version missing method and invalid id shape"`.
24. Implement: enforce `"jsonrpc":"2.0"`, required string `method`, and valid `id` schema.

25. Test: add `test "Request accepts params object array null and missing"`.
26. Implement: params parsing/normalization logic for all accepted shapes.

27. Test: add `test "Request stringify writes canonical JSON-RPC envelope fields"`.
28. Implement: `pub fn jsonStringify(self: Request, jws: *std.json.Stringify) !void`.

29. Test: add `test "Request.isNotification true only when id is absent"`.
30. Implement: `pub fn isNotification(self: Request) bool`.

### Phase 4: `Response`

31. Test: add `test "Response parses success envelope"`.
32. Implement: `pub const Response` and partial `jsonParseFromValue` success branch.

33. Test: add `test "Response parses error envelope"`.
34. Implement: `jsonParseFromValue` error branch using `Error`.

35. Test: add `test "Response rejects envelopes with both result and error or with neither"`.
36. Implement: enforce XOR between `result` and `error`.

37. Test: add `test "Response rejects wrong jsonrpc version and missing id"`.
38. Implement: version/id validation.

39. Test: add `test "Response stringify preserves id and emits exactly one payload branch"`.
40. Implement: `pub fn jsonStringify(self: Response, jws: *std.json.Stringify) !void`.

41. Test: add `test "Response.success and Response.failure helpers build valid envelopes"`.
42. Implement: helper constructors:
   - `pub fn success(id: Id, result: std.json.Value) Response`
   - `pub fn failure(id: Id, rpc_error: Error) Response`

### Phase 5: `BatchOrSingle`

43. Test: add `test "BatchOrSingle parses single request object"`.
44. Implement: `pub const BatchOrSingle` and `jsonParseFromValue` single-object branch.

45. Test: add `test "BatchOrSingle parses non-empty batch array"`.
46. Implement: array parsing branch with per-element `Request` parsing.

47. Test: add `test "BatchOrSingle rejects empty batch"`.
48. Implement: explicit empty-array invalid-request branch.

49. Test: add `test "BatchOrSingle rejects batch element that is not a valid request object"`.
50. Implement: propagate per-element validation failures.

51. Test: add `test "BatchOrSingle stringify writes object for single and array for batch"`.
52. Implement: `pub fn jsonStringify(self: BatchOrSingle, jws: *std.json.Stringify) !void`.

### Phase 6: Integration tests and module wiring

53. Test: add integration test `test "single request parse to response serialization roundtrip"` using raw JSON bytes -> `BatchOrSingle` parse -> `Response` serialize.
54. Implement: helper parse entry point:
   - `pub fn parseBatchOrSingle(allocator: std.mem.Allocator, json_bytes: []const u8) !BatchOrSingle`

55. Test: add integration test `test "batch with mixed notifications and calls can be parsed and responses serialized with preserved ids"`.
56. Implement: helper response serializer:
   - `pub fn stringifyResponses(allocator: std.mem.Allocator, responses: []const Response) ![]u8`

57. Test: add compile test in `jsonrpc/root.zig` confirming envelope re-export is visible.
58. Implement: `pub const envelope = @import("envelope.zig");` in `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`.

59. Test: run `cd ../voltaire && zig test packages/voltaire-zig/src/jsonrpc/envelope.zig`.
60. Implement: fix remaining failures in the smallest increments until green.

61. Test: run `cd ../voltaire && zig build test` with jsonrpc included in aggregate test step.
62. Implement: modify `../voltaire/build.zig` to add `jsonrpc` test artifact into `zig build test`.

## Files to create/modify (with specific function signatures)

### Create

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`
   - `pub const Id = union(enum) { ... }`
   - `pub fn Id.jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Id`
   - `pub fn Id.jsonStringify(self: Id, jws: *std.json.Stringify) !void`
   - `pub const Error = struct { code: i32, message: []const u8, data: ?std.json.Value, ... }`
   - `pub fn Error.jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Error`
   - `pub fn Error.jsonStringify(self: Error, jws: *std.json.Stringify) !void`
   - `pub const Request = struct { id: ?Id, method: []const u8, params: ?std.json.Value, ... }`
   - `pub fn Request.jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Request`
   - `pub fn Request.jsonStringify(self: Request, jws: *std.json.Stringify) !void`
   - `pub fn Request.isNotification(self: Request) bool`
   - `pub const Response = struct { id: Id, payload: union(enum) { result: std.json.Value, error_value: Error }, ... }`
   - `pub fn Response.jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Response`
   - `pub fn Response.jsonStringify(self: Response, jws: *std.json.Stringify) !void`
   - `pub fn Response.success(id: Id, result: std.json.Value) Response`
   - `pub fn Response.failure(id: Id, rpc_error: Error) Response`
   - `pub const BatchOrSingle = union(enum) { single: Request, batch: []Request, ... }`
   - `pub fn BatchOrSingle.jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !BatchOrSingle`
   - `pub fn BatchOrSingle.jsonStringify(self: BatchOrSingle, jws: *std.json.Stringify) !void`
   - `pub fn parseBatchOrSingle(allocator: std.mem.Allocator, json_bytes: []const u8) !BatchOrSingle`
   - `pub fn stringifyResponses(allocator: std.mem.Allocator, responses: []const Response) ![]u8`

### Modify

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
   - Add `pub const envelope = @import("envelope.zig");`.

2. `../voltaire/build.zig`
   - Add `jsonrpc` module test artifact and include it in `zig build test` aggregate step.

## Tests to write

### Unit tests (in `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`)

1. `Id` parse and stringify: integer, string, explicit null, invalid id forms.
2. `Error` parse and stringify: required fields, optional `data`, invalid shapes.
3. `Request` parse and stringify: method call, notification, explicit null id, params variants, invalid envelopes.
4. `Response` parse and stringify: success vs error, XOR enforcement, id handling, invalid envelopes.
5. `BatchOrSingle` parse and stringify: single object, non-empty batch array, empty batch rejection, invalid batch element rejection.

### Integration tests (in `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`)

1. Raw single JSON request parse to typed `Request`, then typed `Response` serialize to expected JSON shape.
2. Raw batch JSON parse to typed batch, then serialize multiple responses preserving per-request ids.
3. Batch containing notification request verifies parsed notification detection (`Request.isNotification`) so downstream dispatcher can omit response.

## Risks and mitigations

1. Risk: JSON number handling may accidentally accept fractional ids.
   - Mitigation: explicit failing tests for fractional and scientific-notation ids; reject non-integer forms.

2. Risk: Inability to distinguish absent `id` vs explicit `id: null`.
   - Mitigation: represent `Request.id` as optional `Id` where explicit null is an `Id` variant, plus `Request.isNotification` tests.

3. Risk: Response shape drift (`result` and `error` both present or both missing).
   - Mitigation: XOR validation tests and strict parse checks before accepting response objects.

4. Risk: Empty batch behavior diverges from JSON-RPC 2.0.
   - Mitigation: dedicated empty-batch rejection test in `BatchOrSingle`.

5. Risk: Envelope tests are not run by default in Voltaire CI/test command.
   - Mitigation: add jsonrpc test artifact to `../voltaire/build.zig` and verify `zig build test` executes it.

## How to verify against acceptance criteria

1. `Id`, `Request`, `Response`, `Error`, and `BatchOrSingle` exist in `jsonrpc/envelope.zig`.
2. Each type has parse + stringify tests that pass.
3. JSON-RPC 2.0 invariants are enforced by tests:
   - request version validation
   - response result/error exclusivity
   - request id schema
   - non-empty batch requirement
4. Envelope is accessible through `jsonrpc.root` re-export.
5. `cd ../voltaire && zig test packages/voltaire-zig/src/jsonrpc/envelope.zig` passes.
6. `cd ../voltaire && zig build test` passes with jsonrpc tests included.
