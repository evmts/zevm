# Context: implement-http-jsonrpc-server

> Historical archive note: this ticket context captures an early bootstrap inventory and may include method-family references outside the active ZEVM contract.
> Normative ZEVM behavior is defined in `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md`.
> The method catalogs below (especially `EthMethod`) are upstream inventory for dispatch/bootstrap context, not a ZEVM phase-1 support list.
> Error-code snippets below that include non-standard ranges are historical upstream references; ZEVM authoritative error semantics are in `docs/specs/json-rpc-contract.md` section 5.

## Ticket Summary

Implement the HTTP JSON-RPC 2.0 server for zevm per `docs/plans/http-jsonrpc-server-and-dispatch.md`. This is the foundational RPC layer: HTTP listener, JSON-RPC envelope parsing/serialization, method dispatch (all stubs returning -32601), batch support, CLI args, and standard error codes.

---

## Plan Document

**Path:** `docs/plans/http-jsonrpc-server-and-dispatch.md`

### Architecture Overview

```
voltaire (upstream)                    zevm (this repo)
+-------------------------------+      +-----------------------------+
| jsonrpc/envelope.zig (NEW)    |      | src/rpc_server.zig (NEW)    |
|   Request, Response, Error,   |      |   handleJsonRpc()           |
|   Id, ErrorCode, parse/serial |      |   handleSingleRequest()     |
+-------------------------------+      |   dispatchMethod()          |
| jsonrpc/eth/methods.zig       |      |   HTTP server (run())       |
|   EthMethod.fromMethodName()  |      +-----------------------------+
| jsonrpc/debug/methods.zig     |      | src/main.zig (MODIFY)       |
|   DebugMethod.fromMethodName()|      |   CLI arg parsing           |
| jsonrpc/engine/methods.zig    |      |   Server startup            |
|   EngineMethod.fromMethodName()|     +-----------------------------+
+-------------------------------+
```

### Phase Breakdown

1. **Phase 1:** Export jsonrpc module from voltaire's build.zig (already done at line 77-84)
2. **Phase 2:** Create `envelope.zig` in voltaire (Request/Response/Error/Id types with JSON serde)
3. **Phase 3:** Implement `handleJsonRpc()` pure-logic layer in zevm (JSON bytes in, JSON bytes out)
4. **Phase 4:** HTTP server layer using `std.net` + `std.http.Server`
5. **Phase 5:** CLI arg parsing in `main.zig` (--port, --host, --chain-id)
6. **Phase 6:** Verification (all tests pass, manual smoke test with curl)

### Key Design Decision

All methods return `-32601 Method not found` initially. Real handlers are added in future tickets. This lets us immediately run Hive rpc-compat tests and track progress incrementally.

---

## Files To Create

| File | Description |
|------|-------------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` | JSON-RPC 2.0 envelope types with JSON serde + tests |
| `src/rpc_server.zig` | HTTP server, JSON-RPC dispatch, handleJsonRpc() |
| `src/rpc_server_test.zig` | All RPC server tests (unit + integration) |

## Files To Modify

| File | Change |
|------|--------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig` | Add `pub const envelope = @import("envelope.zig");` |
| `build.zig` | Import `jsonrpc` module from voltaire, add to zevm + exe + test imports |
| `src/root.zig` | Add `pub const rpc_server` + test import for rpc_server_test |
| `src/main.zig` | Replace stub with CLI parsing + server startup |

---

## Upstream Dependencies

### Voltaire JSON-RPC Module (Already Exported)

**Path:** `../voltaire/packages/voltaire-zig/src/jsonrpc/`

