# Plan: tx-sending-and-mempool

## Overview of the approach
Implement this ticket as an upstream-first TDD sequence:

1. Add missing transaction decoding/recovery and txpool primitives in `../voltaire`.
2. Keep ZEVM as the integration layer: RPC handler wiring, state validation, automine orchestration, block persistence, and receipt indexing.
3. Write failing tests before each function/route, then implement only enough code to make that test pass.

This keeps the reusable logic (decode + mempool ordering) upstream, and ZEVM only owns the node-specific wiring.

## TDD step order (tests before implementation)

### Phase 0: Upstream scaffolding (voltaire)

1. Test: `../voltaire/packages/voltaire-zig/src/txpool/TxPool.zig` compile/import test from a new test block in voltaire build.
2. Implementation: add `txpool` module export in `../voltaire/build.zig` and `../voltaire/packages/voltaire-zig/src/txpool/root.zig`.

### Phase 1: Raw transaction decode + sender recovery (voltaire)

3. Test: `decode legacy raw tx -> hash + sender + nonce + gas fields` using `execution-apis/tests/eth_sendRawTransaction/send-legacy-transaction.io` vector.
4. Implementation: add `decodeLegacySignedTransaction(...)` in `../voltaire/packages/voltaire-zig/src/primitives/Transaction/raw_decode.zig`.

5. Test: `decode type-1/type-2/type-3 raw tx -> hash + sender + nonce + fee fields` using the four typed vectors.
6. Implementation: add `decodeEip2930SignedTransaction(...)`, `decodeEip1559SignedTransaction(...)`, `decodeEip4844SignedTransaction(...)`, and typed envelope dispatch `decodeRawSignedTransaction(...)`.

7. Test: `invalid signature` and `chain id mismatch` are rejected.
8. Implementation: add signature/chain-id validation helpers and error set in `raw_decode.zig`.

### Phase 2: Nonce-ordered mempool core (voltaire)

9. Test: `add()` stores per-sender queue ordered by nonce.
10. Implementation: `TxPool.add(...)` with sender map + nonce ordering.

11. Test: `getReady()` returns only current-nonce txs and orders by gas price desc, nonce asc.
12. Implementation: `TxPool.getReady(...)` sorting logic.

13. Test: `removeMined()` removes included txs and promotes newly unblocked txs.
14. Implementation: `TxPool.removeMined(...)` promotion logic.

15. Test: `pendingCount()` reflects add/remove transitions.
16. Implementation: `TxPool.pendingCount(...)`.

### Phase 3: ZEVM runtime wiring for tx submission

17. Test (unit): runtime config exposes managed accounts + mining mode defaults.
18. Implementation: add `src/rpc/runtime.zig` (`NodeRuntime`, `NodeConfig`, `MiningMode`, account lookup).

19. Test (integration): `eth_sendRawTransaction` rejects nonce mismatch.
20. Implementation: add `validateNonce(...)` in `src/rpc/tx_submission_handlers.zig`.

21. Test (integration): `eth_sendRawTransaction` rejects insufficient balance.
22. Implementation: add `validateBalance(...)`.

23. Test (integration): `eth_sendRawTransaction` rejects intrinsic gas > gasLimit.
24. Implementation: add `validateGasLimit(...)`.

25. Test (integration): valid `eth_sendRawTransaction` returns tx hash and inserts into txpool.
26. Implementation: add route function `ethSendRawTransaction(...)` and txpool insertion path.

### Phase 4: Automine integration

27. Test (integration): when mining mode is `auto`, submitting a ready tx mines one block immediately.
28. Implementation: add `maybeAutomine(...)` that:
- pulls ready txs from txpool
- calls `block_builder.buildBlock(...)`
- flushes state trie (`Database.syncCachedAccountsToTrie`)
- persists block in `blockchain.Blockchain` (`putBlock` + `setCanonicalHead`)
- updates block hash index
- prunes mined txs from pool.

29. Test (integration): mined tx receipt is queryable by hash.
30. Implementation: add receipt index store + `getTransactionReceipt(...)` helper in runtime/handlers.

### Phase 5: `eth_sendTransaction` managed-key path

31. Test (integration): managed `from` account signs + submits and returns hash.
32. Implementation: add `ethSendTransaction(...)` route (build unsigned request, sign with configured managed private key, then reuse raw-tx path).

33. Test (integration): unmanaged `from` account returns JSON-RPC error.
34. Implementation: enforce managed-account guard in `ethSendTransaction(...)`.

### Phase 6: Execution-APIs vector coverage and final verification

35. Test (integration): parse and run all 5 `execution-apis/tests/eth_sendRawTransaction/*.io` vectors through ZEVM handler, assert expected tx hash result.
36. Implementation: add vector harness in ZEVM tests; seed sender state (balance + nonce) from decoded tx to isolate submission semantics.

