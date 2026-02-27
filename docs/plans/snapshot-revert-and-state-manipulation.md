# Plan: snapshot-revert-and-state-manipulation

## Overview of the approach
Implement this ticket in three layers, in strict upstream-first order:
1. Add missing JSON-RPC method types in `voltaire` for `evm_*`, `hardhat_*`, and `anvil_*`.
2. Add deterministic snapshot/revert primitives for block rollback in `voltaire` blockchain storage, so zevm can clear mined blocks after a revert.
3. Add zevm integration handlers that wire RPC -> node runtime state -> `StateManager`/blockchain/mempool/config, with alias routing (`anvil_*` -> same behavior as `hardhat_*`).

All steps are TDD-first: write a failing test, then implement exactly the function/route needed to pass that test before moving on.

---

## TDD Step Order (tests before implementation)

### Phase A - Voltaire JSON-RPC method types

1. **Test**: add `evm_snapshot` serde tests  
File: `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/snapshot/evm_snapshot.zig`  
Test names:
- `test "evm_snapshot Params parses empty array"`
- `test "evm_snapshot Result serializes quantity"`

2. **Implementation**: create `evm_snapshot` method type  
File: `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/snapshot/evm_snapshot.zig`  
Add:
- `pub const method = "evm_snapshot";`
- `pub const Params` (no params)
- `pub const Result` (`types.Quantity`)

3. **Test**: add `evm_revert` serde tests  
File: `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/revert/evm_revert.zig`  
Test names:
- `test "evm_revert Params parses [snapshotId]"`
- `test "evm_revert Result serializes bool"`

4. **Implementation**: create `evm_revert` method type  
File: `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/revert/evm_revert.zig`  
Add:
- `pub const method = "evm_revert";`
- `pub const Params { snapshot_id: types.Quantity }`
- `pub const Result { value: bool }`

5. **Test**: add `evm_setBlockGasLimit` serde tests  
File: `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/setBlockGasLimit/evm_setBlockGasLimit.zig`  
Test names:
- `test "evm_setBlockGasLimit Params parses [limit]"`
- `test "evm_setBlockGasLimit Result serializes bool"`

6. **Implementation**: create `evm_setBlockGasLimit` method type  
File: `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/setBlockGasLimit/evm_setBlockGasLimit.zig`

7. **Test**: add one failing test per hardhat method type (params+result shape)  
Files:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setBalance/hardhat_setBalance.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setCode/hardhat_setCode.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setNonce/hardhat_setNonce.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setStorageAt/hardhat_setStorageAt.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setCoinbase/hardhat_setCoinbase.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setNextBlockBaseFeePerGas/hardhat_setNextBlockBaseFeePerGas.zig`

8. **Implementation**: add hardhat method type files  
Method constants:
- `hardhat_setBalance`
- `hardhat_setCode`
- `hardhat_setNonce`
- `hardhat_setStorageAt`
- `hardhat_setCoinbase`
- `hardhat_setNextBlockBaseFeePerGas`  
Result type for all setters: `{ value: bool }`.

9. **Test**: add one failing test per anvil alias type  
Files:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setBalance/anvil_setBalance.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setCode/anvil_setCode.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setNonce/anvil_setNonce.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setStorageAt/anvil_setStorageAt.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setCoinbase/anvil_setCoinbase.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setNextBlockBaseFeePerGas/anvil_setNextBlockBaseFeePerGas.zig`

10. **Implementation**: add anvil alias method type files  
Same param/result shapes as hardhat equivalents, method names `anvil_*`.

11. **Test**: namespace dispatch maps resolve all new methods  
Files:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/methods.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/methods.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/methods.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`  
Test names:
- `test "EvmMethod.fromMethodName resolves evm_snapshot/revert/setBlockGasLimit"`
- `test "HardhatMethod.fromMethodName resolves all hardhat setters"`
- `test "AnvilMethod.fromMethodName resolves all anvil aliases"`
- `test "JsonRpcMethod includes evm hardhat anvil namespaces"`

12. **Implementation**: wire method unions and root exports  
Files:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/methods.zig` (new)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/methods.zig` (new)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/methods.zig` (new)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig` (modify)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig` (modify)

### Phase B - Voltaire blockchain rollback primitive (required by `evm_revert`)

13. **Test**: block store rollback removes canonical entries above snapshot block  
File: `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`  
Test names:
- `test "BlockStore.revertToBlock truncates canonical chain above target"`
- `test "BlockStore.revertToBlock keeps target block canonical"`

14. **Implementation**: add block store rollback API  
File: `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`  
Signature:
```zig
pub fn revertToBlock(self: *BlockStore, block_number: u64) !void
```

15. **Test**: blockchain facade exposes rollback  
File: `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`  
Test names:
- `test "Blockchain.revertToBlock truncates head to target"`

