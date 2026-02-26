# Plan: HTTP JSON-RPC Server with Method Dispatch

## Overview

Implement the foundational HTTP JSON-RPC 2.0 server for zevm. This is the single highest-impact feature -- without it, nothing else works. The server will:

1. Listen on a configurable port (default 8545)
2. Parse JSON-RPC 2.0 request envelopes (id, method, params)
3. Serialize JSON-RPC 2.0 response envelopes (result/error with id)
4. Handle batch requests (JSON array -> array of responses)
5. Return standard error codes (-32700, -32600, -32601, -32602, -32603)
6. Dispatch methods using voltaire's `fromMethodName()` StaticStringMaps
7. Parse CLI args: `--port`, `--host`, `--chain-id`

**Key design decision:** Start with ALL methods returning `-32601 Method not found`. This lets us immediately run Hive rpc-compat tests and track progress incrementally.

## Architecture

```
                         voltaire (upstream, we own)
                         +---------------------------------+
                         | jsonrpc/envelope.zig  (NEW)     |
                         |   Request, Response, Error, Id  |
                         |   ErrorCode constants            |
                         |   parseRequest(), makeResponse() |
                         +---------------------------------+
                         | jsonrpc/eth/methods.zig          |
                         |   EthMethod.fromMethodName()    |
                         | jsonrpc/debug/methods.zig        |
                         |   DebugMethod.fromMethodName()  |
                         | jsonrpc/engine/methods.zig       |
                         |   EngineMethod.fromMethodName() |
                         +---------------------------------+

                         zevm (this repo)
                         +---------------------------------+
                         | src/rpc_server.zig               |
                         |   handleConnection()             |
                         |   handleJsonRpc()                |
                         |   dispatchMethod()               |
                         +---------------------------------+
                         | src/main.zig                     |
                         |   CLI arg parsing                |
                         |   Server startup                 |
                         +---------------------------------+
```

## Critical Pre-requisites (voltaire changes)

1. **Export jsonrpc module** from voltaire's build.zig -- the types exist but aren't wired up as a build module
2. **Add envelope.zig** to voltaire's jsonrpc module -- JSON-RPC 2.0 Request/Response/Error/Id types with JSON serde
3. **Re-export envelope** from jsonrpc/root.zig

Note: `net_version` and `web3_*` methods don't exist in voltaire yet. The hive rpc-compat suite tests `net_version` (1 test). We'll handle unrecognized methods (including these) with -32601.

## TDD Step Order

### Phase 1: Voltaire -- Export jsonrpc module (build system)

**Step 1.1: Test -- verify jsonrpc module can be imported by zevm**

- File: `src/rpc_server_test.zig` (new)
- Test: `test "jsonrpc module imports successfully"` -- just import the module and check `jsonrpc.eth.EthMethod` exists via `@hasDecl`
- This test will fail until we wire up the module in voltaire's build.zig and zevm's build.zig

**Step 1.2: Implementation -- add jsonrpc module to voltaire's build.zig**

- File: `../voltaire/build.zig`
- Add:
  ```zig
  const jsonrpc_mod = b.addModule("jsonrpc", .{
      .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
      .target = target,
      .optimize = optimize,
  });
  ```
- No other module dependencies needed -- jsonrpc types are pure Zig structs wrapping `std.json.Value`

**Step 1.3: Implementation -- import jsonrpc in zevm's build.zig**

- File: `build.zig`
- Add: `const jsonrpc_mod = voltaire.module("jsonrpc");`
- Add `jsonrpc` import to zevm module, exe module, and test module

### Phase 2: Voltaire -- JSON-RPC 2.0 Envelope Types

**Step 2.1: Test -- envelope type serde (in voltaire)**

- File: `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` (new, tests at bottom)
- Tests:
  - `test "Id -- parse integer"` -- parse `1` -> `.integer = 1`
  - `test "Id -- parse string"` -- parse `"abc"` -> `.string = "abc"`
  - `test "Id -- parse null"` -- parse `null` -> `.null_value`
  - `test "Id -- serialize integer"` -- `.integer = 1` -> `1`
  - `test "Id -- serialize string"` -- `.string = "abc"` -> `"abc"`
  - `test "Id -- serialize null"` -- `.null_value` -> `null`
  - `test "Request -- parse valid request"` -- parse `{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}` -> correct fields
  - `test "Request -- parse request with params"` -- parse `{"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["0xabc","latest"]}` -> params is array
  - `test "Request -- parse notification (no id)"` -- parse `{"jsonrpc":"2.0","method":"eth_subscribe"}` -> id is null
  - `test "Response -- serialize success"` -- success response -> `{"jsonrpc":"2.0","id":1,"result":"0x1"}`
  - `test "Response -- serialize error"` -- error response -> `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}`
  - `test "Response -- serialize null id"` -- null-id error (parse error) -> `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}`
  - `test "ErrorCode constants"` -- verify PARSE_ERROR == -32700, etc.

