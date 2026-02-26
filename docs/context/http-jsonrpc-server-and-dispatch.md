# Research Context: HTTP JSON-RPC Server with Method Dispatch

## Ticket Summary

Implement the HTTP JSON-RPC 2.0 server that is the foundation of the entire dev node. This is the single highest-impact feature -- without it, nothing else works. The server needs an HTTP listener, JSON-RPC 2.0 envelope parsing/serialization, batch request support, standard error codes, method dispatch using voltaire's `JsonRpcMethod` union, and CLI arg parsing.

Start with a dispatcher that returns `-32601` (method not found) for all methods, then subsequent tickets add handlers. This lets us immediately run the Hive rpc-compat test suite to track progress.

---

## Critical Finding: voltaire jsonrpc module NOT exported

**voltaire's build.zig exports these modules:** `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles`

**voltaire's build.zig does NOT export:** `jsonrpc`

The jsonrpc types exist at `voltaire/packages/voltaire-zig/src/jsonrpc/` but are not wired up as a Zig build module. Before zevm can import voltaire's jsonrpc types, we must **add a `jsonrpc` module to voltaire's build.zig**. This is the first implementation step.

---

## What Voltaire Already Provides

### JSON-RPC Method Types (65 methods)

**Location:** `../voltaire/packages/voltaire-zig/src/jsonrpc/`

The jsonrpc module defines typed Params/Result structs for all 65 Ethereum JSON-RPC methods across 3 namespaces:

- **`root.zig`** — Re-exports `JsonRpc.zig`, `eth/methods.zig`, `debug/methods.zig`, `engine/methods.zig`, `types.zig`
- **`JsonRpc.zig`** — Root `JsonRpcMethod` tagged union combining all namespaces: `union(enum) { engine, eth, debug }`
- **`eth/methods.zig`** — `EthMethod` union with 39 eth_ methods, each with `{ params: T.Params, result: T.Result }`. Has `fromMethodName()` using `StaticStringMap` for O(1) method name lookup.
- **`debug/methods.zig`** — `DebugMethod` union with 5 debug_ methods
- **`engine/methods.zig`** — `EngineMethod` union with 20 engine_ methods
- **`types.zig`** — Shared types: `Address`, `Hash`, `Quantity`, `BlockTag`, `BlockSpec`

**Key pattern — each method file (e.g. `eth_blockNumber.zig`):**
```zig
pub const method = "eth_blockNumber";  // method name string
pub const Params = struct { ... };     // with jsonParseFromValue + jsonStringify
pub const Result = struct { ... };     // with jsonParseFromValue + jsonStringify
```

**Params use positional array parsing** — e.g. `eth_getBalance` parses `params` as a JSON array: `[address, blockSpec]`.

**Types are thin wrappers** — `Quantity`, `BlockSpec`, `BlockTag`, `Address`, `Hash` all wrap `std.json.Value` with pass-through serde. Higher layers do validation.

### What voltaire does NOT have (must be added)

1. **JSON-RPC 2.0 envelope types** — No `Request`, `Response`, `Error` structs for the transport layer
2. **jsonrpc build module export** — Not wired up in voltaire's `build.zig`

### TypeScript Reference (voltaire-ts)

**Location:** `../voltaire/packages/voltaire-ts/src/jsonrpc/`

The TypeScript implementation provides the exact pattern we need:

**`types.ts` — JSON-RPC 2.0 envelope types:**
```typescript
interface JsonRpcRequest { jsonrpc: "2.0"; method: string; params?: unknown[]; id: number | string | null; }
interface JsonRpcResponse { jsonrpc: "2.0"; result?: unknown; error?: JsonRpcError; id: number | string | null; }
interface JsonRpcError { code: number; message: string; data?: unknown; }
const JsonRpcErrorCode = {
  PARSE_ERROR: -32700, INVALID_REQUEST: -32600, METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602, INTERNAL_ERROR: -32603,
  INVALID_INPUT: -32000, RESOURCE_NOT_FOUND: -32001, RESOURCE_UNAVAILABLE: -32002,
  TRANSACTION_REJECTED: -32003, METHOD_NOT_SUPPORTED: -32004, LIMIT_EXCEEDED: -32005
};
```

