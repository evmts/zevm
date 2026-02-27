# Context: Integrate ForkBackend into Database Initialization

## Ticket Info
- **Ticket ID**: `integrate-forkbackend-database`
- **Category**: `cat-10-forking`
- **Title**: Wire up `ForkBackend` to `Database` initialization
- **Goal**: Refactor `src/database/database.zig` so `Database.init` accepts fork input (optional `*ForkBackend` or equivalent config) and passes it into `state_manager.StateManager.init` instead of hardcoding `null`. Update all test initializations to the new signature.

---

## Current ZEVM Implementation

### `src/database/database.zig`
- `Database.init(allocator)` currently does:
  - `state_manager.StateManager.init(allocator, null)`
  - so fork mode cannot be threaded into the database integration layer.
- `Database` currently stores:
  - `state: state_manager.StateManager`
  - `accounts`, `contracts`, `block_hashes`
- `syncCachedAccountsToTrie` calls `self.state.accountIterator()`.
  - In current upstream `voltaire` `StateManager`, `accountIterator` is not exposed.
  - This is not the ticket scope, but it is a known integration risk nearby.

### `src/database/database_test.zig`
- `Database.init(...)` is called **14** times.
- These are the only direct `Database.init` callsites in `src/`.
- Scope for test updates is tightly bounded to this file for this ticket.

### Other ZEVM usage
- `src/database/root.zig` only re-exports the database module.
- Other tests (`tx_processor_test`, `host_adapter_test`, `block_builder_test`) call `state_manager.StateManager.init(..., null)` directly and are not affected unless we choose to align them later.

---

## Project Spec Context

### `docs/specs/prd.md`
- Fork mode target explicitly says ZEVM should reuse:
  - `voltaire` `ForkBackend`
  - `StateManager` fork support
- This ticket is directly on that critical integration seam.

---

## Upstream `voltaire` References (Primary)

### State manager APIs

#### `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`
- `pub fn init(allocator: std.mem.Allocator, fork_backend: ?*ForkBackend.ForkBackend) !StateManager`
- This is exactly the constructor ZEVM `Database.init` should flow into.
- StateManager supports checkpoint/snapshot APIs above that fork-aware journaled state.

#### `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig`
- Read cascade:
  - local cache first
  - optional fork backend on miss
  - fallback default (zero/empty)
- Write behavior:
  - writes go to local cache only (fork is read-only)
- Important for ticket behavior:
  - passing `fork_backend != null` changes read semantics without changing write semantics.

#### `../voltaire/packages/voltaire-zig/src/state-manager/ForkBackend.zig`
- `ForkBackend.init(allocator, block_tag, CacheConfig)`
- Read APIs:
  - `fetchAccount`
  - `fetchStorage`
  - `fetchCode`
- Miss behavior:
  - queues pending request and returns `error.RpcPending`
- Bridge model:
  - `peekNextRequest` / `nextRequest`
  - `continueRequest(request_id, response_json)`
- Request payload format includes:
  - `eth_getProof` params
  - `eth_getCode` params
- Confirms fork backend lifecycle as an external object passed by pointer.

#### `../voltaire/packages/voltaire-zig/src/state-manager/c_api.zig`
- Explicit constructor split:
  - `state_manager_create()` (no fork)
  - `state_manager_create_with_fork(fork_backend_handle)`
- Confirms expected ownership pattern:
  - fork backend created separately and injected into state manager init.

#### `../voltaire/packages/voltaire-zig/src/state-manager/root.zig`
- Re-exports `ForkBackend`, `StateManager`, `JournaledState`.
- Confirms stable import surface for ZEVM integration.

### JSON-RPC method wrappers used by fork backend

#### `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getProof/eth_getProof.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getCode/eth_getCode.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getStorageAt/eth_getStorageAt.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBalance/eth_getBalance.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getTransactionCount/eth_getTransactionCount.zig`
- These define method names and params/results for fork reads.

#### `../voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockSpec.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockTag.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig`
#### `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig`
- Current wrappers are permissive/pass-through in places.
- Relevant implication:
  - ZEVM should not assume stronger validation in these wrappers yet.

### Related `voltaire` modules requested in ticket prompt

#### `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`
#### `../voltaire/packages/voltaire-zig/src/blockchain/root.zig`
- `Blockchain.init(allocator, fork_cache: ?*ForkBlockCache)` mirrors the same optional-pointer init pattern used by `StateManager`.
- Confirms consistency of upstream architecture: local + optional forked read backend.

#### `../voltaire/packages/voltaire-zig/src/evm/fork_state_manager.zig`
- Another reference for overlay-on-fork behavior:
  - local mutable overrides
  - remote reads on miss
