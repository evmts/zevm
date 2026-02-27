# Context: add-mempool-to-voltaire

## Ticket Info
- Ticket ID: `add-mempool-to-voltaire`
- Category: `cat-4-eth-send`
- Title: Add Transaction Pool (Mempool) to voltaire upstream
- Goal: implement mempool in `../voltaire/packages/voltaire-zig/src/` (not in ZEVM) with:
  - support for Legacy, EIP-1559, EIP-2930, EIP-4844, EIP-7702 transactions
  - nonce-aware per-account ordering
  - gas-priority ordering for mining
  - API: `add_transaction()`, `remove_transaction()`, `get_pending()`, `get_ready()`, `clear()`
  - mining extraction helper (`ready_transactions()`/equivalent)

## Upstream-First Constraint
- ZEVM should stay a thin integration layer.
- If txpool behavior or types are missing, add them in `voltaire` (and if needed `guillotine-mini`), then wire ZEVM to upstream APIs.

## Required Path Coverage

### ZEVM docs/specs
- `docs/specs/prd.md`
  - Confirms mempool/tx sending is part of ZEVM scope and should be integrated rather than reimplemented ad hoc.

### Voltaire (primary implementation target)
- `../voltaire/packages/voltaire-zig/src/jsonrpc/`
  - Reviewed:
    - `eth/sendRawTransaction/eth_sendRawTransaction.zig`
    - `eth/sendTransaction/eth_sendTransaction.zig`
    - `eth/newPendingTransactionFilter/eth_newPendingTransactionFilter.zig`
  - Provides RPC type surfaces but no txpool implementation.
- `../voltaire/packages/voltaire-zig/src/state-manager/`
  - Reviewed `StateManager.zig`.
  - Provides account/nonce/balance/state access needed for readiness/admission checks.
- `../voltaire/packages/voltaire-zig/src/blockchain/`
  - Reviewed `Blockchain.zig`.
  - Provides canonical block/head storage hooks needed to update pool after mined blocks.
- `../voltaire/packages/voltaire-zig/src/evm/`
  - Used as execution reference boundary; no direct pool implementation found.
- Additional voltaire primitives used for requirements:
  - `../voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig`
  - `../voltaire/packages/voltaire-zig/src/primitives/FeeMarket/fee_market.zig`
  - `../voltaire/packages/voltaire-zig/src/primitives/PendingTransactionFilter/pending_transaction_filter.zig`

### Guillotine-mini references
- Requested paths:
  - `../bench/guillotine-mini/client/rpc/`
  - `../bench/guillotine-mini/client/engine/`
- Status: missing in this workspace (no `../bench` directory).
- Also checked `../guillotine-mini/` directly:
  - repository exists, but `client/rpc/` and `client/engine/` trees are not present in this checkout.
  - `build.zig` references `client/txpool/root.zig` and `client/engine/root.zig`; likely different branch/partial checkout mismatch.
- Action: treat guillotine-mini txpool behavior as unavailable for this ticket until path mismatch is resolved.

### Hardhat EDR
- `edr/crates/edr_provider/src/requests/`
  - Reviewed:
    - `eth/transactions.rs`
    - `hardhat/transactions.rs`
    - `methods.rs`
  - Useful behavior:
    - decode+validate submission path before adding tx
    - chain-id checks in `eth_sendRawTransaction`
    - drop transaction behavior (`hardhat_dropTransaction`)
    - pending tx query method coverage

### Foundry (Anvil reference)
- `foundry/`
  - Reviewed:
    - `crates/anvil/src/eth/pool/mod.rs`
    - `crates/anvil/src/eth/pool/transactions.rs`
    - `crates/anvil/src/eth/miner.rs`
    - `crates/anvil/src/eth/api.rs`
  - Core reference for ready-vs-pending model and replacement semantics.