**`server.ts` — HTTP server pattern:**
- POST-only, CORS headers, OPTIONS preflight
- Read body with max size check
- Parse JSON -> validate request format -> dispatch to handler -> wrap result/error
- `isValidRequest()`: checks `jsonrpc == "2.0"`, `method` is string, `params` is array (if present), `id` is string|number|null

**`handlers.ts` — Dispatch pattern:**
- Switch on method name, parse params positionally, call dependency, format result as hex
- Default case throws `{ code: -32601, message: "Method not found: ..." }`

---

## What guillotine-mini Provides

**Location:** `../guillotine-mini/` (EVM library, not RPC server)

Guillotine-mini is purely an **EVM interpreter library**. It does NOT have:
- HTTP server
- JSON-RPC dispatch/routing
- Envelope parsing
- Response serialization

The `client/rpc/` and `client/engine/` paths referenced in the ticket don't exist. The Zig source is at `worktrees/evm-fix-test/src/` and contains only EVM internals (opcode.zig, host.zig, errors.zig, primitives/, trace.zig).

**What it provides for zevm:** EVM execution via the host adapter pattern (zevm's `host_adapter.zig` bridges voltaire StateManager to guillotine-mini's HostInterface).

---

## What zevm Already Has

### Existing Files
```
src/main.zig              — Stub: prints "zevm - Ethereum local node"
src/root.zig              — Exports: database, blockchain, host_adapter, tx_processor,
                             block_builder, consensus_verifier, beacon_api, consensus_sync, checkpoint
build.zig                 — Imports voltaire (primitives, state-manager, blockchain, crypto, precompiles)
                             and guillotine-mini. Creates zevm module + exe + tests.
build.zig.zon             — Dependencies: voltaire (path: ../voltaire), guillotine-mini (path: ../guillotine-mini)
```

### Build System
- zevm imports voltaire modules: `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles`
- zevm imports guillotine-mini as `guillotine_mini` module
- Executable links to zevm module; tests run from `src/root.zig`

### Passing Tests
- tx_processor_test.zig, host_adapter_test.zig, block_builder_test.zig
- consensus_verifier_test.zig, beacon_api_test.zig, consensus_sync_test.zig, checkpoint_test.zig
- database_test.zig

---

## Reference Implementation Analysis

### EDR (Hardhat) — Rust

**Files:** `edr/crates/edr_provider/src/requests/`, `edr/crates/edr_rpc_client/src/jsonrpc.rs`

**Envelope types:**
```rust
struct Request<MethodT> { version: Version, method: MethodT, id: Id }
enum ResponseData<SuccessT> { Error { error: Error }, Success { result: SuccessT } }
enum Id { Num(u64), Str(String) }
```

**Dispatch pattern:**
- `ProviderRequest` enum: `Single(Box<MethodInvocation>)` | `Batch(Vec<MethodInvocation>)`
- Custom deserializer distinguishes single (map) vs batch (array)
- `MethodInvocation` uses `#[serde(tag = "method", content = "params")]` for 70+ variants
- `handle_single_request` matches on each variant, calls handler function
- Batch processes sequentially for state consistency

**Error codes:**
```rust
INVALID_INPUT: -32000, INTERNAL_ERROR: -32603, INVALID_PARAMS: -32602
// -32004 for unsupported method
```

**Key insight:** EDR itself has NO HTTP server — it's a library called via FFI from Node.js. The HTTP layer is external.

### Foundry Anvil — Rust

**Files:** `foundry/crates/anvil/src/`, `foundry/crates/anvil/server/src/`, `foundry/crates/anvil/rpc/src/`

