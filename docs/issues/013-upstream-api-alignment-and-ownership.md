# Upstream API Alignment And Ownership

## Verified Gap

- The live RPC path is coded against `jsonrpc.envelope`, but the current Voltaire JSON-RPC root does not export that namespace.
- ZEVM still carries a second local `envelope` / `router` / `handlers` stack that is not reconciled with the live path, so JSON-RPC ownership between local and upstream code is still ambiguous.
- `tx_processor` still uses an older `guillotine-mini` `evm.init(...)` signature.
- `tx_submission` assumes runtime fields and behaviors that ZEVM no longer provides.
- Several modules with PRD relevance are effectively orphaned from the shipped/runtime path (`genesis`, `node`, local RPC stack, block-query stack), which keeps ownership blurry between ZEVM and sibling repos.

## Evidence

- `src/rpc/server.zig`
- `src/rpc/dispatcher.zig`
- `src/rpc/envelope.zig`
- `src/rpc/router.zig`
- `src/rpc/handlers.zig`
- `src/tx_processor.zig`
- `src/rpc/handlers/tx_submission.zig`
- `src/genesis.zig`
- `src/node.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- `../guillotine-mini/src/evm.zig`

## Resolution Verification

- ZEVM compiles cleanly against the actual sibling exports with no assumptions about nonexistent namespaces or signatures.
- JSON-RPC envelope/method/response ownership is explicit: either upstream owns it or ZEVM owns it, but not both in parallel.
- Runtime and transaction APIs are aligned, or ZEVM owns the required functionality locally with tests.
- PRD-critical modules are either wired into the product path or clearly removed from the shipping surface.
- Cross-repo CI catches API drift between ZEVM, Voltaire, and `guillotine-mini` before merge.
