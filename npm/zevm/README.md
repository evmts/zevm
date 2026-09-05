# @evmts/zevm

JavaScript bindings for ZEVM's native C ABI. The Node-API addon is implemented in C; execution is implemented in Zig using the sibling Voltaire and Guillotine Mini sources. No JavaScript EVM is bundled.

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

The loader prefers an explicitly configured `ZEVM_NATIVE_PATH`, then the locally built addon, then a platform package. It rejects addons without execution bindings. The existing `LightClient` wrapper remains available independently.