16. **Implementation**: add blockchain rollback API  
File: `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`  
Signature:
```zig
pub fn revertToBlock(self: *Blockchain, block_number: u64) !void
```

### Phase C - Zevm snapshot runtime + handlers

17. **Test**: zevm runtime snapshot metadata (state id + block number + mempool + config)  
File: `src/rpc/dev_runtime_test.zig` (new)  
Test names:
- `test "takeSnapshot stores state snapshot id and block number"`
- `test "takeSnapshot clones pending transactions and node config"`

18. **Implementation**: add snapshot runtime container  
File: `src/rpc/dev_runtime.zig` (new)  
Types/signatures:
```zig
pub const NodeDevConfig = struct {
    coinbase: primitives.Address,
    next_block_base_fee_per_gas: ?u256,
    block_gas_limit: u64,
};

pub const SnapshotEntry = struct {
    state_snapshot_id: u64,
    block_number: u64,
    pending_transactions: []tx_pool.PendingTransaction,
    config: NodeDevConfig,
};

pub const DevRuntime = struct {
    snapshots: std.AutoHashMapUnmanaged(u64, SnapshotEntry),
    next_snapshot_id: u64,
    config: NodeDevConfig,
    // references to db/blockchain/txpool are owned by caller
    pub fn deinit(self: *DevRuntime, allocator: std.mem.Allocator) void;
    pub fn takeSnapshot(
        self: *DevRuntime,
        allocator: std.mem.Allocator,
        state: *state_manager.StateManager,
        block_number: u64,
        pending_transactions: []const tx_pool.PendingTransaction,
    ) !u64;
};
```

19. **Test**: revert behavior (success, invalid id, nested snapshots)  
File: `src/rpc/dev_runtime_test.zig`  
Test names:
- `test "revertSnapshot returns false for unknown id"`
- `test "revertSnapshot restores block number and config"`
- `test "revertSnapshot removes newer snapshots (nested semantics)"`

20. **Implementation**: add `revertSnapshot` runtime API and cleanup rules  
File: `src/rpc/dev_runtime.zig`  
Signature:
```zig
pub fn revertSnapshot(
    self: *DevRuntime,
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    blockchain: *blockchain.Blockchain,
    txpool: *tx_pool.TxPool,
    snapshot_id: u64,
) !bool
```

21. **Test**: handler for `evm_snapshot` returns hex ID  
File: `src/rpc/dev_handlers_test.zig` (new)  
Test name:
- `test "handleEvmSnapshot returns quantity-encoded snapshot id"`

22. **Implementation**: add `handleEvmSnapshot`  
File: `src/rpc/dev_handlers.zig` (new)  
Signature:
```zig
pub fn handleEvmSnapshot(
    allocator: std.mem.Allocator,
    runtime: *dev_runtime.DevRuntime,
    state: *state_manager.StateManager,
    block_number: u64,
    txpool: *tx_pool.TxPool,
) !@import("jsonrpc").evm.snapshot.EvmSnapshot.Result
```

23. **Test**: handler for `evm_revert` block rollback + boolean result  
File: `src/rpc/dev_handlers_test.zig`  
Test names:
- `test "handleEvmRevert returns true and rolls state back on valid id"`
- `test "handleEvmRevert returns false on invalid id"`

24. **Implementation**: add `handleEvmRevert`  
File: `src/rpc/dev_handlers.zig`  
Signature:
```zig
pub fn handleEvmRevert(
    allocator: std.mem.Allocator,
    runtime: *dev_runtime.DevRuntime,
    state: *state_manager.StateManager,
    blockchain: *blockchain.Blockchain,
    txpool: *tx_pool.TxPool,
    params: @import("jsonrpc").evm.revert.EvmRevert.Params,
) !@import("jsonrpc").evm.revert.EvmRevert.Result
```

25. **Test**: one test per state-manipulation handler  
File: `src/rpc/dev_handlers_test.zig`  
Test names:
- `test "hardhat_setBalance updates account balance immediately"`
- `test "hardhat_setCode updates account code immediately"`
- `test "hardhat_setNonce updates account nonce immediately"`
- `test "hardhat_setStorageAt updates storage slot immediately"`
- `test "hardhat_setCoinbase updates runtime coinbase"`
- `test "hardhat_setNextBlockBaseFeePerGas updates next base fee"`
- `test "evm_setBlockGasLimit updates next block gas limit"`