37. Verification run: `zig build test` in ZEVM.
38. Verification run: `zig build test` in `../voltaire` for upstream additions.

## Files to create/modify (with specific function signatures)

### Voltaire (upstream)

- `../voltaire/packages/voltaire-zig/src/txpool/root.zig` (new)
```zig
pub const TxPool = @import("TxPool.zig").TxPool;
pub const PooledTransaction = @import("TxPool.zig").PooledTransaction;
```

- `../voltaire/packages/voltaire-zig/src/txpool/TxPool.zig` (new)
```zig
pub const PooledTransaction = struct {
    hash: primitives.Hash.Hash,
    sender: primitives.Address,
    nonce: u64,
    gas_price_for_ordering: u256,
    raw: []const u8,
    execution_legacy: ?primitives.Transaction.LegacyTransaction,
};

pub const TxPool = struct {
    pub fn init() TxPool;
    pub fn deinit(self: *TxPool, allocator: std.mem.Allocator) void;
    pub fn add(self: *TxPool, allocator: std.mem.Allocator, tx: PooledTransaction, sender_current_nonce: u64) !void;
    pub fn removeMined(self: *TxPool, allocator: std.mem.Allocator, mined_hashes: []const primitives.Hash.Hash) !void;
    pub fn getReady(self: *const TxPool, allocator: std.mem.Allocator, state_nonce_fn: *const fn (primitives.Address) u64) ![]PooledTransaction;
    pub fn pendingCount(self: *const TxPool) usize;
};
```

- `../voltaire/packages/voltaire-zig/src/primitives/Transaction/raw_decode.zig` (new)
```zig
pub const RawTransactionType = enum { legacy, eip2930, eip1559, eip4844 };

pub const DecodedRawTransaction = struct {
    tx_type: RawTransactionType,
    hash: primitives.Hash.Hash,
    sender: primitives.Address,
    nonce: u64,
    gas_limit: u64,
    gas_price_for_ordering: u256,
    chain_id: ?u64,
    execution_legacy: ?primitives.Transaction.LegacyTransaction,
};

pub fn decodeRawSignedTransaction(allocator: std.mem.Allocator, raw_tx_bytes: []const u8) !DecodedRawTransaction;
```

- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionRequest.zig` (new)
```zig
pub const TransactionRequest = struct {
    from: types.Address,
    to: ?types.Address = null,
    gas: ?types.Quantity = null,
    gasPrice: ?types.Quantity = null,
    maxFeePerGas: ?types.Quantity = null,
    maxPriorityFeePerGas: ?types.Quantity = null,
    value: ?types.Quantity = null,
    nonce: ?types.Quantity = null,
    input: ?types.Quantity = null,
    data: ?types.Quantity = null,

    pub fn jsonStringify(self: TransactionRequest, jws: *std.json.Stringify) !void;
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !TransactionRequest;
};
```

- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/sendTransaction/eth_sendTransaction.zig` (modify)
```zig
pub const Params = struct {
    transaction: types.TransactionRequest,
    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void;
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params;
};
```

- `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` (modify: export `TransactionRequest`)
- `../voltaire/build.zig` (modify: export `txpool` module + tests)

### ZEVM

- `build.zig` (modify: import voltaire `txpool` module into ZEVM module graph)

- `src/rpc/runtime.zig` (new)
```zig
pub const MiningMode = enum { auto, manual };

pub const ManagedAccount = struct {
    address: primitives.Address,
    private_key: crypto.PrivateKey,
};

pub const NodeConfig = struct {
    chain_id: u64,
    mining_mode: MiningMode = .auto,
    managed_accounts: []const ManagedAccount,
};

pub const NodeRuntime = struct {
    config: NodeConfig,
    database: *database.Database,
    chain: *blockchain.Blockchain,
    host_iface: guillotine_mini.HostInterface,
    txpool: txpool.TxPool,
    current_block_number: u64,
    receipts_by_hash: std.AutoHashMapUnmanaged(primitives.Hash.Hash, primitives.Receipt.Receipt),

    pub fn deinit(self: *NodeRuntime, allocator: std.mem.Allocator) void;
    pub fn lookupManagedAccount(self: *const NodeRuntime, address: primitives.Address) ?crypto.PrivateKey;
};
```

- `src/rpc/tx_submission_handlers.zig` (new)
```zig
pub fn ethSendRawTransaction(
    allocator: std.mem.Allocator,
    runtime: *runtime.NodeRuntime,
    params: jsonrpc.eth.methods.EthMethodMap.eth_sendRawTransaction.params,
    block_ctx: guillotine_mini.BlockContext,
) !primitives.Hash.Hash;

pub fn ethSendTransaction(
    allocator: std.mem.Allocator,
    runtime: *runtime.NodeRuntime,
    params: jsonrpc.eth.methods.EthMethodMap.eth_sendTransaction.params,
    block_ctx: guillotine_mini.BlockContext,
) !primitives.Hash.Hash;

pub fn getTransactionReceipt(
    runtime: *const runtime.NodeRuntime,
    tx_hash: primitives.Hash.Hash,
) ?primitives.Receipt.Receipt;
```

