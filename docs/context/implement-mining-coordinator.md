# Context: implement-mining-coordinator

## Ticket
- ID: `implement-mining-coordinator`
- Title: Implement `MiningCoordinator` with `MiningMode` state management
- Category: `cat-6-mining`
- Required ZEVM file: `src/mining_coordinator.zig`
- Required behavior:
  - `MiningMode` enum: `auto`, `manual`, `interval`
  - `MiningCoordinator` tracks mode state, pending tx pool, interval timer
  - methods: `init`, `deinit`, `setMode`, `submitTx`, `mineBlock`, `mineBlocks(count, interval)`, `setIntervalMining(seconds)`
  - integrate with existing `src/block_builder.zig`
- Primary reference requested by ticket:
  - `../voltaire/packages/voltaire-ts/src/provider/InMemoryProvider.ts` lines `136-206`, `316-365`

## Current ZEVM integration status
- `src/block_builder.zig` exists and already executes a list of `tx_processor.ExecutionTx` sequentially with:
  - invalid tx filtering (`NonceMismatch`, `IntrinsicGasExceedsLimit`, `InsufficientBalance` are dropped)
  - block gas limit enforcement
  - receipt generation + cumulative gas accounting
- `src/tx_processor.zig` exists and already handles nonce checks, intrinsic gas, EVM execution, state checkpoint/commit/revert, miner payment.
- There is no mining coordinator/state machine yet in `src/`.
- `src/root.zig` exports `block_builder`/`tx_processor` but no mining runtime module.

## Path verification and gaps
- Requested path `../bench/guillotine-mini/client/rpc/` is not present in this workspace.
- Requested path `../bench/guillotine-mini/client/engine/` is not present in this workspace.
- Actual repo found: `../guillotine-mini`.
- `../guillotine-mini/build.zig` still references `client/rpc/root.zig` and `client/engine/root.zig`, but those directories are missing in this checkout.
- Impact: for this ticket, mining coordinator research can proceed from ZEVM + TEVM/Foundry/EDR behavior; guillotine-mini RPC/engine wiring references are unavailable locally.

## Primary behavior references

### 1. Voltaire TS InMemoryProvider (ticket-mandated)
- File: `../voltaire/packages/voltaire-ts/src/provider/InMemoryProvider.ts`
- Relevant lines: `136-206`
  - provider stores `miningMode`, `miningInterval`, `miningIntervalId`, `pendingTransactions`
  - constructor defaults mode and interval, creates genesis block, starts interval miner if mode is `interval`
- Relevant lines: `316-365`
  - `startIntervalMining()` uses `setInterval(() => this.mine(), this.miningInterval)`
  - `stopIntervalMining()` clears timer and nulls handle
  - `mine()` consumes pending txs, clears transient storage, enforces monotonic timestamp (`max(now, current)` else `+1`)
- Additional dispatch behavior (`520-764`):
  - `eth_sendTransaction`: pushes tx to pending pool, immediately calls `mine()` only if mode is `auto`
  - `evm_mine`: mines one block regardless of mode
  - `evm_setAutomine`: `true => auto`, `false => manual`, always stop interval timer
  - `evm_setIntervalMining`: stop existing timer, `interval > 0 => interval mode + timer`, else `manual`

### 2. TEVM mining model and actions
- `../tevm-monorepo/packages/node/src/MiningConfig.ts`
  - shape: `{type:'auto'}` | `{type:'manual'}` | `{type:'interval', blockTime:number}`
  - `blockTime: 0` is explicitly documented as interval configured without periodic mining
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.js`
  - `true => {type:'auto'}`, `false => {type:'manual'}`
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetIntervalMiningProcedure.js`
  - always sets `{type:'interval', blockTime: interval}`
- `../tevm-monorepo/packages/actions/src/Call/handleAutomining.js`
  - automining delegates to `mineHandler` with `blockCount: 1`
- `../tevm-monorepo/packages/actions/src/Mine/mineHandler.js`
  - mines `blockCount` blocks
  - timestamp rule: first block uses `max(now, parent.timestamp)` unless override; subsequent blocks add interval
  - tx ordering uses txpool ordering (`txsByPriceAndNonce`)
  - commits block + receipts, prunes mined txs from pool
- TEVM tests:
  - `anvilSetAutomineProcedure.spec.ts`
  - `anvilSetIntervalMiningProcedure.spec.ts`
  - `anvilGetIntervalMiningProcedure.spec.ts`
  - `ethJsonRpcAutomining.spec.ts`

### 3. Foundry Anvil mining runtime
- `foundry/crates/anvil/src/eth/miner.rs`
  - `MiningMode::{None, Auto, FixedBlockTime, Mixed}`
  - `is_auto_mine()` true only for `Auto`
  - `get_interval()` exposes seconds only in `FixedBlockTime`
  - `set_mining_mode()` swaps mode and wakes miner loop
