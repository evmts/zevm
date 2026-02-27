# Research Context: Add RPC Server Infrastructure

**Ticket:** add-rpc-server-infrastructure  
**Category:** cat-2-eth-read  
**Date:** 2026-02-26  

## Summary

ZEVM currently has no RPC server. This research documents the infrastructure needed to add an HTTP server that listens on a configurable port, parses JSON-RPC 2.0 requests, extracts method names and params, and routes to handlers. The implementation should reuse voltaire's JSON-RPC types and integrate with guillotine-mini's EVM.

---

## 1. Upstream Dependencies (Already Available)

### 1.1 Voltaire (`../voltaire/packages/voltaire-zig/src/`)

Voltaire provides **complete JSON-RPC type definitions** for 65 methods across eth/debug/engine namespaces:

| Module | Path | Contents |
|--------|------|----------|
| JsonRpc.zig | `jsonrpc/JsonRpc.zig` | Root union `JsonRpcMethod` combining all namespaces |
| eth/methods.zig | `jsonrpc/eth/methods.zig` | `EthMethod` union with 45 eth_* methods |
| debug/methods.zig | `jsonrpc/debug/methods.zig` | `DebugMethod` union with 5 debug_* methods |
| engine/methods.zig | `jsonrpc/engine/methods.zig` | `EngineMethod` union with 15 engine_* methods |
| types.zig | `jsonrpc/types.zig` | Re-exports Address, Hash, Quantity, BlockTag, BlockSpec |

**Key Type Pattern** (from `jsonrpc/eth/chainId/eth_chainId.zig`):
```zig
pub const method = "eth_chainId";
pub const Params = struct { 
    // jsonStringify/jsonParseFromValue for serde
};
pub const Result = struct {
    value: types.Quantity,
    // jsonStringify/jsonParseFromValue for serde
};
```

**State Manager** (`state-manager/`):
- `StateManager.zig` - Main API with getBalance, setBalance, getNonce, setNonce, getCode, setCode, getStorage, setStorage
- `JournaledState.zig` - Checkpoint/revert/commit journaling
- `ForkBackend.zig` - RPC client for fork mode with caching

**Blockchain** (`blockchain/`):
- `Blockchain.zig` - Block storage and fork management
- `BlockStore.zig` - Local block storage
- `ForkBlockCache.zig` - Remote block fetching with caching

### 1.2 Guillotine-mini (`../guillotine-mini/src/`)

**Current State**: Guillotine-mini is **purely an EVM interpreter** - it has NO RPC server or dispatch infrastructure.

What it provides:
- `evm.zig` - Main EVM with `inner_call()` for transaction execution
- `host.zig` - `HostInterface` vtable for state access (balance, nonce, code, storage)
- `call_params.zig` / `call_result.zig` - Call input/output types
- `trace.zig` - EIP-3155 tracing support

What zevm must implement (NOT in guillotine-mini):
- HTTP server
- JSON-RPC envelope parsing
- Method routing/dispatch

---

## 2. Reference Implementations

### 2.1 EDR (`edr/crates/edr_provider/src/`)

**Architecture Pattern**:
```
Provider (main struct)
├── ProviderData (state container)
├── requests/methods.rs - MethodInvocation enum (all 73 RPC methods)
├── requests/eth.rs - eth_* handlers
├── requests/hardhat.rs - hardhat_* handlers
└── requests/debug.rs - debug_* handlers
```

**JSON-RPC Types** (`edr_rpc_client/src/jsonrpc.rs`):
```rust
pub struct Request<MethodT> {
    pub version: Version,  // V2_0
    pub method: MethodT,
    pub id: Id,  // Num(u64) or Str(String)
}

pub struct Response<SuccessT> {
    pub jsonrpc: Version,
    pub id: Id,
    pub data: ResponseData<SuccessT>,
}

pub enum ResponseData<SuccessT> {
    Error { error: Error },
    Success { result: SuccessT },
}

pub struct Error {
    pub code: i16,
    pub message: String,
    pub data: Option<Value>,
}
```

### 2.2 Foundry Anvil (`foundry/crates/anvil/src/`)