**Step 2.2: Implementation -- envelope types**

- File: `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` (new)
- Types:
  ```
  Id           -- union(enum) { integer: i64, string: []const u8, null_value: void }
                  with jsonParse, jsonStringify
  ErrorCode    -- pub const PARSE_ERROR: i32 = -32700; etc.
  Error        -- struct { code: i32, message: []const u8, data: ?std.json.Value }
                  with jsonStringify
  Request      -- struct { id: ?Id, method: []const u8, params: ?std.json.Value }
                  with jsonParseFromValue (validates "jsonrpc":"2.0")
  Response     -- struct with factory functions:
                  makeSuccess(id: ?Id, result: anytype) -> serialized JSON bytes
                  makeError(id: ?Id, code: i32, message: []const u8) -> serialized JSON bytes
  ```
- Helper functions:
  ```
  parseRequest(allocator, json_bytes) -> Request | error
  parseBatchOrSingle(allocator, json_bytes) -> union { single: Request, batch: []Request } | error
  serializeResponse(allocator, response) -> []const u8
  ```

**Step 2.3: Implementation -- re-export from jsonrpc root.zig**

- File: `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- Add: `pub const envelope = @import("envelope.zig");`

### Phase 3: ZEVM -- RPC Server Core (handleJsonRpc)

This is the pure-logic layer, tested without HTTP. It takes JSON bytes in, returns JSON bytes out.

**Step 3.1: Test -- malformed JSON returns parse error**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- malformed JSON returns parse error"`
  - Input: `"not json at all"`
  - Expected output: `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}`

**Step 3.2: Test -- missing method field returns invalid request**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- missing method returns invalid request"`
  - Input: `{"jsonrpc":"2.0","id":1}`
  - Expected output: `{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid request"}}`

**Step 3.3: Test -- wrong jsonrpc version returns invalid request**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- wrong jsonrpc version returns invalid request"`
  - Input: `{"jsonrpc":"1.0","id":1,"method":"eth_chainId"}`
  - Expected output: `{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid request"}}`

**Step 3.4: Test -- unknown method returns method not found**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- unknown method returns method not found"`
  - Input: `{"jsonrpc":"2.0","id":1,"method":"foo_bar"}`
  - Expected output: `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}`

**Step 3.5: Test -- recognized eth_ method returns method not found (stub)**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- recognized method returns method not found (stub dispatcher)"`
  - Input: `{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}`
  - Expected output: `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}`
  - (All recognized methods return -32601 initially; handlers added in future tickets)

**Step 3.6: Test -- recognized debug_ method returns method not found**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- debug method returns method not found (stub)"`
  - Input: `{"jsonrpc":"2.0","id":42,"method":"debug_getRawBlock","params":["0x1"]}`
  - Expected output: `{"jsonrpc":"2.0","id":42,"error":{"code":-32601,"message":"Method not found"}}`

**Step 3.7: Test -- string id is preserved**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- string id preserved"`
  - Input: `{"jsonrpc":"2.0","id":"my-request","method":"eth_blockNumber"}`
  - Expected output: `{"jsonrpc":"2.0","id":"my-request","error":{"code":-32601,"message":"Method not found"}}`

**Step 3.8: Test -- null id is preserved (notification-style)**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- null id preserved"`
  - Input: `{"jsonrpc":"2.0","id":null,"method":"eth_blockNumber"}`
  - Expected output: `{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"Method not found"}}`

**Step 3.9: Test -- batch request returns array of responses**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- batch request returns array"`
  - Input: `[{"jsonrpc":"2.0","id":1,"method":"eth_chainId"},{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}]`
  - Expected output: array with 2 elements, both -32601 errors with correct ids

**Step 3.10: Test -- empty batch returns invalid request**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- empty batch returns invalid request"`
  - Input: `[]`
  - Expected: `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid request"}}`

**Step 3.11: Test -- batch with invalid element includes error in array**

- File: `src/rpc_server_test.zig`
- Test: `test "handleJsonRpc -- batch with mixed valid/invalid"`
  - Input: `[{"jsonrpc":"2.0","id":1,"method":"eth_chainId"},{"invalid":true}]`
  - Expected: array with -32601 for first, -32600 for second

**Step 3.12: Implementation -- handleJsonRpc function**