### Hardhat repo
- `hardhat/`
  - Reviewed:
    - `v-next/hardhat/src/internal/builtin-plugins/network-manager/*`
    - `v-next/hardhat-network-helpers/test/network-helpers/drop-transaction.ts`
    - `v-next/hardhat/CHANGELOG.md`
  - Useful for mempool ordering modes (`priority` vs `fifo`) and black-box drop/pending behavior.

### TEVM monorepo
- `../tevm-monorepo/packages/actions/src/`
  - Reviewed:
    - `eth/ethSendRawTransactionHandler.js`
    - `eth/ethSendTransactionHandler.js`
    - `eth/ethSendRawTransactionProcedure.js`
    - `Mine/mineHandler.js`
    - `CreateTransaction/createTransaction.js`
  - Also reviewed tests:
    - `eth/ethSendRawTransaction.spec.ts`
    - `eth/ethSendTransactionHandler.spec.ts`
    - `CreateTransaction/createTransaction.spec.ts`
  - Provides trusted-dev-node send->pool->automine sequencing and test ideas.

### Execution APIs
- `execution-apis/`
  - Reviewed:
    - `src/eth/submit.yaml`
    - `tests/eth_sendRawTransaction/*`
  - Conformance vectors cover legacy/2930/1559/1559+access-list/blob tx forms.

### Execution specs
- `execution-specs/src/ethereum/`
  - Reviewed:
    - `forks/cancun/fork.py`
    - `forks/cancun/transactions.py`
    - `forks/prague/fork.py`
    - `forks/prague/transactions.py`
  - Admission/inclusion validity checks used as semantic baseline.

### Ethereum tests
- `ethereum-tests/`
  - Reviewed filler areas for transaction validity edge cases (RLP, gas/value bounds, tx type behavior).

### Execution spec tests
- `execution-spec-tests/tests/`
  - Reviewed:
    - `prague/eip7702_set_code_tx/test_invalid_tx.py`
    - `prague/eip7702_set_code_tx/test_set_code_txs.py`
    - `berlin/eip2930_access_list/test_tx_intrinsic_gas.py`
  - High-value negative vectors for 7702/2930 admission.

### EIPs
- `EIPs/EIPS/`
  - Reviewed:
    - `eip-155.md`, `eip-2718.md`, `eip-2930.md`, `eip-1559.md`, `eip-4844.md`, `eip-7702.md`
    - `eip-3607.md`, `eip-2681.md`, `eip-3860.md`, `eip-2.md`, `eip-7594.md`
  - Used to define tx validity and replacement constraints.

### Consensus specs
- `consensus-specs/specs/`
  - Reviewed validator/inclusion-list context and blob sidecar/data-availability path notes for relevance to pending tx handling.

### Yellowpaper
- `yellowpaper/`
  - Reviewed transaction validity and intrinsic gas constraints for baseline invariants.

### Hive
- `hive/simulators/ethereum/`
  - Reviewed engine/rpc compatibility docs and tests mentioning invalid tx behavior and pool visibility.

## Existing Implementation Status (Voltaire)
- No mempool/txpool module found in `../voltaire/packages/voltaire-zig/src`.
- Transaction models already support required envelope types and fee fields.
- JSON-RPC method types exist for send methods and pending filter hooks.
- State and blockchain components already exist to support:
  - sender nonce/balance/code checks
  - canonical head tracking
  - post-mining pool update hooks

## Behavioral Requirements from References

### 1) Admission checks before adding to pool
- Decode/typed transaction validation and sender recovery.
- Chain ID and signature validity (EIP-155, EIP-2 low-s).
- Sender must be EOA (EIP-3607).
- Nonce bounds (`< 2^64-1`, EIP-2681) and non-negative semantics.
- Intrinsic gas / initcode constraints (EIP-2930/1559, EIP-3860; Prague floor changes where applicable).
- Fee constraints by type:
  - legacy / 2930: `gas_price`
  - 1559 / 4844 / 7702: `max_fee_per_gas`, `max_priority_fee_per_gas`
  - 4844 additionally: blob fee cap and blob hash/wrapper checks.