**HTTP server:** Uses Axum (tokio-based). Router handles POST at root `/`. CORS configurable.

**Envelope types (rpc/src/request.rs):**
```rust
enum Request { Single(RpcCall), Batch(Vec<RpcCall>) }
enum RpcCall { MethodCall(RpcMethodCall), Notification(RpcNotification), Invalid { id: Id } }
struct RpcMethodCall { jsonrpc: Version, method: String, params: RequestParams, id: Id }
enum RequestParams { None, Array(Vec<Value>), Object(Map) }
enum Id { String(String), Number(i64), Null }
```

**Two-stage dispatch:**
1. Parse generic JSON-RPC envelope (extract method, params, id)
2. Deserialize params into typed `EthRequest` enum via `#[serde(tag = "method", content = "params")]`
3. Match on `EthRequest` variant in `EthApi::execute()` (100+ methods)

**Batch handling:** Concurrent via `futures::join_all` — all items process in parallel.

**CLI args (clap):** `--port 8545`, `--host 127.0.0.1`, `--accounts 10`, `--balance 10000`, `--block-time`, `--fork-url URL@BLOCK`, `--chain-id`, `--gas-limit`, etc.

### TEVM — TypeScript

**Files:** `../tevm-monorepo/packages/actions/src/`

**Dispatch:** Hash map lookup — `handlers[method](request)`. O(1) dispatch, extensible.
- `createHandlers()` returns flat object mapping 120+ method names to handler functions
- Supports namespace aliasing: same handler for `anvil_*`, `hardhat_*`, `ganache_*`

**Three-layer architecture:**
1. **Procedure** — JSON-RPC adapter (hex conversion, envelope wrapping)
2. **Handler** — Business logic (calls StateManager/Blockchain)
3. **Core operations** — VM, StateManager, Blockchain

**Error handling:** Class hierarchy with error codes, documentation links, stack traces.

---

## Hive rpc-compat Test Suite

**Location:** `hive/simulators/ethereum/rpc-compat/`

**How it works:**
1. Loads genesis.json, chain.rlp, forkenv.json from `execution-apis/tests/`
2. Starts client container exposing port 8545
3. Sends initial `engine_forkchoiceUpdatedV3` to set head block
4. Runs `.io` test files: `>> {request}` / `<< {expected_response}`
5. Uses `jsondiff` for response comparison

**Test count: ~199 tests across 30 methods:**
- eth_blockNumber (1), eth_chainId (1), eth_call (6), eth_estimateGas (6)
- eth_getBalance (3), eth_getBlockByNumber (10), eth_getBlockByHash (3)
- eth_getTransactionByHash (9), eth_getTransactionReceipt (9), eth_getLogs (9)
- eth_getBlockReceipts (8), eth_sendRawTransaction (5), eth_simulateV1 (91)
- eth_getCode (3), eth_getStorageAt (4), eth_getTransactionCount (3), eth_getProof (3)
- eth_feeHistory (1), eth_blobBaseFee (1), eth_syncing (1), eth_createAccessList (4)
- debug_getRawBlock (3), debug_getRawHeader (3), debug_getRawReceipts (3), debug_getRawTransaction (2)
- net_version (1), plus block tx count methods (4 total)

**Fixture state:** Chain pre-imported to block 0x2d (45), chain ID 3503995874084926.

### execution-apis .io Test Format

**Location:** `execution-apis/tests/{method}/{test}.io`

```
// comment describing the test
>> {"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}
<< {"jsonrpc":"2.0","id":1,"result":"0x2d"}
```

- `>>` = request, `<<` = expected response
- Both are complete JSON-RPC 2.0 objects
- Error responses: `<< {"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"..."}}`

---

## Implementation Plan

### Step 1: Add jsonrpc module to voltaire's build.zig