- `foundry/crates/anvil/src/eth/api.rs`
  - `anvil_set_auto_mine(bool)` toggles mode between auto and none
  - `anvil_set_interval_mining(secs)` maps `0 => None`, `>0 => FixedBlockTime`
  - `anvil_mine(num_blocks, interval)` mines loop; optional interval increases time between each mined block
  - `mine_one()` pulls ready txs from pool and mines exactly one block
- Foundry request mapping:
  - `foundry/crates/anvil/core/src/eth/mod.rs`
  - aliases include `anvil_mine <-> hardhat_mine`, `anvil_setAutomine <-> evm_setAutomine`, `anvil_setIntervalMining <-> evm_setIntervalMining`
- Foundry tests:
  - `foundry/crates/anvil/tests/it/anvil.rs` (`test_can_change_mining_mode`)
  - `foundry/crates/anvil/tests/it/anvil_api.rs` (`test_mine_first_block_with_interval`)

### 4. Hardhat EDR mining contract and scheduler
- Method contracts: `edr/crates/edr_provider/src/requests/methods.rs`
  - `evm_mine` returns string `"0"`
  - `evm_setAutomine` returns `true`
  - `evm_setIntervalMining` accepts milliseconds (`0`, fixed, or `[min,max]` range)
  - `hardhat_getAutomine` returns bool
  - `hardhat_mine(number_of_blocks?, interval_seconds?)` returns `true`
- Automine toggle: `edr/crates/edr_provider/src/requests/eth/evm.rs`
  - `handle_set_automine_request` calls `data.set_auto_mining(automine)`
- Interval miner start/stop: `edr/crates/edr_provider/src/requests/eth/mine.rs`
  - replaces `interval_miner` with new background worker or `None`
- Timer loop: `edr/crates/edr_provider/src/interval.rs`
  - generates delay, sleeps, then calls `data.interval_mine()`
- Provider runtime behavior: `edr/crates/edr_provider/src/data.rs`
  - `is_auto_mining`, `set_auto_mining`
  - `interval_mine()` mines + logs one block
  - `mine_and_commit_blocks(number_of_blocks, interval)`:
    - first block mined without interval offset
    - subsequent blocks use previous timestamp + interval
  - transaction submission path auto-mines pending txs until submitted tx is mined, then drains remaining pending txs

### 5. Hardhat helper and EDR config bridge
- `hardhat/v-next/hardhat-network-helpers/src/internal/network-helpers/helpers/mine.ts`
  - helper always sends `hardhat_mine` with `[blocksHex, intervalHex]`
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/edr/utils/convert-to-edr.ts`
  - `hardhatMiningIntervalToEdrMiningInterval` maps:
    - `0 => undefined` (disabled)
    - `>0 => bigint`
    - tuple => `{min,max}`
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/edr/edr-provider.ts`
  - network config passes `mining.auto` and converted `mining.interval` into EDR provider config

## Upstream dependencies (what exists and what does not)

### Voltaire Zig
- `../voltaire/packages/voltaire-zig/src/jsonrpc/`
  - contains `eth`, `engine`, `debug` namespaces
  - no `evm_*`, `anvil_*`, `hardhat_*` mining method definitions currently
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`
  - has checkpoint/revert/commit and snapshot APIs; reusable for mining integration
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` + `BlockStore.zig`
  - has `putBlock`, `setCanonicalHead`, canonical head lookup, orphan handling
- `../voltaire/packages/voltaire-zig/src/evm/`
  - execution core is present; no scheduler/mining-mode runtime abstraction

### Guillotine-mini
- Local checkout lacks `client/rpc` and `client/engine` trees requested by ticket context.
- Current actionable integration for this ticket remains ZEVM-side coordinator + existing `block_builder` pipeline.

## Protocol/spec constraints relevant to coordinator design

### docs/specs
- `docs/specs/prd.md` lists required ZEVM mining modes:
  - automine (default)
  - manual mining (`evm_mine`, `hardhat_mine`)
  - interval mining (timer-based)

### execution-apis
- No official `evm_setAutomine` / `evm_setIntervalMining` / `hardhat_mine` methods in execution API docs.
- `pending` block tag is defined as a client-constructed next block from local mempool.

### execution-specs
- `execution-specs/src/ethereum/forks/amsterdam/fork.py` (`369-410`)
  - header validation requires `header.timestamp > parent_header.timestamp`

### consensus specs
- `consensus-specs/specs/bellatrix/beacon-chain.md` (`393-394`)
- `consensus-specs/specs/deneb/beacon-chain.md` (`445-446`)
- `consensus-specs/specs/bellatrix/p2p-interface.md` (`107-109`)
  - execution payload timestamp must match slot time (`compute_time_at_slot`)

### yellowpaper
- `yellowpaper/Paper.tex` (`690-693`)
  - formal timestamp rule: `H_s > P(H)_s`

