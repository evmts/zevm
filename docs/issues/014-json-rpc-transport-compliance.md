# JSON-RPC Transport Compliance

## Verified Gap

- The live transport path is not release-ready even aside from the startup gap: it depends on a broken upstream `jsonrpc.envelope` API, and the alternate in-tree `envelope` / `router` stack is not the product path.
- Neither stack implements notification semantics; both always serialize a response, including for missing IDs and every batch item.
- Live param validation is shallow: only `eth_getBalance` length is checked centrally, while downstream handler failures are flattened to `-32603`.
- The existing tests cover helper entry points such as `handleHttpRequestForTest`, not the real listener/socket path, and there is no notification or mixed-batch coverage.

## Evidence

- `src/rpc/server.zig`
- `src/rpc/dispatcher.zig`
- `src/rpc/envelope.zig`
- `src/rpc/router.zig`
- `src/rpc/server_test.zig`
- `src/rpc/envelope_test.zig`
- `src/rpc/router_test.zig`

## Resolution Verification

- Single requests, batches, mixed valid/invalid batch items, and notifications follow JSON-RPC 2.0 semantics exactly.
- Notifications and notification-only batches return no response body.
- Invalid request objects, invalid params, and handler failures map to the correct JSON-RPC errors without collapsing everything to `-32603`.
- The transport is verified both through direct helper tests and through real socket/listener smoke tests.
- Only one canonical JSON-RPC transport/parser stack remains on the shipping path.