The jsonrpc types exist but aren't exported. Add to `../voltaire/build.zig`:
```zig
const jsonrpc_mod = b.addModule("jsonrpc", .{
    .root_source_file = b.path("packages/voltaire-zig/src/jsonrpc/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

### Step 2: Add JSON-RPC 2.0 envelope types to voltaire's jsonrpc module

Add to `../voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig` (new file):

```zig
/// JSON-RPC 2.0 Request envelope
pub const Request = struct {
    jsonrpc: []const u8,  // must be "2.0"
    method: []const u8,
    params: ?std.json.Value,  // array or object
    id: ?Id,  // null for notifications
};

/// JSON-RPC 2.0 Response envelope
pub const Response = struct {
    jsonrpc: []const u8,  // "2.0"
    result: ?std.json.Value,
    @"error": ?Error,
    id: ?Id,
};

/// JSON-RPC 2.0 Error object
pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value,
};

/// JSON-RPC 2.0 Request ID (string, number, or null)
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,
    null_value: void,
};

/// Standard JSON-RPC 2.0 error codes
pub const ErrorCode = struct {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
    // Ethereum-specific
    pub const INVALID_INPUT: i32 = -32000;
    pub const RESOURCE_NOT_FOUND: i32 = -32001;
    pub const RESOURCE_UNAVAILABLE: i32 = -32002;
    pub const TRANSACTION_REJECTED: i32 = -32003;
    pub const METHOD_NOT_SUPPORTED: i32 = -32004;
    pub const LIMIT_EXCEEDED: i32 = -32005;
};
```

### Step 3: Add jsonrpc import to zevm's build.zig

```zig
const jsonrpc_mod = voltaire.module("jsonrpc");
// Add to zevm module imports and exe imports
```

### Step 4: Implement HTTP server + dispatch in zevm

In `src/rpc_server.zig`:
- Use `std.http.Server` for HTTP listener
- Parse POST body as JSON
- Detect single vs batch (array vs object)
- Extract method name, look up via `EthMethod.fromMethodName()` / `DebugMethod.fromMethodName()` / `EngineMethod.fromMethodName()`
- For now: return `-32601 Method not found` for all recognized methods
- Standard error responses for parse errors, invalid requests

### Step 5: Add CLI arg parsing in `src/main.zig`

Use `std.process.ArgIterator`:
- `--port` (default 8545)
- `--host` (default "127.0.0.1")
- `--chain-id` (default 31337)
- `--fork-url` (optional)

### Step 6: Wire up and test

- Wire rpc_server into main.zig
- Add integration test that sends JSON-RPC requests and verifies responses
- Ensure existing tests still pass

---

## Key Reference Files

### Voltaire (upstream, we own)
| File | What it provides |
|------|-----------------|
| `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig` | Module entry point, re-exports all jsonrpc types |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig` | Root `JsonRpcMethod` union(enum) { engine, eth, debug } |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` | `EthMethod` union with 39 methods + `fromMethodName()` StaticStringMap |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/debug/methods.zig` | `DebugMethod` union with 5 methods + `fromMethodName()` |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/engine/methods.zig` | `EngineMethod` union with 20 methods + `fromMethodName()` |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` | Shared types: Address, Hash, Quantity, BlockTag, BlockSpec |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/blockNumber/eth_blockNumber.zig` | Example: no-param method with Quantity result |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBalance/eth_getBalance.zig` | Example: 2-param method (address + blockSpec) |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/call/eth_call.zig` | Example: complex method (transaction + blockSpec) |
| `../voltaire/build.zig` | Module exports (currently missing jsonrpc!) |
| `../voltaire/packages/voltaire-ts/src/jsonrpc/types.ts` | TypeScript envelope types — model for Zig envelope |
| `../voltaire/packages/voltaire-ts/src/jsonrpc/server.ts` | TypeScript HTTP server — model for Zig server |
| `../voltaire/packages/voltaire-ts/src/jsonrpc/handlers.ts` | TypeScript dispatch — model for Zig dispatch |

### ZEVM (this repo)
| File | What it provides |
|------|-----------------|
| `src/main.zig` | Current stub — needs HTTP server + CLI args |
| `src/root.zig` | Module exports — needs rpc_server added |
| `build.zig` | Build config — needs jsonrpc module import |
| `build.zig.zon` | Dependencies: voltaire, guillotine-mini |

### Reference Implementations (read-only)
| File | What it shows |
|------|--------------|
| `edr/crates/edr_rpc_client/src/jsonrpc.rs` | Rust JSON-RPC envelope types |
| `edr/crates/edr_provider/src/requests.rs` | Single/Batch request discrimination |
| `edr/crates/edr_provider/src/requests/methods.rs` | 70+ method MethodInvocation enum |
| `edr/crates/edr_provider/src/provider.rs` | Dispatch: handle_single_request / handle_batch_request |
| `edr/crates/edr_provider/src/error.rs` | Error codes and error type hierarchy |
| `foundry/crates/anvil/rpc/src/request.rs` | Request/RpcCall/RpcMethodCall/RequestParams/Id types |
| `foundry/crates/anvil/rpc/src/response.rs` | Response/RpcResponse/ResponseResult types |
| `foundry/crates/anvil/rpc/src/error.rs` | RpcError/ErrorCode types |
| `foundry/crates/anvil/server/src/handler.rs` | HTTP request handling, single/batch routing |
| `foundry/crates/anvil/src/eth/api.rs` | Method dispatch via giant match on EthRequest enum |
| `foundry/crates/anvil/src/cmd.rs` | CLI args: --port, --host, --fork-url, --chain-id |
| `foundry/crates/anvil/src/lib.rs` | Server spawning and lifecycle |

### Test Suites
| File | What it shows |
|------|--------------|
| `execution-apis/tests/eth_blockNumber/simple-test.io` | `.io` test format example |
| `execution-apis/tests/eth_chainId/get-chain-id.io` | `.io` test format example |
| `hive/simulators/ethereum/rpc-compat/main.go` | Hive test runner |
| `hive/simulators/ethereum/rpc-compat/testload.go` | Test loading logic |

---

## Design Decisions

### Use `std.http.Server` for HTTP
- Zig's stdlib HTTP server is sufficient for a dev node
- No need for external HTTP library (httpz, zap)
- Single-threaded event loop is fine for dev use; can add threading later

### JSON-RPC envelope types go in voltaire
- These are fundamental JSON-RPC 2.0 types needed by any consumer
- voltaire-ts already has them; Zig should mirror
- Location: `voltaire/packages/voltaire-zig/src/jsonrpc/envelope.zig`

### Method dispatch via string matching, not the union
- The `JsonRpcMethod` union is useful for typed params/results but NOT for dispatch
- Dispatch needs: receive method string -> find handler -> parse params -> call handler -> serialize result
- Use `EthMethod.fromMethodName()` (StaticStringMap) for O(1) method resolution
- Don't need to construct the union at dispatch time

### Start with -32601 for all methods
- Allows immediately running hive rpc-compat (all 199 tests will get proper error responses)
- Each subsequent ticket adds one method handler
- Progress is measurable: count passing hive tests

### Batch support from day 1
- JSON-RPC spec requires it
- Hive tests may use it
- Implementation: detect array at top level, iterate, collect responses

### Sequential batch processing (not concurrent)
- Matches EDR's approach (state consistency within batch)
- Simpler to implement in Zig (no async/threading needed initially)
- Anvil does concurrent batches but that's an optimization for later

### CLI arg parsing with std.process.ArgIterator
- No external CLI library needed for 4 flags
- Zig's `std.process.ArgIterator` plus manual parsing is sufficient
- Match pattern: `--port`, `--host`, `--chain-id`, `--fork-url`