- Reinforces intended fork semantics expected in ZEVM.

---

## `guillotine-mini` References

### Path mismatch in prompt
- Prompt path does not exist in this workspace:
  - `../bench/guillotine-mini/client/rpc/`
  - `../bench/guillotine-mini/client/engine/`
- `../guillotine-mini` exists, but does not have that exact layout.

### Fallback equivalent reviewed
#### `../gmini-review-zlI2Lu/client/rpc/dispatch.zig`
#### `../gmini-review-zlI2Lu/client/rpc/server.zig`
#### `../gmini-review-zlI2Lu/client/engine/api.zig`
- Useful for integration style:
  - method namespace resolution
  - strict JSON-RPC error mapping
  - engine error-code handling
- Not directly changing this ticket, but confirms expected dispatch and RPC boundary patterns around fork-aware data sources.

---

## EDR / Hardhat EDR References

### Request handlers
#### `edr/crates/edr_provider/src/requests/hardhat/config.rs`
#### `edr/crates/edr_provider/src/requests/hardhat/state.rs`
#### `edr/crates/edr_provider/src/requests/hardhat/rpc_types/metadata.rs`
- `hardhat_metadata` includes `forked_network` when forking is enabled.
- State mutation handlers are thin wrappers over provider data methods.

### Forked initialization lifecycle (most relevant)
#### `edr/crates/edr_provider/src/config.rs`
#### `edr/crates/edr_provider/src/data.rs` (`create_forked_blockchain_and_state`, `ProviderData::new`)
- `ProviderConfig` contains optional `fork`.
- Construction splits clearly:
  - if fork config exists: create forked blockchain+state
  - else: create local blockchain+state
- Fork metadata captured at creation:
  - remote chain id
  - fork block number
  - fork block hash
- Strong reference pattern for this ticket:
  - build fork backend/config first
  - pass fork-aware state object at initialization boundary (not ad-hoc later).

---

## Foundry / Anvil References

### Core files reviewed
#### `foundry/crates/anvil/src/config.rs`
#### `foundry/crates/anvil/src/eth/api.rs`
#### `foundry/crates/anvil/src/eth/backend/fork.rs`
#### `foundry/crates/anvil/src/eth/backend/mem/fork_db.rs`

### Relevant patterns
- Config holds optional fork inputs:
  - `eth_rpc_url`
  - `fork_choice` / block selection
  - retry/timeouts/headers
- Setup split:
  - `setup()` chooses in-memory vs `setup_fork_db(...)`.
- Runtime reset semantics:
  - `anvil_reset` can reset forked backend or reset to fresh in-memory backend.
- `ClientFork.reset(...)` updates fork metadata and clears caches.
- This strongly supports passing optional fork dependency at init boundary instead of implicit globals.

---

## TEVM References

### Files reviewed
#### `../tevm-monorepo/packages/actions/src/internal/forkAndCacheBlock.js`
#### `../tevm-monorepo/packages/actions/src/anvil/anvilResetProcedure.js`
#### `../tevm-monorepo/packages/actions/src/anvil/anvilResetProcedure.spec.ts`

### Relevant behavior
- TEVM reconstructs state manager + blockchain with fork transport/block tag.
- Then swaps the VM to the new fork-configured components.
- Reset tests assert canonical head returns to forked block on reset.
- Confirms practical dev-node expectation: fork context is an initialization concern and resettable as a unit.

---

## Execution API / Spec References

### OpenRPC method schema
#### `execution-apis/src/eth/state.yaml`
#### `execution-apis/src/eth/block.yaml`
#### `execution-apis/src/schemas/block.yaml`
- `eth_getBalance`, `eth_getStorageAt`, `eth_getCode`, `eth_getTransactionCount`, `eth_getProof`
  all use block selector inputs relevant to forking.
- `BlockTag` includes:
  - `earliest`, `latest`, `pending`, `safe`, `finalized`
- `BlockNumberOrTagOrHash` formalizes accepted selector forms.

### JSON-RPC conformance vectors
#### `execution-apis/tests/eth_getProof/get-account-proof-latest.io`
#### `execution-apis/tests/eth_getProof/get-account-proof-blockhash.io`
#### `execution-apis/tests/eth_getProof/get-account-proof-with-storage.io`
#### `execution-apis/tests/eth_getStorageAt/get-storage.io`
#### `execution-apis/tests/eth_getCode/get-code.io`
#### `execution-apis/tests/eth_getBlockByNumber/get-latest.io`
#### `execution-apis/tests/eth_getBlockByNumber/get-safe.io`
#### `execution-apis/tests/eth_getBlockByNumber/get-finalized.io`
- Confirms practical selector/tag behavior expected by conformance fixtures.

