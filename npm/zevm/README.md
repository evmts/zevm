# @evmts/zevm

ZEVM runs Ethereum bytecode using the same Zig runtime in Node.js and browsers. Node.js loads the platform-specific Node-API addon. Browsers load a WebAssembly reactor.

```sh
cd ~/zevm
zig build npm-smoke -Doptimize=ReleaseSafe
cp zig-out/npm/native/zevm.node npm/zevm/native/zevm.node
```

```js
import { NativeNode } from '@evmts/zevm'
const node = new NativeNode({ chain_id: 31337 })
try {
  console.log(node.rpc('{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}'))
} finally {
  node.close()
}
```

`rpc` accepts raw JSON and returns response JSON, or `null` for a notification. Calls are synchronous. Serialize access to each node. `close` is idempotent and subsequent RPC calls fail; garbage collection is a final fallback for releasing handles. Use TEVM's event-emitting wrapper for asynchronous serialized requests and lifecycle events.

The loader prefers an explicitly configured `ZEVM_NATIVE_PATH`, then a matching platform package, then the locally built addon. It rejects addons without execution bindings. The existing `LightClient` wrapper remains available independently.

## Browser execution

```js
import { createWasmBackend } from '@evmts/zevm/browser'

const backend = await createWasmBackend()
try {
  const response = backend.rpc(JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'eth_call',
    params: [{ data: '0x602a60005260206000f3' }, 'latest']
  }))
  console.log(JSON.parse(response).result) // 32-byte encoding of 42
} finally {
  backend.close()
}
```

The loader fetches `zevm.wasm` next to its JavaScript module. Bundlers can resolve the asset through `new URL(..., import.meta.url)`. Hosts can also pass a compiled `WebAssembly.Module` or bytes as `{ wasm }`. Pass `{ chainId }` to override 31337. Each instance owns its local chain and implements TEVM's `ZevmBackend` interface.

The browser runtime supports local trusted execution, manual mining, and automining. The native package provides network forks, the consensus light client, Engine API, and background interval mining. Build locally with Zig 0.15.2 and the Rust `wasm32-unknown-unknown` target using `zig build wasm`. The output is `zig-out/npm/browser/zevm.wasm`.