- File: `src/rpc_server.zig` (new)
- Signature: `pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]const u8`
- Logic:
  1. Try `std.json.parseFromSlice(std.json.Value, ...)` on request_bytes. On failure -> return parse error response.
  2. Check if top-level is `.array` (batch) or `.object` (single).
  3. For single: call `handleSingleRequest(allocator, value)`.
  4. For batch: iterate array, call `handleSingleRequest` for each, collect into JSON array.
  5. For empty batch: return invalid request.

- `fn handleSingleRequest(allocator, value: std.json.Value) ![]const u8`:
  1. Extract `.object` fields: `jsonrpc`, `method`, `id`, `params`.
  2. Validate `jsonrpc` == `"2.0"`. If not -> invalid request.
  3. Validate `method` exists and is string. If not -> invalid request.
  4. Call `dispatchMethod(allocator, method_name, params, id)`.

- `fn dispatchMethod(allocator, method: []const u8, params: ?std.json.Value, id: ?jsonrpc.envelope.Id) ![]const u8`:
  1. Try prefix-based dispatch: if starts with `"eth_"`, try `jsonrpc.eth.EthMethod.fromMethodName(method)`.
  2. If starts with `"debug_"`, try `jsonrpc.debug.DebugMethod.fromMethodName(method)`.
  3. If starts with `"engine_"`, try `jsonrpc.engine.EngineMethod.fromMethodName(method)`.
  4. For any recognized method: return `-32601 Method not found` (stub -- real handlers added later).
  5. For unrecognized method: return `-32601 Method not found`.

### Phase 4: ZEVM -- HTTP Server Layer

**Step 4.1: Test -- HTTP POST with JSON-RPC body gets JSON-RPC response**

- File: `src/rpc_server_test.zig`
- Test: `test "HTTP server responds to POST with JSON-RPC"` (integration test)
  - Start server on a random available port (port 0 -> OS picks)
  - Use `std.http.Client` to POST a JSON-RPC request
  - Verify response has `Content-Type: application/json`
  - Verify response body is valid JSON-RPC response
  - Stop server

**Step 4.2: Test -- non-POST method returns 405**

- File: `src/rpc_server_test.zig`
- Test: `test "HTTP server rejects GET with 405"`
  - Start server, send GET, verify 405 status

**Step 4.3: Implementation -- HTTP server**

- File: `src/rpc_server.zig`
- Add to existing file:
  ```
  pub const ServerConfig = struct {
      host: []const u8,  // default "127.0.0.1"
      port: u16,         // default 8545
      chain_id: u64,     // default 31337
  };
  ```
  - `pub fn run(allocator, config: ServerConfig) !void` -- main server loop:
    1. `std.net.Address.parseIp(config.host, config.port)` -> `address.listen(.{})`
    2. Loop: `server.accept()`, create reader/writer, init `std.http.Server`
    3. `receiveHead()` -> check method is POST -> read body -> `handleJsonRpc()` -> respond
    4. Non-POST -> respond with 405
    5. Set `Content-Type: application/json` header on all JSON-RPC responses

### Phase 5: ZEVM -- CLI Arg Parsing

**Step 5.1: Test -- parseArgs with defaults**

- File: `src/rpc_server_test.zig`
- Test: `test "parseArgs -- defaults"` -- empty args -> port 8545, host "127.0.0.1", chain_id 31337

**Step 5.2: Test -- parseArgs with overrides**

- File: `src/rpc_server_test.zig`
- Test: `test "parseArgs -- custom port and host"` -- `["--port", "9545", "--host", "0.0.0.0", "--chain-id", "1"]` -> correct values

**Step 5.3: Implementation -- CLI arg parsing in main.zig**

- File: `src/main.zig`
- Replace stub `main()` with:
  1. Parse `std.process.argsWithAllocator()` or read from `std.os.argv`
  2. Iterate args: match `--port`, `--host`, `--chain-id`
  3. Build `ServerConfig`
  4. Print banner: `zevm - Ethereum local node\n  Listening on {host}:{port}\n  Chain ID: {chain_id}\n`
  5. Call `rpc_server.run(allocator, config)`
- Note: Arg parsing is a simple inline loop, not a separate function -- it's only ~20 lines.

**Step 5.4: Implementation -- wire rpc_server into root.zig**

- File: `src/root.zig`
- Add: `pub const rpc_server = @import("rpc_server.zig");`
- Add test import: `_ = @import("rpc_server_test.zig");`

### Phase 6: Verification

**Step 6.1: Run all existing tests**

```bash
cd /Users/williamcory/zevm && zig build test
```