### Execution spec Python reference
#### `execution-specs/src/ethereum/state.py`
#### `execution-specs/src/ethereum/forks/prague/state.py`
#### `execution-specs/src/ethereum/forks/prague/trie.py`
#### `execution-specs/src/ethereum/forks/prague/fork.py`
- Reinforces canonical state/trie model:
  - account + storage tries
  - state root from trie content
  - transaction-scoped snapshot/rollback behavior.

### Execution-spec-tests
#### `execution-spec-tests/tests/` (directory scan)
- No immediate RPC-fork wiring tests directly tied to this constructor change.
- Useful future source for black-box behavior parity but not a direct dependency for this ticket.

---

## EIP / Consensus / Yellow Paper / Hive References

### EIPs
#### `EIPs/EIPS/eip-1186.md`
- Defines `eth_getProof` semantics and return payload shape.

#### `EIPs/EIPS/eip-1474.md`
- Defines JSON-RPC error code expectations and quantity/data encoding rules.

#### `EIPs/EIPS/eip-1898.md`
- Defines block selector object with `blockHash` / `blockNumber` and optional `requireCanonical`.
- Relevant to fork reads pinned to non-canonical or explicit block hashes.

### Consensus specs
#### `consensus-specs/specs/phase0/fork-choice.md`
#### `consensus-specs/specs/bellatrix/fork-choice.md`
#### `consensus-specs/fork_choice/safe-block.md`
- Clarifies safe/finalized concepts and `safe_block_hash` signaling into execution engine flow.
- Useful context for block tag interpretation (`safe`, `finalized`) in fork-aware read paths.

### Yellow Paper
#### `yellowpaper/Paper.tex`
- Source-of-truth model context:
  - world state as address -> account state mapping
  - account fields include nonce, balance, storageRoot, codeHash
  - block header stores `stateRoot`
  - trie-based identity and proof model.

### Hive
#### `hive/simulators/ethereum/rpc-compat/README.md`
#### `hive/simulators/ethereum/rpc-compat/main.go`
- RPC-compat simulator runs execution-apis tests against clients as black boxes.
- Strong signal for regression strategy after future fork-mode RPC work.
- Note: local `tests/forkenv.json` is not present in this checkout path (loaded at runtime/build setup).

### Ethereum tests corpus
#### `ethereum-tests/` (directory scan)
- Broad EVM/state/blockchain corpus; not directly targeted at this constructor plumbing change.
- Still relevant for future fork-mode integration validation depth.

---

## Implementation Implications for This Ticket

## 1) Preferred shape of `Database.init`
- Current:
  - `pub fn init(allocator: std.mem.Allocator) !Database`
- Target options:
  - `pub fn init(allocator: std.mem.Allocator, fork_backend: ?*state_manager.ForkBackend) !Database`
  - or a fork config form that still ultimately passes optional pointer into `StateManager.init`.
- The minimal, direct change is passing optional backend pointer through.

## 2) Constructor wiring rule
- Replace:
  - `state_manager.StateManager.init(allocator, null)`
- With:
  - `state_manager.StateManager.init(allocator, fork_backend)`

## 3) Test updates
- Update all 14 `Database.init(std.testing.allocator)` calls in:
  - `src/database/database_test.zig`
- Likely pass explicit `null` for non-fork tests to keep intent clear.

## 4) Ownership/lifetime considerations
- Upstream pattern implies fork backend is externally owned and passed as pointer.
- Ensure `Database.deinit` does not attempt to deinit externally owned fork backend unless ownership contract is explicitly changed.

## 5) Zig style constraints to preserve
- No local type aliases.
- No stored allocators in new ZEVM code paths.
- Keep abstraction minimal and inline where straightforward.

---

## Risks / Notes
- `Database.syncCachedAccountsToTrie` currently depends on `StateManager.accountIterator()`, which upstream `voltaire` does not expose.
  - Not part of this ticket, but this area may fail once integration code is exercised more deeply.
- Fork backend methods can return `error.RpcPending` on cache miss.
  - This ticket is constructor plumbing only, but downstream callsites may need explicit handling when fork mode becomes active end-to-end.

---

## Suggested Implementation Checklist
- Change `Database.init` signature to accept optional fork input.
- Thread the optional fork input into `StateManager.init`.
- Update all `database_test.zig` init calls to new signature.
- Run `zig build test`.
- If failures surface around `accountIterator` or pending RPC semantics, split into follow-up ticket(s).

