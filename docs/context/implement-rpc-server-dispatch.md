# Context: implement-rpc-server-dispatch

## Ticket

- **Id:** `implement-rpc-server-dispatch`
- **Category:** `cat-1-rpc-server`
- **Goal:** create `src/rpc_server.zig` and implement `handleJsonRpc` for single and batch JSON-RPC requests with correct validation and error codes (`-32700`, `-32600`, `-32601`).
- **Date:** 2026-02-27

## Current ZEVM State (Relevant Existing Implementation)

- `src/rpc_server.zig` does not exist yet.
- `src/main.zig` is still a stub that only prints a banner.
- `src/root.zig` has no RPC server export/tests wired yet.
- `build.zig` imports voltaire modules `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles`, but not `jsonrpc`.
- `../voltaire/build.zig` already exports a `jsonrpc` module, so ZEVM can import it directly when implementing dispatch.

## Dispatch Semantics To Implement (Normative)

Primary sources for request validity and error mapping:

- `EIPs/EIPS/eip-1474.md`
- `execution-apis/src/engine/common.md`

Required behavior for this ticket:

1. Malformed JSON input -> JSON-RPC error `-32700` (Parse error), `id: null`.
2. Valid JSON but not a valid Request object -> `-32600` (Invalid request).
3. Unknown/unimplemented method -> `-32601` (Method not found), preserving request `id` when present and valid.
4. Batch requests:
   - Top-level non-empty array -> process each element independently and return response array.
   - Empty array `[]` -> `-32600` invalid request (single error object).
5. Parse error vs invalid request distinction:
   - JSON parse failure -> `-32700`.
   - Parsed value is not request object/array shape -> `-32600`.

## Reference Path Inventory (Requested Paths)

### 1) `docs/specs/`

- **Read:** `docs/specs/prd.md`
- **Relevant findings:**
  - RPC server is a core deliverable.
  - Explicitly requires JSON-RPC 2.0, batch support, and standard error codes.
  - Mentions reusing voltaire JSON-RPC types.

### 2) `../voltaire/packages/voltaire-zig/src/jsonrpc/`

- **Read:** `root.zig`, `JsonRpc.zig`, `eth/methods.zig`, `debug/methods.zig`, `engine/methods.zig`
- **Relevant findings:**
  - `root.zig` exports `JsonRpc`, `eth`, `debug`, `engine`, `types`.
  - Method-name resolution exists and is authoritative:
    - `jsonrpc.eth.fromMethodName(...)`
    - `jsonrpc.debug.fromMethodName(...)`
    - `jsonrpc.engine.fromMethodName(...)`
  - Unknown method resolution returns `error.UnknownMethod`.
  - Useful for namespace/method recognition in dispatcher without re-defining method tables.
  - No envelope helpers are exported from `root.zig` right now.

### 3) `../voltaire/packages/voltaire-zig/src/state-manager/`

- **Read:** `root.zig`, `StateManager.zig`, `ForkBackend.zig`
- **Relevant findings:**
  - Not needed to implement raw JSON-RPC dispatch itself.
  - Confirms future handler wiring targets (`StateManager`, `ForkBackend`) are upstream and should be reused.

### 4) `../voltaire/packages/voltaire-zig/src/blockchain/`

- **Read:** `root.zig`, `Blockchain.zig`, `ForkBlockCache.zig`
- **Relevant findings:**
  - Not needed for envelope/dispatch correctness directly.
  - Confirms block query handlers should wire to upstream `Blockchain` / `ForkBlockCache` rather than local replacements.

### 5) `../voltaire/packages/voltaire-zig/src/evm/`

- **Read:** `evm.zig` (+ `precompiles/root.zig` for context)
- **Relevant findings:**
  - Not directly required for `handleJsonRpc`, but confirms EVM execution is upstream infrastructure.
  - Dispatcher should remain a thin routing/validation layer.

### 6) `../bench/guillotine-mini/client/rpc/`