26. **Implementation**: add hardhat/evm mutation handler functions  
File: `src/rpc/dev_handlers.zig`  
Signatures:
```zig
pub fn handleHardhatSetBalance(
    state: *state_manager.StateManager,
    params: @import("jsonrpc").hardhat.setBalance.HardhatSetBalance.Params,
) !@import("jsonrpc").hardhat.setBalance.HardhatSetBalance.Result

pub fn handleHardhatSetCode(
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    params: @import("jsonrpc").hardhat.setCode.HardhatSetCode.Params,
) !@import("jsonrpc").hardhat.setCode.HardhatSetCode.Result

pub fn handleHardhatSetNonce(
    state: *state_manager.StateManager,
    params: @import("jsonrpc").hardhat.setNonce.HardhatSetNonce.Params,
) !@import("jsonrpc").hardhat.setNonce.HardhatSetNonce.Result

pub fn handleHardhatSetStorageAt(
    state: *state_manager.StateManager,
    params: @import("jsonrpc").hardhat.setStorageAt.HardhatSetStorageAt.Params,
) !@import("jsonrpc").hardhat.setStorageAt.HardhatSetStorageAt.Result

pub fn handleHardhatSetCoinbase(
    runtime: *dev_runtime.DevRuntime,
    params: @import("jsonrpc").hardhat.setCoinbase.HardhatSetCoinbase.Params,
) !@import("jsonrpc").hardhat.setCoinbase.HardhatSetCoinbase.Result

pub fn handleHardhatSetNextBlockBaseFeePerGas(
    runtime: *dev_runtime.DevRuntime,
    params: @import("jsonrpc").hardhat.setNextBlockBaseFeePerGas.HardhatSetNextBlockBaseFeePerGas.Params,
) !@import("jsonrpc").hardhat.setNextBlockBaseFeePerGas.HardhatSetNextBlockBaseFeePerGas.Result

pub fn handleEvmSetBlockGasLimit(
    runtime: *dev_runtime.DevRuntime,
    params: @import("jsonrpc").evm.setBlockGasLimit.EvmSetBlockGasLimit.Params,
) !@import("jsonrpc").evm.setBlockGasLimit.EvmSetBlockGasLimit.Result
```

27. **Test**: alias routing (`anvil_*`) maps to same behavior/results  
File: `src/rpc/routing_test.zig` (new or existing dispatch test file)  
Test names:
- `test "anvil_setBalance aliases hardhat_setBalance"`
- `test "anvil_setCode aliases hardhat_setCode"`
- `test "anvil_setNonce aliases hardhat_setNonce"`
- `test "anvil_setStorageAt aliases hardhat_setStorageAt"`
- `test "anvil_setCoinbase aliases hardhat_setCoinbase"`
- `test "anvil_setNextBlockBaseFeePerGas aliases hardhat_setNextBlockBaseFeePerGas"`

28. **Implementation**: dispatch routing cases for `evm`, `hardhat`, `anvil`  
Files:
- `src/rpc_server.zig` (or current dispatch module)
- `build.zig` (if `jsonrpc` import not yet wired)  
Implementation rule: each `anvil_*` route calls the corresponding hardhat handler.

29. **Test**: JSON-RPC integration (request envelope -> response envelope)  
File: `src/rpc/dev_methods_integration_test.zig` (new)  
Cases:
- `evm_snapshot` then mutate state then `evm_revert`
- revert clears mined blocks above snapshot block
- anvil aliases return same boolean success shape as hardhat methods

30. **Implementation**: finalize wiring in `src/root.zig` and test imports  
Files:
- `src/root.zig`
- `src/rpc/root.zig` (new, optional module index)

31. **Verification step**  
Run:
- `cd ../voltaire && zig build test`
- `cd /Users/williamcory/zevm && zig build test`

---

## Files to create/modify (with specific function signatures)

### Voltaire (upstream)

Create:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/snapshot/evm_snapshot.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/revert/evm_revert.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/setBlockGasLimit/evm_setBlockGasLimit.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/methods.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setBalance/hardhat_setBalance.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setCode/hardhat_setCode.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setNonce/hardhat_setNonce.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setStorageAt/hardhat_setStorageAt.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setCoinbase/hardhat_setCoinbase.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/setNextBlockBaseFeePerGas/hardhat_setNextBlockBaseFeePerGas.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/hardhat/methods.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setBalance/anvil_setBalance.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setCode/anvil_setCode.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setNonce/anvil_setNonce.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setStorageAt/anvil_setStorageAt.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setCoinbase/anvil_setCoinbase.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setNextBlockBaseFeePerGas/anvil_setNextBlockBaseFeePerGas.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/methods.zig`

Modify:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`

Key new signatures:
```zig
pub fn revertToBlock(self: *BlockStore, block_number: u64) !void
pub fn revertToBlock(self: *Blockchain, block_number: u64) !void
```

### Zevm

Create:
- `src/rpc/dev_runtime.zig`
- `src/rpc/dev_handlers.zig`
- `src/rpc/dev_runtime_test.zig`
- `src/rpc/dev_handlers_test.zig`
- `src/rpc/routing_test.zig`
- `src/rpc/dev_methods_integration_test.zig`
- `src/rpc/root.zig` (optional index module)

