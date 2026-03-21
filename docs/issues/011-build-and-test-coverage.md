# Build And Test Coverage

## Verified Gap

- `zig build` and `zig build -j1` are still blocked by the sibling `blst` shell build step, which mutates shared in-tree outputs in place. Running `../voltaire/packages/voltaire-zig/lib/c-kzg-4844/blst/build.sh` manually succeeds, which points to an invocation/race issue rather than a permanently broken dependency.
- After manually priming that dependency, `zig build test -j1` still fails on real ZEVM compile drift: `jsonrpc.envelope` no longer exists upstream, and `tx_processor` still calls the older 5-argument `evm.init(...)` signature.
- The default test graph omits 11 test files: `genesis_test.zig`, `log_index_test.zig`, `main_test.zig`, `node_test.zig`, `receipt_index_test.zig`, `rpc/block_queries_test.zig`, `rpc/envelope_test.zig`, `rpc/handlers/block_spec_test.zig`, `rpc/handlers/eth_read_test.zig`, `rpc/handlers/tx_submission_test.zig`, and `rpc/router_test.zig`.
- The current HTTP tests target `handleHttpRequestForTest`, not the real listener/socket path.

## Evidence

- `build.zig`
- `src/root.zig`
- `src/rpc/root.zig`
- `src/rpc/server.zig`
- `src/tx_processor.zig`
- `../voltaire/packages/voltaire-zig/lib/c-kzg-4844/blst/build.sh`
- `../guillotine-mini/src/evm.zig`

## Resolution Verification

- `zig build` and `zig build test` pass from a clean checkout with no manual dependency repair.
- Sibling build scripts are safe under Zig's dependency invocation model and free of shared-artifact races.
- The default test root imports every shipped surface or explicitly gates non-shipping helpers elsewhere.
- Stale tests are updated or removed; omitted tests are not allowed to silently rot.
- CI includes end-to-end HTTP dev-node smoke coverage and light-client startup/resume coverage.