- **Status:** path not present in this workspace.
- **Fallback used:** `../gmini-review-zlI2Lu/client/rpc/`
- **Read:** `dispatch.zig`, `error.zig`, `server.zig`, `root.zig`
- **Relevant findings:**
  - `dispatch.zig` shows a practical prefix + `fromMethodName` namespace resolver.
  - Top-level request shape checks are done before namespace resolution.
  - `error.zig` validates EIP-1474 code/message expectations.
  - Batch handling appears separated from `parseRequestNamespace` (it treats arrays as invalid in that helper).

### 7) `../bench/guillotine-mini/client/engine/`

- **Status:** path not present in this workspace.
- **Fallback used:** `../gmini-review-zlI2Lu/client/engine/`
- **Read:** `api.zig`
- **Relevant findings:**
  - Contains explicit constants for `-32700`, `-32600`, `-32601`, etc. aligned with execution-apis Engine common definitions.
  - Confirms error-code vocabulary expected across RPC/Engine surfaces.

### 8) `edr/crates/edr_provider/src/requests/`

- **Read:** `requests.rs`, `requests/serde.rs`, plus `edr_provider/src/provider.rs` and `edr_rpc_client/src/jsonrpc.rs` for end-to-end request handling.
- **Relevant findings:**
  - `ProviderRequest` deserializes as `Single` or `Batch` via custom visitor.
  - Provider dispatches single/batch in separate paths.
  - Useful pattern: parse request envelope first, then method dispatch.
  - EDR has custom invalid-request reason mapping; useful as contrast but not strictly canonical for this ticket.

### 9) `foundry/`

- **Read:** `foundry/crates/anvil/rpc/src/request.rs`, `foundry/crates/anvil/rpc/src/error.rs`, `foundry/crates/anvil/server/src/handler.rs`
- **Relevant findings:**
  - Explicit envelope model:
    - `Request = Single | Batch`
    - `RpcCall = MethodCall | Notification | Invalid`
  - Canonical error code enum for parse/invalid request/method not found.
  - Batch path returns invalid request for invalid calls and omits notifications.
  - Strong reference for per-item batch validation behavior.

### 10) `hardhat/`

- **Read:** `hardhat/v-next/hardhat/src/internal/builtin-plugins/node/json-rpc/handler.ts`, `.../network-manager/json-rpc.ts`, `.../network-manager/provider-errors.ts`
- **Relevant findings:**
  - Transport reads JSON first; malformed JSON is converted to parse error (`-32700`).
  - Supports single and batch transport handling.
  - Strict request validators for `jsonrpc`, `id`, `method`, and `params` shape.
  - Error classes map directly to EIP-1474 codes.

### 11) `../tevm-monorepo/packages/actions/src/`

- **Read:** `requestProcedure.js`, `requestBulkProcedure.js`, `createHandlers.js`
- **Relevant findings:**
  - Explicit method map dispatcher with method-not-found fallback.
  - Bulk procedure processes each request independently and aggregates responses.
  - Good reference for simple, pragmatic dispatch-table architecture.

### 12) `execution-apis/`

- **Read:** `execution-apis/src/engine/common.md`, sample tests in `execution-apis/tests/*.io`
- **Relevant findings:**
  - Engine common doc includes canonical JSON-RPC error list including `-32700`, `-32600`, `-32601`.
  - Test `.io` format confirms expected request/response envelope shapes used by compatibility suites.
  - Sample fixtures show standard `"jsonrpc":"2.0"`, `"id"`, `"method"` patterns.

### 13) `execution-specs/src/ethereum/`

- **Read:** directory scan and keyword search.
- **Relevant findings:**
  - Primarily execution/state transition spec content.
  - No direct JSON-RPC dispatch guidance for this ticket.

### 14) `ethereum-tests/`

- **Read:** repository scan, `JSONSchema` references.
- **Relevant findings:**
  - Mostly execution/state test corpus, not request dispatcher behavior.
  - Some JSON schema material reinforces hex quantity/data encoding expectations for later handler param validation.

