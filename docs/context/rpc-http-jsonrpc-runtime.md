# Context: Build HTTP JSON-RPC runtime and method router

## Reference Materials
- `../voltaire/packages/voltaire-zig/src/jsonrpc/` - Provides the JSON-RPC types, including Request/Response definitions, Params/Results, and JSON serde functionality.
- `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/` - Upstream RPC dispatch routing, either to be restored/exposed or replaced by direct ZEVM wiring against voltaire JSON-RPC unions.
- `edr/crates/edr_provider/src/requests/methods.rs` - Hardhat EDR's Rust implementation of JSON-RPC methods; useful reference for supported methods, parameters, and error handling.
- `execution-apis/src/eth/client.yaml` - Standard Ethereum JSON-RPC API specification detailing request/response schemas.
- `foundry/` and `hardhat/` - Reference dev node implementations.

## Relevant Codebase Files
- `build.zig` - Current build configuration importing `voltaire` and `guillotine-mini` dependencies. Needs to link or include the new RPC module.
- `src/main.zig` & `src/root.zig` - Entry points where the JSON-RPC server should be initialized and exposed.
- `src/rpc/server.zig` (To be created) - Production JSON-RPC 2.0 HTTP server layer that accepts requests.
- `src/rpc/dispatcher.zig` (To be created) - Method router that parses/serializes through voltaire jsonrpc types and dispatches to handler functions.
- `src/rpc/server_test.zig` (To be created) - End-to-end HTTP tests (single request, batch, invalid JSON, unknown method, bad params).

## Summary
The goal is to implement an HTTP server in ZEVM that acts as a thin wiring layer for JSON-RPC 2.0 requests. It will parse requests and serialize responses using `voltaire`'s JSON-RPC types, and route methods to their respective handlers using a newly built dispatcher. Since `guillotine-mini` lacks its upstream RPC dispatch modules, the dispatcher in ZEVM will likely wire directly against the `voltaire` JSON-RPC method unions. The implementation should adhere to standard JSON-RPC 2.0 specifications, including proper canonical error codes.