The jsonrpc module is already exported in voltaire's `build.zig` (lines 77-84):
```zig
const jsonrpc_mod = b.addModule("jsonrpc", .{
    .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

**However**, zevm's `build.zig` does NOT yet import this module. It imports: primitives, state-manager, blockchain, crypto, precompiles, guillotine_mini. This snapshot proposed adding the `jsonrpc` module import.

#### root.zig (`../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`)
- Exports: `JsonRpc`, `eth`, `debug`, `engine`, `types`, `JsonRpcMethod`
- Snapshot proposal: add `pub const envelope = @import("envelope.zig");`

#### eth/methods.zig — `EthMethod` union(enum) with 37 variants
- `fromMethodName(method_name: []const u8) !std.meta.Tag(EthMethod)` — uses `std.StaticStringMap`
- Returns `error.UnknownMethod` for unrecognized methods
- Methods: eth_accounts, eth_blobBaseFee, eth_blockNumber, eth_call, eth_chainId, eth_coinbase, eth_createAccessList, eth_estimateGas, eth_feeHistory, eth_gasPrice, eth_getBalance, eth_getBlockByHash, eth_getBlockByNumber, eth_getBlockReceipts, eth_getBlockTransactionCountByHash, eth_getBlockTransactionCountByNumber, eth_getCode, eth_getFilterChanges, eth_getFilterLogs, eth_getLogs, eth_getProof, eth_getStorageAt, eth_getTransactionByBlockHashAndIndex, eth_getTransactionByBlockNumberAndIndex, eth_getTransactionByHash, eth_getTransactionCount, eth_getTransactionReceipt, eth_getUncleCountByBlockHash, eth_getUncleCountByBlockNumber, eth_maxPriorityFeePerGas, eth_newBlockFilter, eth_newFilter, eth_newPendingTransactionFilter, eth_sendRawTransaction, eth_sendTransaction, eth_sign, eth_signTransaction, eth_simulateV1, eth_syncing, eth_uninstallFilter
- Contract alignment note: this list is an upstream method-name inventory, not a statement of ZEVM phase-1 support.
- Contract alignment note: filter lifecycle methods beyond `eth_getLogs` (`eth_newFilter`, `eth_newBlockFilter`, `eth_newPendingTransactionFilter`, `eth_getFilterChanges`, `eth_getFilterLogs`, `eth_uninstallFilter`) are deferred/out-of-contract for ZEVM phase 1.

#### debug/methods.zig — `DebugMethod` union(enum) with 5 variants
- `fromMethodName()` — same pattern as EthMethod
- Methods: debug_getBadBlocks, debug_getRawBlock, debug_getRawHeader, debug_getRawReceipts, debug_getRawTransaction

#### engine/methods.zig — `EngineMethod` union(enum) with 20 variants
- `fromMethodName()` — same pattern
- Methods: engine_exchangeCapabilities, engine_exchangeTransitionConfigurationV1, engine_forkchoiceUpdatedV1/V2/V3, engine_getBlobsV1/V2, engine_getPayloadBodiesByHashV1, engine_getPayloadBodiesByRangeV1, engine_getPayloadV1-V6, engine_newPayloadV1-V5

#### types.zig — Shared types (all wrap `std.json.Value`)
- `Quantity` — hex-encoded unsigned integer
- `Hash` — 32-byte hex hash
- `Address` — 20-byte hex address
- `BlockTag` — latest/earliest/pending/safe/finalized
- `BlockSpec` — BlockTag or block number

#### Individual method files (e.g., eth_chainId.zig)
Each method file exports:
- `pub const method = "eth_chainId";` — method name string
- `pub const Params = struct { ... }` — with `jsonParseFromValue`, `jsonStringify`
- `pub const Result = struct { ... }` — with `jsonParseFromValue`, `jsonStringify`

### envelope.zig (TO BE CREATED)

**Path:** `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`

This file did NOT exist at the time of this snapshot. The proposal was to create it with:

```
Id           — union(enum) { integer: i64, string: []const u8, null_value: void }
               with jsonParse, jsonStringify
ErrorCode    — pub const PARSE_ERROR: i32 = -32700;
               pub const INVALID_REQUEST: i32 = -32600;
               pub const METHOD_NOT_FOUND: i32 = -32601;
               pub const INVALID_PARAMS: i32 = -32602;
               pub const INTERNAL_ERROR: i32 = -32603;
Error        — struct { code: i32, message: []const u8, data: ?std.json.Value }
Request      — struct { id: ?Id, method: []const u8, params: ?std.json.Value }
               with jsonParseFromValue (validates "jsonrpc":"2.0")
Response     — factory functions:
               makeSuccess(id: ?Id, result: anytype) -> serialized JSON bytes
               makeError(id: ?Id, code: i32, message: []const u8) -> serialized JSON bytes

Helper functions:
  parseRequest(allocator, json_bytes) -> Request | error
  parseBatchOrSingle(allocator, json_bytes) -> union { single: Request, batch: []Request } | error
  serializeResponse(allocator, response) -> []const u8