Modify:
- `src/rpc_server.zig` (or active RPC dispatch file)
- `src/root.zig`
- `build.zig` (if `jsonrpc` import is still missing)

Key new signatures:
```zig
pub fn takeSnapshot(
    self: *DevRuntime,
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    block_number: u64,
    pending_transactions: []const tx_pool.PendingTransaction,
) !u64

pub fn revertSnapshot(
    self: *DevRuntime,
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    blockchain: *blockchain.Blockchain,
    txpool: *tx_pool.TxPool,
    snapshot_id: u64,
) !bool
```

---

## Tests to write (unit + integration)

### Unit tests

- Voltaire method-type serde tests for each new `evm_*`, `hardhat_*`, and `anvil_*` module.
- Voltaire namespace method-map tests for `fromMethodName` and `methodName`.
- Voltaire rollback tests for `BlockStore.revertToBlock` and `Blockchain.revertToBlock`.
- Zevm runtime tests for snapshot capture, invalid snapshot revert, nested snapshot semantics.
- Zevm handler tests for each state mutation method and `evm_snapshot`/`evm_revert` return shapes.
- Zevm alias tests ensuring `anvil_*` routes are behaviorally identical to hardhat routes.

### Integration tests

- JSON-RPC request/response tests that call the dispatch path end-to-end:
  - `evm_snapshot` returns quantity-encoded ID string.
  - `evm_revert` returns `true` on valid ID and `false` on invalid ID.
  - State mutations are immediately observable via direct state reads.
  - Revert restores state, block number, and pending tx pool snapshot.
  - Revert removes blocks mined after snapshot point.

---

## Risks and mitigations

1. **Risk: mempool snapshot semantics may drift from tx-pool implementation.**  
Mitigation: require `TxPool.clonePending` + `TxPool.replacePending` (or equivalent) and test deep-copy behavior.

2. **Risk: rollback only truncates canonical mapping but leaves stale block objects accessible by hash.**  
Mitigation: define explicit rollback semantics in `BlockStore.revertToBlock`; test both canonical and hash lookups post-revert.

3. **Risk: hex parsing ambiguity (`Quantity` vs fixed-width DATA) for storage slot/value.**  
Mitigation: parse and validate slot/value in zevm handlers with strict checks; add negative tests for malformed hex and wrong width.

4. **Risk: alias drift (`anvil_*` path diverges from hardhat behavior).**  
Mitigation: implement alias routes as direct calls to hardhat handler functions and assert response equality in routing tests.

5. **Risk: upstream/downstream ordering causes temporary breakage.**  
Mitigation: land in this order: Voltaire types -> Voltaire rollback API -> zevm handler wiring.

---

## Verification against acceptance criteria

1. `evm_snapshot` returns hex snapshot ID  
Validated by `handleEvmSnapshot returns quantity-encoded snapshot id`.

2. `evm_snapshot` captures StateManager state and block number  
Validated by `takeSnapshot stores state snapshot id and block number`.

3. `evm_revert` restores state to snapshot point  
Validated by `handleEvmRevert returns true and rolls state back on valid id`.

4. `evm_revert` reverts block number and clears later blocks  
Validated by integration test + `Blockchain.revertToBlock truncates head to target`.

5. `evm_revert` returns true on success, false on invalid ID  
Validated by two explicit revert tests.

6. Nested snapshots work correctly  
Validated by `revertSnapshot removes newer snapshots (nested semantics)`.

7. `hardhat_setBalance` updates immediately  
Validated by `hardhat_setBalance updates account balance immediately`.

8. `hardhat_setCode` updates immediately  
Validated by `hardhat_setCode updates account code immediately`.

9. `hardhat_setNonce` updates immediately  
Validated by `hardhat_setNonce updates account nonce immediately`.

10. `hardhat_setStorageAt` updates immediately  
Validated by `hardhat_setStorageAt updates storage slot immediately`.

11. `hardhat_setCoinbase` updates coinbase  
Validated by `hardhat_setCoinbase updates runtime coinbase`.

12. `hardhat_setNextBlockBaseFeePerGas` affects next block  
Validated by base-fee runtime test + block-build integration assertion.

13. `evm_setBlockGasLimit` updates next block gas limit  
Validated by `evm_setBlockGasLimit updates next block gas limit`.

14. `anvil_*` aliases work for hardhat methods  
Validated by alias routing tests.

15. Voltaire jsonrpc has anvil/evm method type definitions  
Validated by namespace map tests and `JsonRpcMethod includes evm hardhat anvil namespaces`.

16. `zig build test` passes  
Validated in final verification step after upstream + zevm changes.
