# Plan: genesis-bootstrap-and-core-eth-read

## Overview

Implement a minimal ZEVM node runtime that bootstraps deterministic dev-chain state and exposes core `eth_*` read handlers via the existing JSON-RPC runtime dependency. Keep ZEVM as a thin integration layer over `voltaire`:

1. Fix missing/incorrect RPC type surfaces in `voltaire` first (upstream-first rule).
2. Add ZEVM node bootstrap state (`chain_id`, `coinbase`, managed accounts, head block number defaults).
3. Add shared block-spec parsing for `latest`, `pending`, `earliest`, and explicit hex quantity.
4. Implement one read handler at a time with tests first.
5. Add one HTTP smoke test to verify end-to-end JSON-RPC output formatting.

## TDD Step Order (Tests First, Then Implementation)

### Phase 0: Upstream type gaps in voltaire (required before ZEVM handlers)

1. Write failing tests in `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig` proving `eth_accounts.Result` serializes/parses an address array.
2. Implement `eth_accounts.Result.value: []const @import("../../types.zig").Address` and update serde.
3. Write failing tests in `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/feeHistory/eth_feeHistory.zig` for:
   - `Params` parsing (`blockCount`, `newestBlock` block spec, `rewardPercentiles` float array)
   - `Result` object shape (`oldestBlock`, `baseFeePerGas`, `gasUsedRatio`, optional `reward`, optional blob fields)
4. Implement corrected `eth_feeHistory` `Params`/`Result` types and serde in voltaire.
5. Run `zig build test` in `../voltaire` to lock type surface before ZEVM wiring.

### Phase 1: Node bootstrap runtime in ZEVM

6. Write failing test `"NodeRuntime.init uses deterministic defaults"` in `src/node/runtime_test.zig`.
7. Implement `pub fn init(allocator: std.mem.Allocator, config: ?NodeConfig) !NodeRuntime` in `src/node/runtime.zig` with defaults:
   - `chain_id = 31337`
   - deterministic `coinbase`
   - deterministic managed dev accounts
   - head block number initialized to `0`
8. Write failing test `"NodeRuntime.init seeds head block number and canonical head state"`.
9. Implement bootstrap write path that inserts genesis/head metadata into ZEVM runtime state (without introducing duplicate state primitives).
10. Write failing test `"NodeRuntime.deinit releases managed account memory"`.
11. Implement `pub fn deinit(self: *NodeRuntime, allocator: std.mem.Allocator) void`.

### Phase 2: Shared block tag/number parser

12. Write failing tests in `src/rpc/handlers/block_spec_test.zig` for:
   - `latest`
   - `pending`
   - `earliest`
   - explicit hex quantity (`0x0`, `0x1`, `0xa`)
   - invalid strings and malformed hex
13. Implement `pub fn resolveBlockNumber(runtime: *const @import("../../node/runtime.zig").NodeRuntime, block_spec: @import("jsonrpc").types.BlockSpec) !u64` in `src/rpc/handlers/block_spec.zig`.
14. Write failing tests for parser behavior when block number is beyond known head.
15. Implement range validation (`error.BlockOutOfRange`) and map it to JSON-RPC invalid params in dispatcher glue.

### Phase 3: Core read handlers (one method at a time)

16. Write failing test `"eth_chainId returns configured chain id"` in `src/rpc/handlers/eth_read_test.zig`.
17. Implement `pub fn handleEthChainId(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.chainId.EthChainId.Params) !@import("jsonrpc").eth.chainId.EthChainId.Result`.

18. Write failing test `"eth_blockNumber returns current head number"`.
19. Implement `pub fn handleEthBlockNumber(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.blockNumber.EthBlockNumber.Params) !@import("jsonrpc").eth.blockNumber.EthBlockNumber.Result`.

20. Write failing tests for `eth_getBalance` with `latest`, `pending`, `earliest`, and explicit quantity.
21. Implement `pub fn handleEthGetBalance(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.getBalance.EthGetBalance.Params) !@import("jsonrpc").eth.getBalance.EthGetBalance.Result`.

22. Write failing tests for `eth_getCode` (existing account code and empty code).
23. Implement `pub fn handleEthGetCode(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.getCode.EthGetCode.Params) !@import("jsonrpc").eth.getCode.EthGetCode.Result`.

24. Write failing tests for `eth_getStorageAt` (set slot + unset slot).
25. Implement `pub fn handleEthGetStorageAt(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.getStorageAt.EthGetStorageAt.Params) !@import("jsonrpc").eth.getStorageAt.EthGetStorageAt.Result`.