### 15) `execution-spec-tests/tests/`

- **Read:** directory scan and keyword search.
- **Relevant findings:**
  - Execution/fork behavior test corpus; not direct JSON-RPC dispatcher design.
  - Useful later for method semantics, not for transport-level `handleJsonRpc`.

### 16) `EIPs/EIPS/`

- **Read:** `eip-1474.md`, `eip-1898.md`
- **Relevant findings:**
  - `eip-1474` provides standard JSON-RPC error codes/messages and request/response framing expectations.
  - `eip-1898` is relevant for later param parsing (`BlockSpec` object form), not dispatch envelope parsing.

### 17) `consensus-specs/specs/`

- **Read:** repo scan (bellatrix/capella/deneb references).
- **Relevant findings:**
  - Useful for Engine API execution semantics and CL/EL interaction.
  - Not a primary source for JSON-RPC transport validation logic.

### 18) `yellowpaper/`

- **Read:** repo scan, `JS.tex` presence.
- **Relevant findings:**
  - Historical background only; not normative for modern JSON-RPC 2.0 transport behavior.

### 19) `hive/simulators/ethereum/`

- **Read:** `hive/simulators/ethereum/rpc-compat/main.go`, `testload.go`
- **Relevant findings:**
  - RPC-compat harness posts JSON to `:8545` and compares response bodies.
  - Harness ignores `error.message` text when both expected/actual contain `error`, focusing heavily on structural correctness and code values.
  - Confirms that dispatcher-level correctness (shape/codes/id) is critical for passing compatibility tests.

## Cross-Implementation Behavior Notes (Most Useful for `handleJsonRpc`)

- **Foundry**: strong typed envelope with invalid-element handling in batch and notification omission.
- **Hardhat**: strict validation pipeline and explicit parse-error handling before request validation.
- **EDR**: separate single vs batch parse and dispatch path.
- **TEVM**: simple method-map dispatcher and independent per-item batch handling.
- **Voltaire**: canonical Ethereum method name maps (`fromMethodName`) for namespace/method recognition.

## Recommended Dispatcher Design for ZEVM

Implementation should stay thin and deterministic:

1. Parse bytes into `std.json.Value`.
2. On parse failure, return one JSON-RPC error object (`-32700`, `id: null`).
3. Branch:
   - object -> handle single request
   - array -> handle batch request (non-empty only)
   - anything else -> invalid request (`-32600`)
4. For each request object:
   - validate required structure (`jsonrpc == "2.0"`, `method` string, `params` shape if enforced)
   - invalid structure -> `-32600`
   - resolve method with voltaire `fromMethodName` helpers
   - if not found -> `-32601`
   - if recognized but unimplemented in this ticket -> also `-32601` (stub dispatch)
5. Preserve `id` for non-parse errors when request contains a valid JSON-RPC id value; use `null` otherwise.

## Suggested Test Matrix for This Ticket

- malformed JSON -> `-32700`, `id:null`
- top-level scalar (`"x"`, `1`, `true`) -> `-32600`
- object missing method -> `-32600`
- wrong `jsonrpc` version -> `-32600`
- unknown method -> `-32601`
- known `eth_`/`debug_`/`engine_` method but not implemented -> `-32601`
- batch with two valid request objects -> two responses
- empty batch -> single `-32600`
- batch with mixed valid/invalid objects -> mixed response entries
- id preservation for number/string/null

## Open Decisions (Flag Before Implementation)

1. **Notifications (missing `id`)**:
   - JSON-RPC spec says do not respond.
   - Existing internal planning docs previously tolerated always-respond behavior for simplicity.
   - Decide explicitly before coding tests.

2. **`params` strictness**:
   - Some clients require params array/object; others default missing params to `[]`.
   - Decide whether to enforce strict request validation now or defer to handler-level parsing.