**Architecture Pattern**:
```
EthApi (main RPC handler)
├── execute(EthRequest) -> ResponseResult  (routes all methods)
├── backend (blockchain + state)
├── pool (transaction mempool)
├── miner (block production)
└── filters (eth_newFilter, etc.)

server/
├── rpc_handlers.rs - HttpEthRpcHandler, PubSubEthRpcHandler
└── mod.rs - HTTP/WS server setup
```

**Key Pattern** - Handler trait:
```rust
#[async_trait]
pub trait RpcHandler {
    type Request;
    async fn on_request(&self, request: Self::Request) -> ResponseResult;
}
```

### 2.3 TEVM (`../tevm-monorepo/packages/actions/src/`)

**Handler Pattern** (from `eth/getBalanceHandler.js`):
```javascript
export const getBalanceHandler = (baseClient) => async ({ address, blockTag }) => {
    const vm = await baseClient.getVm();
    if (blockTag === 'latest') {
        const account = await vm.stateManager.getAccount(createAddress(address));
        return account?.balance ?? 0n;
    }
    // ... fork handling
};
```

**Procedure Pattern** (from `eth/getBalanceProcedure.js`):
```javascript
export const getBalanceProcedure = (baseClient) => async (req) => {
    return {
        jsonrpc: '2.0',
        id: req.id,
        method: req.method,
        result: numberToHex(await getBalanceHandler(baseClient)({...})),
    };
};
```

---

## 3. Execution APIs Specification (`execution-apis/`)

**JSON-RPC 2.0 Envelope** (from `src/schemas/base-types.yaml`):

| Type | Pattern | Example |
|------|---------|---------|
| address | `^0x[0-9a-fA-F]{40}$` | `0xfe3b557e8fb62b89f4916b721be55ceb828dbd73` |
| bytes | `^0x[0-9a-f]*$` | `0x60806040...` |
| uint | `^0x(0\|[1-9a-f][0-9a-f]*)$` | `0x1cfe56f3795885980000` |
| hash32 | `^0x[0-9a-f]{64}$` | `0x...` (64 hex chars) |

**Standard Error Codes**:
- `-32700` - Parse error
- `-32600` - Invalid Request
- `-32601` - Method not found
- `-32602` - Invalid params
- `-32603` - Internal error

**Core eth_* Methods for Read Category** (from `src/eth/state.yaml`, `src/eth/execute.yaml`):
- `eth_chainId` - Returns chain ID
- `eth_blockNumber` - Returns latest block number
- `eth_getBalance(address, block)` - Returns account balance
- `eth_getCode(address, block)` - Returns contract code
- `eth_getStorageAt(address, slot, block)` - Returns storage value
- `eth_getTransactionCount(address, block)` - Returns nonce
- `eth_call(transaction, block)` - Executes message call
- `eth_estimateGas(transaction, block)` - Estimates gas required

---

## 4. ZEVM Current State

### 4.1 Existing Infrastructure

**Database Layer** (`src/database/`):
- `Database.zig` - Merkle Patricia Trie for state root computation
- `Accounts.zig` - Account state management
- `Contracts.zig` - Contract code deduplication
- `BlockHashes.zig` - Block hash storage

**Transaction Processing** (`src/tx_processor.zig`):
- `intrinsicGas(data, is_create)` - Gas calculation
- `processTransaction(allocator, state_manager, host, sender, tx, block_ctx)` - Full tx execution
- Integrates with guillotine-mini EVM

**Host Adapter** (`src/host_adapter.zig`):
- Bridges voltaire `StateManager` to guillotine-mini `HostInterface`
- Vtable implementation for balance, nonce, code, storage access

**Block Building** (`src/block_builder.zig`):
- `buildBlock(allocator, state, txs, header)` - Block construction
- Gas limit enforcement, receipt generation

### 4.2 Missing for RPC Server

1. **HTTP Server** - No HTTP listener
2. **JSON-RPC Parser** - No request/response envelope handling
3. **Method Router** - No dispatch from method name to handler
4. **Handler Functions** - No eth_* method implementations

---

## 5. Recommended Implementation Structure