### EIPs / tests / hive
- `EIPs/EIPS/`: no dev-node mining RPC semantic definitions for `evm_setAutomine`/`hardhat_mine`/`anvil_setIntervalMining`.
- `execution-spec-tests/tests/`, `ethereum-tests/`, `hive/simulators/ethereum/`: no direct dev-node mining-mode RPC behavior suite; useful mainly for protocol correctness and interoperability.

## Implementation-relevant behavior synthesis for `MiningCoordinator`

### A. Core state machine
- Coordinator must own and expose a single authoritative mode:
  - `auto`: each accepted submitted tx should trigger immediate mining
  - `manual`: submitted txs are queued; only `mineBlock`/`mineBlocks` consume queue
  - `interval`: submitted txs are queued; background timer triggers periodic `mineBlock`
- On mode changes:
  - switching away from interval must cancel timer
  - switching to interval must (re)start timer if interval > 0

### B. Pending tx pool responsibilities
- Minimal queue semantics for this ticket:
  - append tx in arrival order
  - `mineBlock` should pass a tx slice to `block_builder.buildBlock`
  - mined/accepted txs must be removed from queue
  - txs skipped by block gas limit or invalidity should be handled deterministically
- Existing `block_builder.buildBlock` already filters invalid txs and gas-over-limit txs; coordinator should not reimplement those checks.

### C. Timestamp/interval behavior
- Protocol requirement: mined block timestamps must remain strictly increasing (`>` parent).
- `mineBlocks(count, interval)` should follow dev-node expectations from TEVM/Foundry/EDR:
  - block 1: use current monotonic timestamp rule
  - blocks 2..N: apply interval increment between timestamps
- `setIntervalMining(seconds)` ticket API says seconds.
- Unit mismatch across references:
  - TEVM/Foundry mostly seconds in public RPC UX
  - EDR `evm_setIntervalMining` accepts milliseconds/range
  - Voltaire TS `InMemoryProvider` timer currently uses raw interval argument directly in `setInterval`
- Recommendation for ZEVM coordinator: store interval in seconds in coordinator API, convert to timer duration when scheduling.

### D. Auto-mining trigger
- `submitTx` behavior should mirror TEVM/voltaire-ts:
  - `auto`: enqueue tx then mine immediately (single block), return result
  - `manual` / `interval`: enqueue only, defer mining

### E. Integration with `src/block_builder.zig`
- Coordinator should call:
  - `block_builder.buildBlock(allocator, sm, host_iface, txs, block_ctx)`
- Coordinator should own or receive enough context each call to provide:
  - `state_manager.StateManager`
  - `guillotine_mini.HostInterface`
  - `guillotine_mini.BlockContext`
  - tx queue slice (`[]const tx_processor.ExecutionTx`)
- After successful block build, coordinator should expose mined metadata needed by caller:
  - block number/timestamp
  - receipts/gas used from `BlockResult`
  - remaining pending queue length

## Known semantic divergences to resolve during implementation
- `setIntervalMining(0)` behavior differs across references:
  - Voltaire TS InMemoryProvider: switches to `manual`
  - Foundry: sets miner mode `None` (manual equivalent)
  - TEVM mining config often keeps `{type:'interval', blockTime:0}`
- Choose one ZEVM behavior up front and test it explicitly.
- Practical recommendation for this ticket shape:
  - keep explicit mode enum semantics simple (`interval` only when timer-enabled; `0` switches to manual)
  - or if TEVM-compat is required later, keep mode `interval` with disabled timer and document it.

## Candidate black-box tests to port/adapt for ZEVM
- TEVM:
  - `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.spec.ts`
  - `../tevm-monorepo/packages/actions/src/anvil/anvilSetIntervalMiningProcedure.spec.ts`
  - `../tevm-monorepo/packages/actions/src/eth/ethJsonRpcAutomining.spec.ts`
- Foundry:
  - `foundry/crates/anvil/tests/it/anvil.rs` (`test_can_change_mining_mode`)
  - `foundry/crates/anvil/tests/it/anvil_api.rs` (`test_mine_first_block_with_interval`)
- EDR behavior references:
  - `edr/crates/edr_provider/src/data.rs` interval mine and multi-block mine paths

## Minimal implementation checklist derived from research
- Add `src/mining_coordinator.zig` with:
  - `pub const MiningMode = enum { auto, manual, interval }`
  - coordinator struct fields: mode, pending tx container, interval config, timer handle/state
  - methods required by ticket
- Reuse existing ZEVM `tx_processor.ExecutionTx` and `block_builder.buildBlock`; do not reimplement execution logic.
- Preserve monotonic timestamp guarantees for all mining entry points.
- Add tests for:
  - `submitTx` in auto vs manual
  - timer enable/disable and mode transitions
  - `mineBlocks(count, interval)` timestamp spacing
  - pending pool drain behavior and invalid tx filtering passthrough from `block_builder`