All existing tests (tx_processor, host_adapter, block_builder, consensus, beacon_api, database) must continue passing.

**Step 6.2: Run new tests**

All rpc_server_test.zig tests must pass.

**Step 6.3: Manual smoke test**

```bash
# Terminal 1
cd /Users/williamcory/zevm && zig build run

# Terminal 2
curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}'
# Expected: {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}

curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d 'broken json'
# Expected: {"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}

curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '[{"jsonrpc":"2.0","id":1,"method":"eth_chainId"},{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}]'
# Expected: [{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}},{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}]
```

## Files to Create/Modify

### New Files
| File | Description |
|------|-------------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` | JSON-RPC 2.0 envelope types (Request, Response, Error, Id, ErrorCode) with JSON serde + tests |
| `src/rpc_server.zig` | HTTP server, JSON-RPC dispatch, handleJsonRpc() |
| `src/rpc_server_test.zig` | All RPC server tests (unit + integration) |

### Modified Files
| File | Change |
|------|--------|
| `../voltaire/build.zig` | Add `jsonrpc` module export |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig` | Add `pub const envelope = @import("envelope.zig");` |
| `build.zig` | Import `jsonrpc` module from voltaire, add to zevm + exe + test imports |
| `src/root.zig` | Add `pub const rpc_server = @import("rpc_server.zig");` + test import |
| `src/main.zig` | Replace stub with CLI parsing + server startup |

## Risks and Mitigations

### Risk 1: Zig 0.15 std.http.Server API differences
- **Risk:** The API changed significantly from 0.13/0.14 to 0.15 (new Reader/Writer abstractions)
- **Mitigation:** Researched the exact 0.15.2 API. Use `std.net.Address.listen()` -> `server.accept()` -> `connection.stream.reader()/writer()` -> `std.http.Server.init()` -> `receiveHead()` -> `respond()`.

### Risk 2: voltaire jsonrpc module may have import issues
- **Risk:** The jsonrpc types import internal files via relative paths. When exposed as a build module, missing dependencies could cause compile errors.
- **Mitigation:** The jsonrpc module only depends on `std` and its own internal files (types.zig, etc). No external module dependencies. We verified the root.zig structure.

### Risk 3: JSON serde compatibility between envelope types and method types
- **Risk:** The envelope `Id` type and the existing method `Params`/`Result` types need to work together during dispatch.
- **Mitigation:** The dispatch layer works at the `std.json.Value` level. We parse the raw JSON once, extract method/id/params as `std.json.Value`, then the dispatch layer will eventually pass params to method-specific `Params.jsonParseFromValue()`. For now (stub), we don't need to invoke Params parsing at all.

### Risk 4: std.http.Server single-threaded limitation
- **Risk:** Single-threaded server blocks on each request. If Hive sends concurrent requests, some may timeout.
- **Mitigation:** For dev node use, sequential handling is fine. Hive rpc-compat sends requests sequentially per test. Threading can be added in a future ticket.

### Risk 5: Request body size
- **Risk:** Large batch requests or eth_simulateV1 requests could exceed buffer sizes.
- **Mitigation:** Use dynamic allocation (`body_reader.allocRemaining(allocator, .unlimited)`) for reading request bodies. Set a reasonable max (e.g., 10MB) to prevent OOM.

## Acceptance Criteria Verification

| # | Criterion | How to verify |
|---|-----------|---------------|
| 1 | Server on port 8545 (configurable) | `zig build run` starts on 8545; `zig build run -- --port 9545` starts on 9545 |
| 2 | Valid JSON-RPC 2.0 parsed correctly | Unit tests: valid request parsing with id, method, params |
| 3 | Unrecognized method -> -32601 | Unit test: `foo_bar` -> method not found |
| 4 | Malformed JSON -> -32700 | Unit test: garbage input -> parse error |
| 5 | Batch requests return array | Unit test: array input -> array output |
| 6 | Envelope types in voltaire | `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` exists with tests |
| 7 | Dispatch uses fromMethodName() | dispatchMethod() calls EthMethod.fromMethodName(), DebugMethod.fromMethodName(), EngineMethod.fromMethodName() |
| 8 | Integration test: curl eth_chainId | HTTP integration test + manual smoke test |
| 9 | CLI flags parsed | Unit tests for parseArgs + main.zig wiring |

## Dependencies

- **No external libraries.** Uses only `std.http.Server`, `std.json`, `std.net` from Zig stdlib.
- **Voltaire jsonrpc module.** Must be exported first (Phase 1).
- **No guillotine-mini involvement.** The RPC server doesn't need the EVM yet.