- `src/block_builder.zig` (modify)
```zig
pub const IncludedTransaction = struct {
    hash: primitives.Hash.Hash,
    sender: primitives.Address,
    nonce: u64,
};

pub const BlockResult = struct {
    receipts: []primitives.Receipt.Receipt,
    included_transactions: []IncludedTransaction,
    total_gas_used: u64,
    block_number: u64,
    pub fn deinit(self: *BlockResult, allocator: std.mem.Allocator) void;
};
```

- `src/rpc/tx_submission_handlers_test.zig` (new)
- `src/rpc/execution_api_send_raw_vectors_test.zig` (new)
- `src/root.zig` (modify: export/import new RPC test modules)

## Tests to write

### Unit tests (voltaire)

1. Raw decode legacy: hash/sender/nonce/fee extraction matches known vector.
2. Raw decode typed (2930/1559/4844): parser and sender recovery succeed.
3. Raw decode invalid signature: fails with explicit error.
4. TxPool add ordering: sender queue is nonce-ordered.
5. TxPool ready ordering: cross-sender ordering is gas-price desc then nonce.
6. TxPool remove mined: dependent nonce transactions become ready.
7. TxPool pending count: add/remove transitions are correct.

### Unit tests (ZEVM runtime)

8. Managed account lookup returns private key for configured address.
9. Managed account lookup returns null for unknown address.
10. Mining mode defaults to `auto`.

### Integration tests (ZEVM handlers)

11. `eth_sendRawTransaction` nonce mismatch -> error.
12. `eth_sendRawTransaction` insufficient balance -> error.
13. `eth_sendRawTransaction` intrinsic gas > gas limit -> error.
14. `eth_sendRawTransaction` valid tx -> returns hash and inserts into pool.
15. Automine `auto` mines immediately: block persisted and head increments.
16. Automine `manual` does not mine immediately.
17. Receipt query returns mined receipt by hash.
18. `eth_sendTransaction` managed account signs + submits + returns hash.
19. `eth_sendTransaction` unmanaged account -> error.

### Execution-APIs vector integration tests

20. `execution-apis/tests/eth_sendRawTransaction/send-legacy-transaction.io`
21. `execution-apis/tests/eth_sendRawTransaction/send-access-list-transaction.io`
22. `execution-apis/tests/eth_sendRawTransaction/send-dynamic-fee-transaction.io`
23. `execution-apis/tests/eth_sendRawTransaction/send-dynamic-fee-access-list-transaction.io`
24. `execution-apis/tests/eth_sendRawTransaction/send-blob-tx.io`

All five assert returned tx hash equals expected response hash.

## Risks and mitigations

1. Risk: typed transaction execution semantics (access list/blob details) differ from legacy path.
Mitigation: keep typed decode/recovery upstream-compliant and normalize only the execution fields ZEVM currently supports; cover hash correctness with execution-apis vectors; add follow-up ticket for full typed execution semantics.

2. Risk: no existing RPC server module in current ZEVM tree.
Mitigation: implement route functions in `src/rpc/tx_submission_handlers.zig` with direct tests; wire into HTTP dispatcher in the RPC-server ticket branch without changing handler signatures.

3. Risk: receipt ownership/memory leaks when storing receipts in index.
Mitigation: store owned copies, add explicit `deinit` coverage in runtime tests, and run `zig build test` with leak checks enabled.

4. Risk: chain head persistence can fail if block header/body assembly is incomplete.
Mitigation: use existing `primitives.Block.from(...)` + `blockchain.Blockchain.putBlock/setCanonicalHead` path and test head-number increment explicitly.

5. Risk: upstream API churn between ZEVM and voltaire.
Mitigation: keep ZEVM depending only on exported, stable upstream signatures listed above; add compile-time import tests in both repos.

## Verification against acceptance criteria

1. Mempool stores nonce-ordered sender queues: TxPool unit tests 4 and 6.
2. Ready tx ordering by gas price: TxPool unit test 5.
3. `eth_sendRawTransaction` decodes RLP, recovers sender, returns hash: raw decode unit tests 1-3 + integration test 14.
4. Nonce/balance/gas-limit validation: integration tests 11-13.
5. Valid raw tx added to mempool: integration test 14.
6. `eth_sendTransaction` signs with managed key and submits: integration test 18.
7. Unmanaged account error: integration test 19.
8. Automine triggers block build when mode is auto: integration test 15.
9. Block stored and block number increments: integration test 15.
10. Receipts queryable after mining: integration test 17.
11. execution-apis `eth_sendRawTransaction` vectors (5) pass: vector tests 20-24.
12. `zig build test` passes: phase 6 verification steps 37-38.