26. Write failing tests for `eth_getTransactionCount` (nonce at each supported block selector).
27. Implement `pub fn handleEthGetTransactionCount(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.getTransactionCount.EthGetTransactionCount.Params) !@import("jsonrpc").eth.getTransactionCount.EthGetTransactionCount.Result`.

28. Write failing tests for `eth_coinbase` and `eth_accounts`.
29. Implement:
   - `pub fn handleEthCoinbase(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.coinbase.EthCoinbase.Params) !@import("jsonrpc").eth.coinbase.EthCoinbase.Result`
   - `pub fn handleEthAccounts(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.accounts.EthAccounts.Params) !@import("jsonrpc").eth.accounts.EthAccounts.Result`

30. Write failing tests for `eth_gasPrice`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee` hex quantity formatting.
31. Implement:
   - `pub fn handleEthGasPrice(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.gasPrice.EthGasPrice.Params) !@import("jsonrpc").eth.gasPrice.EthGasPrice.Result`
   - `pub fn handleEthMaxPriorityFeePerGas(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.maxPriorityFeePerGas.EthMaxPriorityFeePerGas.Params) !@import("jsonrpc").eth.maxPriorityFeePerGas.EthMaxPriorityFeePerGas.Result`
   - `pub fn handleEthBlobBaseFee(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.blobBaseFee.EthBlobBaseFee.Params) !@import("jsonrpc").eth.blobBaseFee.EthBlobBaseFee.Result`

32. Write failing tests for `eth_feeHistory`:
   - returns correctly shaped object
   - validates block count bounds
   - returns hex quantities in quantity fields
33. Implement `pub fn handleEthFeeHistory(allocator: std.mem.Allocator, runtime: *const @import("../../node/runtime.zig").NodeRuntime, params: @import("jsonrpc").eth.feeHistory.EthFeeHistory.Params) !@import("jsonrpc").eth.feeHistory.EthFeeHistory.Result`.

### Phase 4: Routing + integration smoke over HTTP

34. Write failing dispatcher tests in `src/rpc/dispatcher_test.zig` for each method name mapping to the correct handler.
35. Implement routing in `src/rpc/dispatcher.zig` for the 12 methods in scope.
36. Write failing HTTP smoke test in `src/rpc/server_test.zig` that boots runtime + server and calls:
   - `eth_chainId`
   - `eth_getBalance`
   - `eth_feeHistory`
37. Implement any remaining response/error glue for invalid block selectors and invalid params.

### Phase 5: Full verification

38. Run `zig build test` in `zevm`.
39. Add short acceptance-criteria checklist comments to `src/rpc/handlers/eth_read_test.zig` mapping each test to ticket criteria.

## Files to Create/Modify (with function signatures)

### ZEVM files

1. Create `src/node/runtime.zig`
   - `pub const NodeConfig = struct { ... }`
   - `pub const NodeRuntime = struct { ... }`
   - `pub fn init(allocator: std.mem.Allocator, config: ?NodeConfig) !NodeRuntime`
   - `pub fn deinit(self: *NodeRuntime, allocator: std.mem.Allocator) void`

2. Create `src/node/runtime_test.zig`

3. Create `src/rpc/handlers/block_spec.zig`
   - `pub fn resolveBlockNumber(runtime: *const @import("../../node/runtime.zig").NodeRuntime, block_spec: @import("jsonrpc").types.BlockSpec) !u64`

4. Create `src/rpc/handlers/block_spec_test.zig`

5. Create `src/rpc/handlers/eth_read.zig`
   - `pub fn handleEthChainId(...) !@import("jsonrpc").eth.chainId.EthChainId.Result`
   - `pub fn handleEthBlockNumber(...) !@import("jsonrpc").eth.blockNumber.EthBlockNumber.Result`
   - `pub fn handleEthGetBalance(...) !@import("jsonrpc").eth.getBalance.EthGetBalance.Result`
   - `pub fn handleEthGetCode(...) !@import("jsonrpc").eth.getCode.EthGetCode.Result`
   - `pub fn handleEthGetStorageAt(...) !@import("jsonrpc").eth.getStorageAt.EthGetStorageAt.Result`
   - `pub fn handleEthGetTransactionCount(...) !@import("jsonrpc").eth.getTransactionCount.EthGetTransactionCount.Result`
   - `pub fn handleEthGasPrice(...) !@import("jsonrpc").eth.gasPrice.EthGasPrice.Result`
   - `pub fn handleEthCoinbase(...) !@import("jsonrpc").eth.coinbase.EthCoinbase.Result`
   - `pub fn handleEthAccounts(...) !@import("jsonrpc").eth.accounts.EthAccounts.Result`
   - `pub fn handleEthMaxPriorityFeePerGas(...) !@import("jsonrpc").eth.maxPriorityFeePerGas.EthMaxPriorityFeePerGas.Result`
   - `pub fn handleEthBlobBaseFee(...) !@import("jsonrpc").eth.blobBaseFee.EthBlobBaseFee.Result`
   - `pub fn handleEthFeeHistory(...) !@import("jsonrpc").eth.feeHistory.EthFeeHistory.Result`

6. Create `src/rpc/handlers/eth_read_test.zig`

7. Modify `src/rpc/dispatcher.zig` (or create if absent)
   - add route branches for the 12 methods in scope

8. Modify `src/rpc/dispatcher_test.zig` (or create if absent)

9. Modify `src/rpc/server_test.zig` (or create if absent)
   - add HTTP smoke test for representative methods

10. Modify `src/root.zig`
   - export new modules
   - import new tests in root `test {}` block

11. Modify `build.zig` if needed to include any new RPC module imports already provided by dependency ticket.

### Upstream files in voltaire

1. Modify `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/accounts/eth_accounts.zig`
   - fix `Result` to address-array type

2. Modify `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/feeHistory/eth_feeHistory.zig`
   - correct `Params` and `Result` structures to match execution-apis

3. Modify `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` only if type export wiring needs updates.

## Tests to Write

## Unit tests

1. `src/node/runtime_test.zig`
   - deterministic defaults
   - bootstrap head number
   - managed account list ownership/deinit behavior

2. `src/rpc/handlers/block_spec_test.zig`
   - all supported block selectors
   - invalid selector rejection
   - out-of-range explicit block rejection

3. `src/rpc/handlers/eth_read_test.zig`
   - one focused test per handler + method-specific edge cases
   - hex quantity formatting assertions for fee methods
   - state-backed reads (`balance`, `code`, `storage`, `nonce`) across selectors

4. `src/rpc/dispatcher_test.zig`
   - one route test per method name
   - invalid params mapping to JSON-RPC error

5. Upstream voltaire tests
   - `eth_accounts` serde tests
   - `eth_feeHistory` serde tests

## Integration tests

1. `src/rpc/server_test.zig`
   - start node + HTTP server
   - send JSON-RPC requests and verify serialized response shapes
   - include one negative test for invalid block selector on state-read method

2. Optional black-box parity check (if quickly portable)
   - port a minimal execution-apis case for `eth_getBalance`
   - port a minimal `eth_feeHistory` shape validation case

## Risks and Mitigations

1. Risk: `voltaire` method types for `eth_accounts` and `eth_feeHistory` are currently not spec-shaped.
   - Mitigation: fix upstream first under Phase 0 and gate ZEVM implementation on upstream test pass.

2. Risk: `BlockSpec` is currently pass-through `std.json.Value`, so malformed inputs can slip through.
   - Mitigation: centralize strict parsing in `resolveBlockNumber` and test all invalid forms.

3. Risk: Quantity formatting bugs (leading zeros, decimal output, wrong type) can break client compatibility.
   - Mitigation: assert exact hex-quantity strings in every fee/read handler test.

4. Risk: Ambiguous pending semantics without mempool integration.
   - Mitigation: document and test `pending` behavior as alias of current head for this ticket scope.

5. Risk: Runtime bootstrap can drift from deterministic values used by tests.
   - Mitigation: keep defaults in a single `NodeConfig.defaults()` path and test through public API only.

## Verification Against Acceptance Criteria

1. Node bootstrap deterministic defaults:
   - covered by `NodeRuntime.init` tests in `src/node/runtime_test.zig`.

2. `eth_chainId` returns configured chain ID:
   - covered by `handleEthChainId` unit test and HTTP smoke call.

3. `eth_blockNumber` returns current head:
   - covered by `handleEthBlockNumber` unit test.

4. `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount` read from state manager:
   - covered by seeded-state handler tests across block selectors.

5. `eth_accounts` returns managed dev accounts:
   - covered by `handleEthAccounts` test and upstream `eth_accounts` type test.

6. `eth_gasPrice`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee`, `eth_feeHistory` return valid hex quantities:
   - covered by exact serialization assertions in handler tests.

7. Block tag/number parsing correctness:
   - covered by `block_spec_test.zig` selector matrix.

8. `zig build test` passes:
   - final verification step after all phases.