```

---

## Existing ZEVM Codebase

### build.zig
- Imports voltaire dependency and extracts: primitives, state-manager, blockchain, crypto, precompiles
- Creates guillotine_mini module from dependency
- Creates zevm module with all imports
- Creates exe from `src/main.zig` importing zevm module
- Tests use root module (src/root.zig)
- **Snapshot proposal:** add `const jsonrpc_mod = voltaire.module("jsonrpc");` and wire it into zevm, exe, and test module imports

### build.zig.zon
- Dependencies: `voltaire` (path: `../voltaire`), `guillotine-mini` (path: `../guillotine-mini`)

### src/main.zig (CURRENT — stub)
```zig
const std = @import("std");
pub fn main() !void {
    std.debug.print("zevm - Ethereum local node\n", .{});
}
```

### src/root.zig (CURRENT)
- Exports: database, blockchain, host_adapter, tx_processor, block_builder, consensus_verifier, beacon_api, consensus_sync, checkpoint
- Test block imports all test files
- **Snapshot proposal:** add `pub const rpc_server = @import("rpc_server.zig");` and `_ = @import("rpc_server_test.zig");` in test block

### Existing modules (snapshot compatibility context):
- `host_adapter.zig` — Bridges voltaire StateManager to guillotine-mini HostInterface
- `tx_processor.zig` — Transaction processing with gas accounting
- `block_builder.zig` — Block building with gas limit enforcement
- `database/` — State persistence layer
- `consensus_verifier.zig`, `beacon_api.zig`, `consensus_sync.zig`, `checkpoint.zig` — Light client consensus

---

## Zig 0.15 HTTP Server API

### std.net.Address + std.http.Server Pattern

```zig
// Listen
const address = std.net.Address.parseIp4("127.0.0.1", 8545) catch unreachable;
var server = try address.listen(.{ .reuse_address = true });
defer server.deinit();

