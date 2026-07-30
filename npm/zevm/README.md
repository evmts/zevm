# @evmts/zevm

TypeScript bindings and a native Node.js addon for ZEVM's light-client C ABI.

## Install

`0.1.0-beta.1` is a prerelease while ZEVM's pre-1.0 API and native packaging
receive production feedback:

```bash
npm install @evmts/zevm@beta
```

The install selects an optional native package for macOS (arm64/x64), Linux
(arm64/x64, glibc/musl), or Windows (arm64/ia32/x64). Node.js 22 or newer is
required.

## Use

```ts
import {
  LightClient,
  ZEVM_NETWORK_MAINNET,
  ZEVM_STATUS_SYNCED,
} from "@evmts/zevm";

const client = new LightClient(
  ZEVM_NETWORK_MAINNET,
  "https://your-beacon-api.example",
  "https://your-execution-rpc.example",
);

try {
  while (client.status() !== ZEVM_STATUS_SYNCED) {
    client.syncStep();
  }

  const balance = client.getBalance(
    "0x0000000000000000000000000000000000000000",
  );
  console.log(balance);
} finally {
  client.close();
}
```

Calls on one `LightClient` instance must be serialized by the caller. Block
number `0` means the latest verified head. ZEVM does not retain arbitrary
historical state, so a non-zero block is available only when it matches the
current optimistic or finalized header.

The root native binding is ESM. Compatibility subpaths such as
`@evmts/zevm/evm`, `@evmts/zevm/rlp`, and `@evmts/zevm/trie` expose both ESM and
CommonJS builds.

## Develop

Local development builds can be produced from the repository root:

```bash
npm --prefix npm/zevm ci --ignore-scripts
zig build npm-native
npm --prefix npm/zevm run typecheck
node npm/zevm/scripts/smoke.cjs zig-out/npm/native/zevm.node
```

Set `ZEVM_NATIVE_PATH=/absolute/path/to/zevm.node` to load a locally built addon
instead of an optional platform package.

See the [ZEVM documentation](https://zevm.tevm.sh) and
[source repository](https://github.com/evmts/zevm).
