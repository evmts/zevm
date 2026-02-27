# Plan: implement-rpc-handlers-block-queries

## Overview

Implement six block query RPC handlers in ZEVM:

1. `eth_getBlockByNumber`
2. `eth_getBlockByHash`
3. `eth_getTransactionByHash`
4. `eth_getTransactionReceipt`
5. `eth_getBlockReceipts`
6. `eth_getLogs`

Approach:

1. Add missing typed RPC response/filter types in `../voltaire` (upstream-first, no ZEVM duplication).
2. Add ZEVM query indexes for receipts/transactions and a single block-indexing hook.
3. Implement shared block-spec resolution and primitive->RPC conversion helpers.
4. Implement each handler behind unit tests (test first, then implementation).
5. Wire handlers into existing dispatch from the HTTP JSON-RPC ticket.
6. Validate behavior against execution-apis vectors for the six in-scope methods.

## Preconditions / Dependency Gates

This ticket depends on previously planned work. Before coding handlers, verify these are present (or land them first):

1. `src/database/database.zig` has `blockchain: @import("blockchain").Blockchain`.
2. A reachable RPC dispatch layer exists in ZEVM (`src/rpc_server.zig` or equivalent from `http-jsonrpc-server-and-dispatch`).
3. A block-commit path exists that can call a ZEVM indexing hook after canonical head update.

Current workspace note:

1. ZEVM currently has no RPC server/dispatch files.
2. `../guillotine-mini` in this workspace does not currently include RPC dispatch modules, so routing is expected in ZEVM (using voltaire method types).

## Files To Create / Modify (with planned signatures)

## Voltaire (Create)

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/types/RpcLog.zig`
   - `pub const RpcLog = struct { ... }`
   - `pub fn fromPrimitive(log: primitives.EventLog.EventLog, block_hash: primitives.Hash.Hash, block_timestamp: u64) RpcLog`

2. `../voltaire/packages/voltaire-zig/src/jsonrpc/types/RpcReceipt.zig`
   - `pub const RpcReceipt = struct { ... }`
   - `pub fn fromPrimitive(allocator: std.mem.Allocator, receipt: primitives.Receipt.Receipt, block_timestamp: u64) !RpcReceipt`
   - `pub fn deinit(self: *RpcReceipt, allocator: std.mem.Allocator) void`

3. `../voltaire/packages/voltaire-zig/src/jsonrpc/types/RpcTransaction.zig`
   - `pub const RpcTransaction = struct { ... }`
   - `pub const TxContext = struct { block_hash: ?primitives.Hash.Hash, block_number: ?u64, transaction_index: ?u32, block_timestamp: ?u64, from: primitives.Address.Address }`
   - `pub fn fromDecoded(allocator: std.mem.Allocator, decoded: primitives.Transaction.DecodedTransaction, tx_hash: primitives.Hash.Hash, ctx: TxContext) !RpcTransaction`
   - `pub fn deinit(self: *RpcTransaction, allocator: std.mem.Allocator) void`

4. `../voltaire/packages/voltaire-zig/src/jsonrpc/types/RpcBlock.zig`
   - `pub const RpcBlock = struct { ... }`
   - `pub fn fromPrimitive(allocator: std.mem.Allocator, block: primitives.Block.Block, txs: []const RpcBlockTransaction) !RpcBlock`
   - `pub fn deinit(self: *RpcBlock, allocator: std.mem.Allocator) void`

## Voltaire (Modify)

1. `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig`
   - export `RpcBlock`, `RpcTransaction`, `RpcReceipt`, `RpcLog`

2. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByNumber/eth_getBlockByNumber.zig`
   - `pub const Result = struct { block: ?types.RpcBlock, ... }`

3. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByHash/eth_getBlockByHash.zig`
   - `pub const Result = struct { block: ?types.RpcBlock, ... }`

4. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionByHash/eth_getTransactionByHash.zig`
   - `pub const Result = struct { tx: ?types.RpcTransaction, ... }`

5. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionReceipt/eth_getTransactionReceipt.zig`
   - `pub const Result = struct { receipt: ?types.RpcReceipt, ... }`

6. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockReceipts/eth_getBlockReceipts.zig`
   - `pub const Result = struct { receipts: ?[]const types.RpcReceipt, ... }`

7. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getLogs/eth_getLogs.zig`
   - `pub const FilterObject = struct { ... }`
   - `pub const Params = struct { filter: FilterObject, ... }`
   - `pub const Result = struct { logs: []const types.RpcLog, ... }`

8. `../voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig` (if decode helper missing)
   - `pub const DecodedTransaction = union(enum) { legacy: LegacyTransaction, eip2930: Eip2930Transaction, eip1559: Eip1559Transaction, eip4844: Eip4844Transaction, eip7702: Eip7702Transaction }`
   - `pub fn decodeRawTransaction(allocator: std.mem.Allocator, raw: []const u8) !DecodedTransaction`
   - `pub fn hashRawTransaction(allocator: std.mem.Allocator, raw: []const u8) !Hash.Hash`

## ZEVM (Create)

1. `src/rpc_handlers/root.zig`
   - exports all six handlers and shared helpers.

2. `src/rpc_handlers/block_spec.zig`
   - `pub fn resolveBlockNumber(blockchain: *@import("blockchain").Blockchain, spec: @import("jsonrpc").types.BlockSpec) !?u64`
   - `pub fn resolveBlockHash(blockchain: *@import("blockchain").Blockchain, spec: @import("jsonrpc").types.BlockSpec) !?primitives.Hash.Hash`

3. `src/rpc_handlers/conversions.zig`
   - `pub fn toRpcBlock(...) !@import("jsonrpc").types.RpcBlock`
   - `pub fn toRpcTransaction(...) !@import("jsonrpc").types.RpcTransaction`
   - `pub fn toRpcReceipt(...) !@import("jsonrpc").types.RpcReceipt`
   - `pub fn toRpcLog(...) @import("jsonrpc").types.RpcLog`

4. `src/rpc_handlers/eth_getBlockByNumber.zig`
   - `pub fn handle(allocator: std.mem.Allocator, db: *@import("../database/root.zig").Database, params: @import("jsonrpc").eth.getBlockByNumber.EthGetBlockByNumber.Params) !@import("jsonrpc").eth.getBlockByNumber.EthGetBlockByNumber.Result`

5. `src/rpc_handlers/eth_getBlockByHash.zig`
   - `pub fn handle(allocator: std.mem.Allocator, db: *@import("../database/root.zig").Database, params: @import("jsonrpc").eth.getBlockByHash.EthGetBlockByHash.Params) !@import("jsonrpc").eth.getBlockByHash.EthGetBlockByHash.Result`

6. `src/rpc_handlers/eth_getTransactionByHash.zig`
   - `pub fn handle(allocator: std.mem.Allocator, db: *@import("../database/root.zig").Database, params: @import("jsonrpc").eth.getTransactionByHash.EthGetTransactionByHash.Params) !@import("jsonrpc").eth.getTransactionByHash.EthGetTransactionByHash.Result`

7. `src/rpc_handlers/eth_getTransactionReceipt.zig`
   - `pub fn handle(allocator: std.mem.Allocator, db: *@import("../database/root.zig").Database, params: @import("jsonrpc").eth.getTransactionReceipt.EthGetTransactionReceipt.Params) !@import("jsonrpc").eth.getTransactionReceipt.EthGetTransactionReceipt.Result`

8. `src/rpc_handlers/eth_getBlockReceipts.zig`
   - `pub fn handle(allocator: std.mem.Allocator, db: *@import("../database/root.zig").Database, params: @import("jsonrpc").eth.getBlockReceipts.EthGetBlockReceipts.Params) !@import("jsonrpc").eth.getBlockReceipts.EthGetBlockReceipts.Result`

9. `src/rpc_handlers/eth_getLogs.zig`
   - `pub fn handle(allocator: std.mem.Allocator, db: *@import("../database/root.zig").Database, params: @import("jsonrpc").eth.getLogs.EthGetLogs.Params) !@import("jsonrpc").eth.getLogs.EthGetLogs.Result`

10. `src/rpc_handlers/rpc_handlers_test.zig`
11. `src/rpc_handlers/block_spec_test.zig`
12. `src/rpc_handlers/conversions_test.zig`
13. `src/rpc_handlers/eth_getBlockByNumber_test.zig`
14. `src/rpc_handlers/eth_getBlockByHash_test.zig`
15. `src/rpc_handlers/eth_getTransactionByHash_test.zig`
16. `src/rpc_handlers/eth_getTransactionReceipt_test.zig`
17. `src/rpc_handlers/eth_getBlockReceipts_test.zig`
18. `src/rpc_handlers/eth_getLogs_test.zig`

## ZEVM (Modify)

1. `src/database/database.zig`
   - add:
     - `pub const TxLocation = struct { block_hash: primitives.Hash.Hash, block_number: u64, transaction_index: u32 }`
     - `pub const IndexedTransaction = struct { tx_hash: primitives.Hash.Hash, raw: []const u8, sender: primitives.Address.Address }`
     - `receipts_by_tx_hash: std.AutoHashMapUnmanaged(primitives.Hash.Hash, primitives.Receipt.Receipt)`
     - `receipts_by_block_hash: std.AutoHashMapUnmanaged(primitives.Hash.Hash, std.ArrayListUnmanaged(primitives.Receipt.Receipt))`
     - `tx_index: std.AutoHashMapUnmanaged(primitives.Hash.Hash, TxLocation)`
     - `tx_by_hash: std.AutoHashMapUnmanaged(primitives.Hash.Hash, IndexedTransaction)`
   - add:
     - `pub fn indexMinedBlock(self: *Database, allocator: std.mem.Allocator, block: primitives.Block.Block, receipts: []const primitives.Receipt.Receipt, indexed_transactions: []const IndexedTransaction) !void`
     - `pub fn getIndexedTransaction(self: *Database, tx_hash: primitives.Hash.Hash) ?IndexedTransaction`

2. `src/database/root.zig`
   - export new `TxLocation` and `IndexedTransaction` as needed.

3. `src/root.zig`
   - export/import `rpc_handlers` and all new test files.

4. Dispatch integration file from prerequisite (`src/rpc_server.zig` or equivalent)
   - route six method tags to `src/rpc_handlers/*` handlers.

5. Block commit integration file from prerequisite (`src/mining_coordinator.zig` or equivalent)
   - call `db.indexMinedBlock(...)` immediately after canonical block commit.

## TDD Step Order (Tests First, Then Implementation)

Each step is atomic: one failing test, then one implementation change to make it pass.

### Phase A: Upstream Voltaire Type Surface

1. Write failing test for `RpcLog` JSON field names and hex encoding (`blockHash`, `blockTimestamp`, `removed`, topic array).
2. Implement `RpcLog.zig` and export it in `types.zig`.
3. Write failing test for `RpcReceipt` serialization (`sender` mapped to `from`, `status`/`root` exclusivity, `blobGas*` optional fields).
4. Implement `RpcReceipt.zig`.
5. Write failing test for `RpcTransaction` legacy and dynamic-fee serialization (`gasPrice` vs `maxFeePerGas`, `yParity`, pending nulls).
6. Implement `RpcTransaction.zig`.
7. Write failing test for `RpcBlock` hydrated and non-hydrated transaction projections, plus optional fork fields omission.
8. Implement `RpcBlock.zig`.
9. Write failing test for `eth_getLogs.FilterObject` parsing and validation of mutually-exclusive `blockHash` with `fromBlock/toBlock`.
10. Implement `FilterObject` in `eth_getLogs.zig`.
11. Write failing tests for each of six method `Result` wrappers to ensure JSON `null` on not-found.
12. Implement result-type updates in six method files.
13. Write failing tests for raw transaction decode helpers covering type 0/1/2/3/4.
14. Implement decode/hash helpers in `Transaction.zig` (or split helper file in voltaire if preferred).

### Phase B: ZEVM Database Indexes

15. Write failing `database_test.zig` test: `Database` initializes/deinitializes new query indexes without leaks.
16. Implement new index fields + init/deinit in `src/database/database.zig`.
17. Write failing test for `indexMinedBlock`: stores `receipts_by_tx_hash`, `receipts_by_block_hash`, `tx_index`, and rewrites placeholder `receipt.block_hash`.
18. Implement `indexMinedBlock(...)`.
19. Write failing test for duplicate tx hash behavior (replace vs reject) and define expected semantics.
20. Implement duplicate-handling logic and document behavior.

### Phase C: Shared Resolver and Conversion Helpers

21. Write failing tests for `resolveBlockNumber` (`latest`, `safe`, `finalized`, `pending`, `earliest`, hex number, missing hash).
22. Implement `resolveBlockNumber`.
23. Write failing tests for `resolveBlockHash` from `BlockSpec` number/hash/tag.
24. Implement `resolveBlockHash`.
25. Write failing tests for `toRpcLog` (topic/address matching, timestamp injection).
26. Implement `toRpcLog`.
27. Write failing tests for `toRpcReceipt`.
28. Implement `toRpcReceipt`.
29. Write failing tests for `toRpcTransaction` across transaction types.
30. Implement `toRpcTransaction`.
31. Write failing tests for `toRpcBlock`.
32. Implement `toRpcBlock`.

### Phase D: Handler-by-Handler

33. Write failing test `eth_getBlockByNumber` not-found returns `Result{ .block = null }`.
34. Implement minimal `eth_getBlockByNumber.handle`.
35. Write failing test `eth_getBlockByNumber` supports tag + hydration switch.
36. Extend `eth_getBlockByNumber.handle` with tag resolution + hydrated tx path.

37. Write failing test `eth_getBlockByHash` not-found returns null.
38. Implement `eth_getBlockByHash.handle`.

39. Write failing test `eth_getTransactionByHash` not-found returns null.
40. Implement `eth_getTransactionByHash.handle`.

41. Write failing test `eth_getTransactionReceipt` not-found returns null.
42. Implement `eth_getTransactionReceipt.handle`.

43. Write failing test `eth_getBlockReceipts` returns null for missing block and `[]` for existing empty block.
44. Implement `eth_getBlockReceipts.handle`.

45. Write failing test `eth_getLogs` for address/topic matching, OR-topic arrays, and wildcard positions.
46. Implement `eth_getLogs.handle` filtering loop.
47. Write failing test `eth_getLogs` invalid range scenarios (`fromBlock > toBlock`, future head range, `blockHash + range`).
48. Implement `eth_getLogs` validation and error mapping (`-32602` in dispatch layer).

### Phase E: Dispatch Integration

49. Write failing dispatcher test: six method tags resolve to handler entry points and serialize typed result objects.
50. Implement routing in `src/rpc_server.zig` (or equivalent dispatch file).
51. Write failing end-to-end JSON-RPC test covering one happy-path and one not-found for each of the six methods.
52. Implement remaining glue (error mapping / allocator ownership fixes).

### Phase F: Black-box Compatibility Tests

53. Add failing ZEVM fixture tests for execution-apis vectors:
   - `eth_getBlockByNumber/get-genesis.io`
   - `eth_getBlockByHash/get-block-by-hash.io`
   - `eth_getTransactionByHash/get-legacy-tx.io`
   - `eth_getTransactionReceipt/get-legacy-receipt.io`
   - `eth_getBlockReceipts/by-number.io`
   - `eth_getLogs/filter-with-blockHash-and-topics.io`
54. Implement fixture harness/adapters and field-normalization needed to pass these vectors.

## Tests To Write

## Unit Tests (Voltaire)

1. `RpcLog` serde tests for required/optional fields and EIP-1474 hex formatting.
2. `RpcReceipt` serde tests including pre-Byzantium `root` and post-Byzantium `status`.
3. `RpcTransaction` serde tests for legacy, EIP-2930, EIP-1559, EIP-4844, EIP-7702.
4. `RpcBlock` serde tests with hydrated transaction arrays and transaction-hash arrays.
5. `eth_getLogs.FilterObject` parse/validation tests.
6. Result wrapper tests for all six method files (null behavior).
7. Raw transaction decode/hash tests (if helper added).

## Unit Tests (ZEVM)

1. Database query index init/deinit.
2. Database block indexing hook correctness.
3. Block-spec resolution for all tag variants.
4. Conversion helper tests for block/tx/receipt/log mapping.
5. One test file per handler for null/happy/error behavior.
6. `eth_getLogs` topic semantics:
   - exact match
   - wildcard position
   - OR list per position
   - address single + address array

## Integration Tests (ZEVM)

1. Dispatcher route tests for all six method names.
2. JSON-RPC envelope tests for end-to-end method calls (single request + batch mix).
3. In-memory chain fixture test:
   - mine/store block
   - index block artifacts
   - assert all six handlers return consistent linked data.

## Black-box / Conformance Tests To Port

1. Selected `execution-apis/tests/*/*.io` vectors for each in-scope method.
2. Follow-up target: run the same subset through Hive rpc-compat once dispatch exists.

## Risks and Mitigations

1. Risk: Missing prerequisites (dispatch, blockchain field, commit hook) block handler reachability.
   - Mitigation: gate this ticket with explicit dependency check and merge order.

2. Risk: Voltaire currently lacks raw transaction decoding; `eth_getTransactionByHash` cannot hydrate typed txs from block body bytes.
   - Mitigation: add decode helper upstream first (Phase A).

3. Risk: Memory ownership bugs for dynamic arrays (`logs`, `topics`, `accessList`, `authorizationList`) can cause leaks/double-free.
   - Mitigation: explicit `deinit` tests for every new RPC type plus allocator leak checks.

4. Risk: Incorrect JSON field mapping (`sender` -> `from`, optional field omission vs null) causes execution-apis mismatch.
   - Mitigation: serialization golden tests per type and fixture-level assertions.

5. Risk: `eth_getLogs` range scans become expensive.
   - Mitigation: start with bounded range checks and enforce max range in handler validation.

6. Risk: Ambiguity around guillotine-mini RPC dispatch path in this workspace.
   - Mitigation: route in ZEVM dispatch layer; keep guillotine-mini untouched unless a missing upstream module is confirmed.

## Verification Against Acceptance Criteria

Acceptance criteria requires six handlers, voltaire jsonrpc types, dispatch integration, and spec-correct responses.

Verification checklist:

1. `zig build test` in `../voltaire` passes with new RPC type and method tests.
2. `zig build test` in `zevm` passes with all new handler and integration tests.
3. Each method proves not-found returns JSON `null` where required:
   - `eth_getBlockByNumber`
   - `eth_getBlockByHash`
   - `eth_getTransactionByHash`
   - `eth_getTransactionReceipt`
   - `eth_getBlockReceipts` (null for missing block).
4. `eth_getLogs` returns filtered log arrays and `-32602` for invalid filter combos/ranges.
5. Execution-apis fixture subset listed above passes in ZEVM test harness.
6. Dispatcher test confirms method-name routing uses voltaire method definitions and reaches each handler.