// Accept loop
while (true) {
    const conn = try server.accept();
    defer conn.stream.close();

    // HTTP parsing
    var buf: [8192]u8 = undefined;
    var http = std.http.Server.init(conn, &buf);
    var req = try http.receiveHead();

    // Read body
    const reader = req.reader();
    const body = try reader.readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    // Respond
    try req.respond(response_bytes, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
```

### Key API Notes
- `std.net.Address.listen()` returns `std.net.Server`
- `server.accept()` returns `std.net.Server.Connection` with `.stream`
- `std.http.Server.init(connection, &buffer)` — buffer for HTTP header parsing
- `http.receiveHead()` returns a `Request` with `.method`, `.reader()`, `.respond()`
- For port 0 (random port): OS assigns, can read `server.listen_address.getPort()`
- For non-POST: respond with `.status = .method_not_allowed`

---

## Reference Implementation Patterns

### EDR (Hardhat) — `edr/crates/edr_provider/src/requests/`

**Method dispatch pattern (`methods.rs`):**
- Uses Rust `#[serde(tag = "method", content = "params")]` to deserialize directly into a `MethodInvocation<ChainSpec>` enum
- 73 methods total including eth_, debug_, hardhat_, evm_, web3_, net_, personal_ namespaces
- Additional methods not in voltaire: `net_version`, `web3_clientVersion`, `web3_sha3`, `personal_sign`, `eth_signTypedData_v4`, `eth_subscribe`, `eth_unsubscribe`, `eth_pendingTransactions`, plus all evm_* and hardhat_* methods

**Error handling (`serde.rs`):**
- `InvalidRequestReason` enum: UnsupportedMethod (-32004), InvalidStorageKey (-32000), InvalidStorageValue (-32000), InvalidJson (-32602) (EDR-specific reference, not ZEVM contract)
- Custom address/quantity/data deserialization with helpful error messages

**Request resolution (`resolve.rs`):**
- Transforms RPC types to internal transaction types
- Handles fee parameter defaults (EIP-1559, legacy)

### Hive rpc-compat Tests

**Location:** `hive/simulators/ethereum/rpc-compat/`

**Test format:** `.io` files with `>>` (request) and `<<` (expected response) pairs:
```
// retrieves the client's current block number
>> {"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}
<< {"jsonrpc":"2.0","id":1,"result":"0x2d"}
```

**Methods tested (30 total, 199 test files):**
- eth_: blobBaseFee(1), blockNumber(1), call(6), chainId(1), createAccessList(4), estimateGas(6), feeHistory(1), getBalance(3), getBlockByHash(3), getBlockByNumber(10), getBlockReceipts(8), getBlockTransactionCountByHash(2), getBlockTransactionCountByNumber(2), getCode(3), getLogs(9), getProof(3), getStorageAt(4), getTransactionByBlockHashAndIndex(1), getTransactionByBlockNumberAndIndex(1), getTransactionByHash(9), getTransactionCount(3), getTransactionReceipt(9), sendRawTransaction(5), simulateV1(91), syncing(1)
- debug_: getRawBlock(3), getRawHeader(3), getRawReceipts(3), getRawTransaction(2)
- net_: version(1)

**Test execution:**
- HTTP POST to `http://CLIENT_IP:8545` with `Content-Type: application/json`
- 5-second timeout
- jsondiff comparison (error messages are ignored, only code/data checked)
- `speconly` tests only validate JSON schema, not exact values

**Key insight for this ticket:** With all methods stubbed to -32601, every Hive test will get a "Method not found" response. This is expected — the goal is to get the server running and accepting requests. Future tickets implement actual handlers.

### JSON-RPC 2.0 Error Codes

| Code | Constant | Meaning |
|------|----------|---------|
| -32700 | PARSE_ERROR | Invalid JSON received |
| -32600 | INVALID_REQUEST | Not a valid Request object |
| -32601 | METHOD_NOT_FOUND | Method does not exist |
| -32602 | INVALID_PARAMS | Invalid method parameters |
| -32603 | INTERNAL_ERROR | Internal JSON-RPC error |

### Ethereum-Specific Error Codes (Engine API, for future use)

| Code | Meaning |
|------|---------|
| -38001 | Unknown payload |
| -38002 | Invalid forkchoice state |
| -38003 | Invalid payload attributes |
| -38004 | Too large request |
| -38005 | Unsupported fork |

---

## JSON-RPC 2.0 Batch Request Rules

Per spec:
1. Batch request = JSON array of Request objects
2. Server responds with array of Response objects
3. Empty batch `[]` -> Invalid Request error
4. Each element processed independently; partial failures OK
5. Per spec, notifications (no id) do not produce Response objects, but this snapshot's plan treated them like regular requests for simplicity
6. Response order need not match request order

---

## Guillotine-mini

Guillotine-mini is purely an EVM interpreter (`src/host.zig`, `src/bytecode.zig`, `src/opcode.zig`, etc.). It does NOT have RPC dispatch code despite what the CLAUDE.md suggests. The RPC server is entirely zevm's responsibility, using voltaire's jsonrpc types for method recognition.

---

## Zig Style Constraints

- **No local type aliases.** Always use fully qualified paths: `std.mem.Allocator`, `jsonrpc.eth.EthMethod`, etc.
- **No stored allocators.** Pass allocator explicitly to methods.
- **Zig 0.15** with lowercase `@typeInfo` variants (`.int`, `.bool`, `.float`).
- **Minimize abstractions.** Inline code except where abstraction is high leverage.
- **No useless wrapper methods.** If a method is 1-2 lines, inline it.

---

## Test Strategy

### New Tests (src/rpc_server_test.zig)

**Pure logic tests (no HTTP):**
1. `handleJsonRpc -- malformed JSON returns parse error` (-32700, null id)
2. `handleJsonRpc -- missing method returns invalid request` (-32600)
3. `handleJsonRpc -- wrong jsonrpc version returns invalid request` (-32600)
4. `handleJsonRpc -- unknown method returns method not found` (-32601)
5. `handleJsonRpc -- recognized eth_ method returns method not found (stub)` (-32601)
6. `handleJsonRpc -- debug method returns method not found (stub)` (-32601)
7. `handleJsonRpc -- string id preserved`
8. `handleJsonRpc -- null id preserved`
9. `handleJsonRpc -- batch request returns array`
10. `handleJsonRpc -- empty batch returns invalid request`
11. `handleJsonRpc -- batch with mixed valid/invalid`

**HTTP integration tests:**
12. `HTTP server responds to POST with JSON-RPC` (start server on random port, POST, verify)
13. `HTTP server rejects GET with 405`

**CLI tests:**
14. `parseArgs -- defaults` (port 8545, host 127.0.0.1, chain_id 31337)
15. `parseArgs -- custom port and host`

### Existing Tests (Snapshot Goal: Continue Passing)
- tx_processor_test.zig
- host_adapter_test.zig
- block_builder_test.zig
- consensus_verifier_test.zig
- beacon_api_test.zig
- consensus_sync_test.zig
- checkpoint_test.zig
- database/database_test.zig

---

## Implementation Order

1. Create `envelope.zig` in voltaire with types + tests
2. Add `pub const envelope = @import("envelope.zig");` to voltaire jsonrpc root.zig
3. Add `jsonrpc` module import to zevm's build.zig (zevm module, exe module, test module)
4. Create `src/rpc_server.zig` with `handleJsonRpc()` + `dispatchMethod()` + HTTP server
5. Create `src/rpc_server_test.zig` with all tests
6. Update `src/root.zig` to export rpc_server and import test file
7. Update `src/main.zig` with CLI parsing + server startup
8. Run `zig build test` to verify all tests pass

---

## Risks

1. **Zig 0.15 std.http.Server API** — API changed from 0.13/0.14. Use `std.net.Address.listen()` -> `server.accept()` -> `std.http.Server.init()` -> `receiveHead()` -> `respond()`.
2. **jsonrpc module import chain** — The jsonrpc module has no external deps (only std), so no linking issues expected.
3. **Single-threaded** — Sequential request handling is fine for dev node. Hive sends requests sequentially per test.
4. **Request body size** — Use dynamic allocation with reasonable max (10MB) to prevent OOM.
5. **Missing net_/web3_ methods in voltaire** — `net_version`, `web3_clientVersion`, `web3_sha3` are tested by Hive but not in voltaire's method enums. In this snapshot, the fallback expectation was `-32601` like other unrecognized methods.