- Type-specific constraints:
  - 4844: no create tx, blob fields required/valid.
  - 7702: non-empty authorization list and tuple validity.

### 2) Ready vs pending state
- Per-sender nonce sequencing is mandatory.
- A tx is ready when its nonce is exactly the next expected nonce for sender.
- Future nonces are pending and become ready when predecessors are mined/removed.
- Foundry marker pattern (`requires`/`provides`) is a strong model for dependency unlocking.

### 3) Global ordering for mining extraction
- `get_ready()` / `ready_transactions()` should return deterministic miner-facing order.
- Priority should be fee-based (effective gas price / dynamic fee aware), while respecting sender nonce ordering.
- Optionally preserve insertion order tie-breaker for stable determinism.

### 4) Replacement policy
- Same sender + nonce should trigger replacement path, not duplicate insert.
- Replacement must require fee bump:
  - gas-price bump for legacy-style pricing
  - both exec fee bump and blob fee bump for blob tx where applicable
  - EIP-4844 recommends ~10% bump for blob base fee component.
- Underpriced replacement should return a clear error and keep old tx.

### 5) Post-mine and removal behavior
- `remove_transaction()` should remove from ready/pending indexes and repair dependency graph.
- After block inclusion:
  - remove included txs
  - advance sender nonce frontier
  - promote newly unblocked pending txs to ready
- Reorg/fork handling should support reinsertion/revalidation strategy (can be follow-up if initial scope is single-head dev node).

## Proposed Voltaire API Shape (Minimal)
- `add_transaction(...) !Hash` (or transaction id) with validation + insertion + replacement handling.
- `remove_transaction(hash) bool` returns whether removed.
- `get_pending(...) []Transaction` (by sender and/or global view).
- `get_ready(...) []Transaction` (miner-facing ready set).
- `clear()` resets pool.
- `ready_transactions(...)` helper for mining pipeline (name can alias `get_ready`).

## Suggested Internal Data Model
- Primary index by hash for lookup/remove.
- Sender index keyed by address with nonce-ordered map.
- Ready structure as fee-priority queue constrained by nonce-frontier.
- Optional dependency markers (`requires`/`provides`) to simplify promotion logic.
- Keep metadata:
  - insertion id / timestamp (tie-breaker)
  - tx type + fee components
  - sender and nonce

## Integration Points for ZEVM (after upstream implementation)
- `eth_sendRawTransaction` / `eth_sendTransaction` should call voltaire txpool insert API.
- Automine path should pull from `get_ready()` and mine in returned order.
- Pending transaction filter (`eth_newPendingTransactionFilter`) should source from txpool events/contents.
- ZEVM should avoid own mempool logic beyond orchestration.

## Black-Box Tests to Port or Mirror
- Foundry txpool behavior:
  - replacement underpriced rejection
  - nonce-gap pending->ready promotion after predecessor mined
  - txpool content/status parity checks
- Hardhat/EDR:
  - drop-pending-tx behavior
  - invalid chain-id raw tx rejected and absent from pool
- Execution API vectors:
  - `execution-apis/tests/eth_sendRawTransaction/*` typed transaction acceptance/rejection.
- Execution-spec tests:
  - 7702 invalid authorization forms
  - 2930 intrinsic gas edge cases
- Hive scenarios:
  - invalid tx should not appear in included payload or pending pool.

## Open Gaps / Blockers
- `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/` were requested but are not present.
- `../guillotine-mini/client/` tree is also absent in this checkout despite references in `build.zig`.
- If guillotine-mini txpool behavior is required as canonical guidance, repository path/branch alignment must be fixed first.

## Implementation Guidance Summary
- Implement txpool fully in voltaire with sender-nonce correctness first, fee-priority second.
- Use EIP/execution-spec validity rules for admission so `eth_sendRawTransaction` can reject early.
- Keep ZEVM changes limited to calling upstream txpool APIs and mining ready transactions.
- Treat replacement and post-mine promotion as required MVP behavior, not optional polish.
