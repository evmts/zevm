# Context for implement-voltaire-txpool-core

## Ticket Description
Implement nonce/fee-ordered TxPool in Voltaire. Add `../voltaire/packages/voltaire-zig/src/txpool/TxPool.zig` and `root.zig`, export module in `../voltaire/build.zig`, and implement `add/getReady/removeMined/pendingCount` with sender-nonce ordering and replacement policy tests.

## Reference Paths Gathered

- **Docs & Specifications**:
  - `docs/specs/`: Central documentation for client specs.
  - `yellowpaper/`: Formal specifications for transaction validity, nonces, intrinsic gas, and signatures.
  - `execution-apis/`: The RPC specifications dictating expected inputs (e.g., `eth_sendRawTransaction`) and outputs.
  - `execution-specs/src/ethereum/`: Python reference implementation containing fork-specific transaction validity rules (e.g. EIP-1559 fee checking, EIP-2930 access lists).
  - `EIPs/EIPS/`: Critical EIPs that affect the pool, such as EIP-1559 (fee market), EIP-2718 (typed txs), EIP-4844 (blob txs replacement rules), and general replacement fee bump percentages (usually 10%).

- **Upstream Dependencies (Voltaire)**:
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/`: Defines JSON-RPC types and serializers. Ensures we don't duplicate types for `Transaction` objects.
  - `../voltaire/packages/voltaire-zig/src/state-manager/`: Needed to validate transactions against current account state (nonce must be `>=` state nonce, balance must cover `fee * gas_limit + value`).
  - `../voltaire/packages/voltaire-zig/src/blockchain/`: Supplies current base fee, block gas limit, and block numbers to evaluate tx feasibility.
  - `../voltaire/packages/voltaire-zig/src/evm/`: Reusing existing EVM logic for gas limit enforcements and signature recovery.

- **Client Routing**:
  - `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/`: Reference paths for how the `TxPool` will eventually hook into the actual incoming JSON-RPC dispatchers in the client.

- **Reference Implementations (for logic & edge cases)**:
  - `foundry/crates/anvil/src/eth/pool/mod.rs` & `transactions.rs`: Foundry's mempool code provides strong reference on separating "ready" vs "pending" queues, dropping underpriced transactions, ordering by nonce and fee, and tracking what transactions unlock subsequent nonces.
  - `edr/crates/edr_provider/src/requests/`: Shows how the Hardhat-style rust dev node manages local transaction submittal and ordering edge cases.
  - `../tevm-monorepo/packages/actions/src/`: Tevm's TypeScript node demonstrates transaction pool validation logic and custom dev node behaviors for dropping or replacing transactions.

- **Testing References**:
  - `ethereum-tests/` & `execution-spec-tests/tests/`: Can be referenced to ensure we respect official validation limits.
  - `hive/simulators/ethereum/`: Helpful to observe integration test requirements for RPC txpool behavior.

## Implementation Strategy
1. **Scaffold the Module**:
   - Create `../voltaire/packages/voltaire-zig/src/txpool/TxPool.zig`.
   - Create `../voltaire/packages/voltaire-zig/src/txpool/root.zig`.
   - Update `../voltaire/build.zig` to expose the new `txpool` module.
2. **Data Structures**:
   - Differentiate between `pending` (future nonces) and `ready` (executable) transactions.
   - Use Zig's `std.PriorityQueue` or `std.AutoHashMap` arrays combined with custom sorting functions to order transactions by `(sender, nonce)`.
   - Within the same nonce, order by fee/tip to manage replacements.
3. **Core APIs**:
   - `add`: Validates signature, intrinsic gas, nonce against state, balance against state, and inserts to pool. Returns success or standard RPC error types. Implements the 10% fee bump rule for same-nonce replacements.
   - `getReady`: Retrieves sorted, valid transactions up to block gas limit.
   - `removeMined`: Accepts an array of mined transaction hashes, removes them from the pool, and promotes newly unlocked `pending` transactions to `ready`.
   - `pendingCount`: Provides quick status queries.
4. **Zig Style Considerations**:
   - Strictly avoid local type aliases (no `const Foo = bar.Foo`).
   - Do not store allocators in structs; pass them into methods (e.g. `add(allocator: std.mem.Allocator, tx: Transaction)`).
   - Minimize nesting abstractions.
5. **Testing**: 
   - Add unit tests validating the replacement policy, nonce ordering, and promotion logic when previous nonces are mined.