Based on reference implementations, ZEVM RPC server should have:

```
src/
├── rpc/
│   ├── server.zig       - HTTP server (std.http.Server)
│   ├── envelope.zig     - JSON-RPC 2.0 request/response types
│   ├── router.zig       - Method name -> handler dispatch
│   └── handlers.zig     - eth_* handler implementations
├── node.zig             - Main node struct (holds state manager, blockchain, pool)
└── main.zig             - CLI + server startup
```

### 5.1 Key Components

**1. HTTP Server** (Zig stdlib `std.http.Server`):
- Listen on configurable port (default 8545)
- Accept POST requests
- Handle CORS headers for browser access

**2. JSON-RPC Envelope**:
```zig
pub const Request = struct {
    jsonrpc: []const u8,  // "2.0"
    method: []const u8,
    params: std.json.Value,
    id: ?std.json.Value,  // null for notifications
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    error: ?RpcError = null,
    id: ?std.json.Value,
};

pub const RpcError = struct {
    code: i16,
    message: []const u8,
    data: ?std.json.Value = null,
};
```

**3. Method Router**:
- Parse method name from request
- Dispatch to appropriate handler
- Return "method not found" for unknown methods

**4. Handler Context** (injected into all handlers):
```zig
pub const HandlerContext = struct {
    state_manager: *state_manager.StateManager,
    blockchain: *blockchain.Blockchain,
    // future: mempool, filter manager, etc.
};
```

### 5.2 Integration with Upstream

**Voltaire Types**: Use `jsonrpc.types.Address`, `jsonrpc.types.Quantity`, `jsonrpc.types.Hash` for parameter/result serialization.

**Voltaire State**: Use `state_manager.StateManager` for all state access (getBalance, getNonce, etc.).

**Guillotine-mini EVM**: Use `guillotine_mini.Evm` via `host_adapter.HostAdapter` for eth_call and eth_estimateGas.

---

## 6. Testing Approach

ZEVM tests should focus on **integration layer only** (wiring between voltaire/guillotine-mini and RPC handlers):

- **Envelope parsing** - Valid/invalid JSON-RPC requests
- **Method routing** - Correct handler invoked for each method
- **Error handling** - Standard JSON-RPC error codes
- **Handler integration** - State manager calls work correctly

Do NOT test:
- Voltaire's JSON-RPC types (already tested in voltaire)
- Guillotine-mini's EVM (already tested in guillotine-mini)
- State manager journaling (already tested in voltaire)

---

## 7. File References

### 7.1 ZEVM Files to Modify/Create
- `src/main.zig` - Add server startup
- `src/rpc/server.zig` - **NEW**: HTTP server
- `src/rpc/envelope.zig` - **NEW**: JSON-RPC types
- `src/rpc/router.zig` - **NEW**: Method dispatch
- `src/rpc/handlers.zig` - **NEW**: eth_* handlers
- `src/node.zig` - **NEW**: Main node struct

### 7.2 Upstream Files (READ-ONLY, reference only)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig`
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`
- `../guillotine-mini/src/evm.zig`
- `../guillotine-mini/src/host.zig`

### 7.3 Reference Implementations (READ-ONLY)
- `edr/crates/edr_provider/src/requests/methods.rs`
- `edr/crates/edr_rpc_client/src/jsonrpc.rs`
- `foundry/crates/anvil/src/eth/api.rs`
- `foundry/crates/anvil/src/server/rpc_handlers.rs`
- `../tevm-monorepo/packages/actions/src/eth/getBalanceHandler.js`
- `execution-apis/src/eth/state.yaml`
- `execution-apis/src/schemas/base-types.yaml`

---

## 8. Next Steps

1. Create `src/rpc/envelope.zig` with JSON-RPC 2.0 types
2. Create `src/rpc/server.zig` with HTTP listener
3. Create `src/rpc/router.zig` with method dispatch
4. Create `src/rpc/handlers.zig` with eth_chainId, eth_blockNumber, eth_getBalance
5. Create `src/node.zig` to hold state manager and blockchain
6. Update `src/main.zig` to start server
7. Add tests for envelope parsing and routing
