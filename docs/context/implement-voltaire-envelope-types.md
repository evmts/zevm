# Research Context: `implement-voltaire-envelope-types`

## Ticket
Add JSON-RPC envelope primitives in Voltaire Zig at:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`

Target primitives:
- `Id`
- `Request`
- `Response`
- `Error`
- `BatchOrSingle`

Category:
- `cat-1-rpc-server`

## Executive Summary
Voltaire Zig already has method-specific JSON-RPC types (`eth_*`, `engine_*`, `debug_*`) but does **not** yet have transport envelope primitives. The implementation should follow JSON-RPC 2.0 semantics first, then align Ethereum-specific error codes with EIP-1474.

The most important behavioral points to encode are:
1. Request `id` supports string, number, or null; missing `id` means notification.
2. Response must contain exactly one of `result` or `error`.
3. Batch requests are object-or-array at the top level; empty batch is invalid.
4. Parse/invalid request errors should use `id: null`.
5. Batch responses must omit notification-only calls; if all entries are notifications, produce no response payload.

## Normative Specs (What to Implement Against)

### JSON-RPC 2.0 (primary)
Source:
- https://www.jsonrpc.org/specification

Key rules extracted:
- Request object:
  - `jsonrpc` must be exactly `"2.0"`.
  - `method` is required string.
  - `params` is optional (object/array in spec; many clients tolerate null/missing).
  - `id` is optional; when present: string/number/null. Numbers should not be fractional.
- Notification:
  - A request without `id` is a notification.
  - Server must not reply to notifications.
- Response object:
  - Must include `jsonrpc: "2.0"` and `id`.
  - Must include exactly one of:
    - `result` (success)
    - `error` (failure)
  - `error` contains `code`, `message`, optional `data`.
- Batch:
  - Request may be an array of request objects.
  - Empty array is invalid request (`-32600`).
  - Invalid batch (empty array) should return a single error object (not a response array).
  - If batch contains only notifications, server returns no response body.

### EIP-1474 (Ethereum RPC conventions)
Source:
- `EIPs/EIPS/eip-1474.md`

Key rules extracted:
- Ethereum RPC methods must be called via JSON-RPC request objects and return JSON-RPC response objects.
- Error object must contain `code` and `message`.
- Error code set used by ecosystem:
  - Standard JSON-RPC:
    - `-32700` Parse error
    - `-32600` Invalid request
    - `-32601` Method not found
    - `-32602` Invalid params
    - `-32603` Internal error
  - Ethereum non-standard range commonly used:
    - `-32000` Invalid input
    - `-32001` Resource not found
    - `-32002` Resource unavailable
    - `-32003` Transaction rejected
    - `-32004` Method not supported
    - `-32005` Limit exceeded
    - `-32006` JSON-RPC version not supported

### Project product spec
Source:
- `docs/specs/prd.md`

Relevant requirements:
- JSON-RPC 2.0 request/response handling.
- Batch support.
- Standard error codes (`-32700`, `-32600`, `-32601`, `-32602`, `-32603`).

## Existing Voltaire Zig Status

Paths reviewed:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/{Address.zig,Hash.zig,Quantity.zig,BlockSpec.zig}`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig`

Findings:
- Voltaire Zig has generated method unions and per-method `Params`/`Result` types.
- `jsonrpc/envelope.zig` does not exist.
- JSON serde style in Voltaire uses `jsonStringify` / `jsonParseFromValue` on structs.
- `build.zig` already exports `jsonrpc` module:
  - `../voltaire/build.zig` contains `b.addModule("jsonrpc", ...)`.

Implication:
- This ticket is a direct addition in Voltaire Zig; ZEVM should consume that type rather than duplicating envelopes locally.

## Requested Path Sweep

### `docs/specs/`
- File read: `docs/specs/prd.md`
- Usefulness: confirms JSON-RPC 2.0 + batch + canonical error-code requirements.

### `../voltaire/packages/voltaire-zig/src/jsonrpc/`
- Read method/type roots and representative files.
- Usefulness: defines style and interfaces envelope types should match.
- Gap: no envelope primitives yet.

### `../voltaire/packages/voltaire-zig/src/state-manager/`
- Reviewed via targeted search.
- Usefulness: no transport envelope implementation; only internal fork RPC bridging/request IDs.
- Relevance to ticket: low.

### `../voltaire/packages/voltaire-zig/src/blockchain/`
- Reviewed via targeted search.
- Usefulness: no JSON-RPC envelope structures; internal async request queues only.
- Relevance: low.

### `../voltaire/packages/voltaire-zig/src/evm/`
- Reviewed via targeted search.
- Usefulness: EVM execution only; no envelope logic.
- Relevance: low.

### `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/`
- **Missing in this workspace** (`../bench` directory not present).
- Actual dependency path `../guillotine-mini` exists but does not include these `client/...` paths.
- Fallback inspected for context only:
  - `../gmini-review-zlI2Lu/client/rpc/*`
  - `../gmini-review-zlI2Lu/client/engine/*`
- Fallback shows useful routing/error-code patterns but is not in the declared dependency path.

### `edr/crates/edr_provider/src/requests/`
Files read:
- `edr/crates/edr_provider/src/requests.rs`
- `edr/crates/edr_provider/src/requests/serde.rs`
- `edr/crates/edr_provider/src/requests/methods.rs`
- `edr/crates/edr_rpc_client/src/jsonrpc.rs`
- `edr/crates/edr_napi_core/src/{provider.rs,spec.rs}`

High-signal behaviors:
- Custom single-or-batch deserializer (not plain untagged derive) to preserve better errors.
- Strong `ResponseData` success/error union shape.
- Strict version parse (`"2.0"`).
- `Id` in `edr_rpc_client` is number/string (no null variant there), but comments acknowledge JSON-RPC null semantics.
- EDR request parse error mapping is implementation-specific in places (`InvalidRequestReason`), so treat as reference, not strict norm.

### `foundry/`
Files read:
- `foundry/crates/anvil/rpc/src/request.rs`
- `foundry/crates/anvil/rpc/src/response.rs`
- `foundry/crates/anvil/rpc/src/error.rs`
- `foundry/crates/anvil/server/src/{handler.rs,lib.rs,pubsub.rs}`

High-signal behaviors:
- `Id` supports string/number/null.
- Requests modeled as `Single | Batch` and `MethodCall | Notification | Invalid`.
- `params: null` is normalized to none.
- Response modeled as exactly success-or-error via flattened enum.
- Batch handling removes notification responses; when resulting batch is empty, top-level handler returns invalid-request error (implementation choice).

### `hardhat/`
Files read:
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/json-rpc.ts`
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/provider-errors.ts`
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/node/json-rpc/handler.ts`
- `hardhat/v-next/hardhat/src/types/providers.ts`

High-signal behaviors:
- Parse errors mapped to `-32700`; invalid request to `-32600`.
- Request validator requires array params in current implementation.
- Request `id` allowed as number/string in request types; response `id` allows number/string/null.
- Node handler notes provider does not truly support batch yet, but still processes arrays at handler layer.

### `../tevm-monorepo/packages/actions/src/`
Files read:
- `../tevm-monorepo/packages/actions/src/requestProcedure.js`
- `../tevm-monorepo/packages/actions/src/requestBulkProcedure.js`
- `../tevm-monorepo/packages/actions/src/createHandlers.js`
- `../tevm-monorepo/packages/jsonrpc/src/{JsonRpcRequest.ts,JsonRpcResponse.ts,createJsonRpcFetcher.js}`

High-signal behaviors:
- Request `id` is optional (`string | number | null`) to represent notification style.
- Response types enforce result/error exclusivity.
- Bulk procedure processes each request and preserves per-request IDs in responses.

### `execution-apis/`
Files read:
- `execution-apis/README.md`
- `execution-apis/docs-api/docs/tests.md`
- sampled fixtures under `execution-apis/tests/*`

High-signal behaviors:
- Conformance tests use single round-trip `.io` format (`>> request`, `<< response`).
- Fixtures consistently use `jsonrpc: "2.0"`, `id`, and either `result` or `error`.
- Envelope edge cases (invalid JSON, batch notifications) are mostly exercised via clients/simulators, not heavily encoded as dedicated fixtures here.

### `execution-specs/src/ethereum/`
- Targeted scan found no direct JSON-RPC envelope semantics in this subtree.
- Relevance: minimal for this ticket.

### `ethereum-tests/`
Files read:
- `ethereum-tests/docs/rpc-ref.rst`

Usefulness:
- Provides many JSON-RPC request/response examples and method-specific expectations.
- Relevance is mostly illustrative, not normative for envelope edge cases.

### `execution-spec-tests/tests/`
- Minimal envelope-related content; mostly execution semantics.
- Only incidental JSON-RPC examples in comments.

### `EIPs/EIPS/`
- File read: `EIPs/EIPS/eip-1474.md`
- High relevance for Ethereum JSON-RPC error code conventions.

### `consensus-specs/specs/`
- Reviewed with targeted search.
- Mentions Engine API interaction and occasional `eth_getBlockByHash` references.
- No direct JSON-RPC envelope grammar.

### `yellowpaper/`
- Reviewed with targeted search.
- Focuses on wire protocol/p2p internals, not JSON-RPC envelope.
- Not relevant for this ticket.

### `hive/simulators/ethereum/`
Files read:
- `hive/simulators/ethereum/rpc-compat/{main.go,README.md,testload.go,testload_speconly_test.go}`

High-signal behaviors:
- `rpc-compat` compares request/response payloads against execution-apis test fixtures.
- Supports a `speconly` mode that validates response structure/types.
- Important for integration validation once envelope types are wired into server handling.

## Cross-Implementation Behavior Matrix (Envelope-Level)

### `id` shape
- JSON-RPC spec: string/number/null when present, optional for notifications.
- Foundry: string/number/null.
- Hardhat: request validator accepts string/number; response allows null.
- EDR `edr_rpc_client`: string/number in concrete type, comments acknowledge null in spec.
- tevm/voltaire-ts: string/number/null.

### Success vs error response shape
- JSON-RPC spec: exactly one of `result` or `error`.
- Foundry/voltaire-ts/tevm models encode this clearly.
- Hardhat validator checks at least one exists; exclusivity is handled in higher-level flow.

### Batch semantics
- JSON-RPC spec:
  - empty request array is invalid (`-32600`)
  - notification-only batch yields no response
- Foundry handler drops notifications; implementation currently turns fully-empty output into invalid request response.
- tevm bulk always returns per-request outputs (request model expects id).

## Recommended Voltaire Envelope Design

## Types
- `Id`
  - union(enum): number, string, null
- `Error`
  - `code: i32`
  - `message: []const u8`
  - `data: ?std.json.Value = null`
- `Request`
  - `jsonrpc: []const u8` (must be `"2.0"`)
  - `method: []const u8`
  - `params: ?std.json.Value` (keep raw)
  - `id: ?Id` (null/absent => notification)
- `Response`
  - `jsonrpc: []const u8 = "2.0"`
  - `id: ?Id`
  - `result: ?std.json.Value = null`
  - `error: ?Error = null`
  - helper validation: exactly one of result/error
- `BatchOrSingle(comptime T: type)`
  - union(enum): `single: T`, `batch: []T`
  - parse helper should reject empty batch for requests

## Parsing/validation policy
- Strictly enforce `jsonrpc == "2.0"` at envelope parse time.
- Require request `method` string.
- Treat missing `params` as null/none.
- Accept `params: null` as none for compatibility.
- Treat invalid `id` type as invalid request.
- Top-level request parser should distinguish:
  - invalid JSON parse => `-32700`
  - structurally wrong envelope => `-32600`

## Serialization policy
- `Response` serializer should emit only one of:
  - `result`
  - `error`
- Preserve `id` exactly from request for non-parse errors.
- Use `id: null` for parse/invalid-request where request ID is unavailable.

## Export wiring
Also update:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`

To export:
- `pub const envelope = @import("envelope.zig");`

## Suggested Test Matrix for `envelope.zig`

### `Id`
- Parse/serialize number, string, null.
- Reject object/array/bool IDs.
- Reject fractional numbers if represented as float values.

### `Request`
- Valid: with id number/string/null.
- Valid notification: missing id.
- Invalid: missing method.
- Invalid: wrong `jsonrpc` version.
- Params cases: missing, null, array, object.

### `Response`
- Valid success (`result` only).
- Valid error (`error` only).
- Invalid both result and error present.
- Invalid neither present.

### `BatchOrSingle`
- Single object parse.
- Batch parse (non-empty).
- Empty batch rejected as invalid request.
- Mixed batch including notifications should parse; response suppression happens at server layer.

## Notes on Scope Boundaries
- This ticket is **envelope primitives only** in Voltaire Zig.
- No RPC transport/server behavior should be duplicated in ZEVM for this work.
- If any shared behavior is missing in Voltaire or declared upstream dependency, add there first, then consume from ZEVM.

## Sources
- JSON-RPC spec: https://www.jsonrpc.org/specification
- EIP-1474: `EIPs/EIPS/eip-1474.md`
- Voltaire Zig JSON-RPC module: `../voltaire/packages/voltaire-zig/src/jsonrpc/`
- Foundry Anvil RPC envelope refs:
  - `foundry/crates/anvil/rpc/src/request.rs`
  - `foundry/crates/anvil/rpc/src/response.rs`
  - `foundry/crates/anvil/rpc/src/error.rs`
  - `foundry/crates/anvil/server/src/handler.rs`
- Hardhat v-next JSON-RPC refs:
  - `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/json-rpc.ts`
  - `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/provider-errors.ts`
  - `hardhat/v-next/hardhat/src/internal/builtin-plugins/node/json-rpc/handler.ts`
- EDR refs:
  - `edr/crates/edr_provider/src/requests.rs`
  - `edr/crates/edr_provider/src/requests/serde.rs`
  - `edr/crates/edr_rpc_client/src/jsonrpc.rs`
- tevm refs:
  - `../tevm-monorepo/packages/actions/src/requestProcedure.js`
  - `../tevm-monorepo/packages/actions/src/requestBulkProcedure.js`
  - `../tevm-monorepo/packages/jsonrpc/src/JsonRpcRequest.ts`
  - `../tevm-monorepo/packages/jsonrpc/src/JsonRpcResponse.ts`
- execution-apis conformance refs:
  - `execution-apis/docs-api/docs/tests.md`
  - `execution-apis/tests/*`
- hive rpc-compat refs:
  - `hive/simulators/ethereum/rpc-compat/main.go`
  - `hive/simulators/ethereum/rpc-compat/testload.go`
