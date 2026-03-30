# Context: ZEVM-001 - Create MiningConfig type and state management

> Archival snapshot note: this file is a point-in-time research artifact, not the active ZEVM contract. Workspace path checks, checkout gaps, and module/status statements below reflect capture-time conditions and may be stale.
> For current mining RPC return semantics and aliases, use `docs/specs/json-rpc-contract.md` sections 9.3 and 10. For current error semantics, use section 5.

## Ticket
- ID: `ZEVM-001`
- Category: `cat-6-mining`
- Goal: add `MiningConfig` state to ZEVM node/client runtime with TEVM-compatible shape:
  - `{ type: 'auto' }`
  - `{ type: 'manual' }`
  - `{ type: 'interval', blockTime: number }`

## Current ZEVM status
- `src/main.zig` is only a banner entrypoint.
- `src/root.zig` exports execution/light-client modules, but there is no node runtime struct yet.
- Execution integration exists (`src/tx_processor.zig`, `src/block_builder.zig`, `src/host_adapter.zig`, `src/database/database.zig`), but no mining mode state exists in ZEVM.

## Path mismatches discovered
- Requested: `../bench/guillotine-mini/client/rpc/` and `../bench/guillotine-mini/client/engine/`.
- In this workspace:
  - `../bench/guillotine-mini` does not exist.
  - `../guillotine-mini` exists, but `client/` is missing in checkout.
  - `../guillotine-mini/build.zig` still references:
    - `client/rpc/root.zig` (line around 296)
    - `client/engine/root.zig` (line around 319)
- Impact for ZEVM-001: mining config state can be implemented in ZEVM now, but RPC/engine wiring work depending on guillotine `client/*` cannot be completed from current checkout.

## Key references

### TEVM (primary shape reference)
- `../tevm-monorepo/packages/node/src/MiningConfig.ts`
  - Defines:
    - `ManualMining = { type: 'manual' }`
    - `AutoMining = { type: 'auto' }`
    - `IntervalMining = { type: 'interval', blockTime: number }`
  - `blockTime` is documented in seconds.
  - `blockTime: 0` means interval mode set but no periodic mining; manual mine calls still used.
- `../tevm-monorepo/packages/node/src/TevmNode.ts`
  - `miningConfig: MiningConfig` is mutable node state.
- `../tevm-monorepo/packages/node/src/createTevmNode.js`
  - Default is `miningConfig: { type: 'auto' }`.
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.js`
  - `true => { type: 'auto' }`, `false => { type: 'manual' }`.
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetIntervalMiningProcedure.js`
  - Sets `{ type: 'interval', blockTime: interval }`.
- `../tevm-monorepo/packages/actions/src/anvil/anvilGetAutomineProcedure.js`
  - Returns `miningConfig.type === 'auto'`.
- `../tevm-monorepo/packages/actions/src/anvil/anvilGetIntervalMiningProcedure.js`
  - Returns interval value when interval mode, else `0`.
- `../tevm-monorepo/packages/actions/src/eth/ethSendTransactionProcedure.js`
- `../tevm-monorepo/packages/actions/src/eth/ethSendRawTransactionProcedure.js`
  - Automining trigger is gated by `miningConfig.type === 'auto'`.

### Foundry Anvil (runtime mode behavior)
- `foundry/crates/anvil/src/eth/miner.rs`
  - `MiningMode::{None, Auto, FixedBlockTime, Mixed}`.
  - `is_auto_mine()` true only for `Auto`.
  - `get_interval()` exposes interval only for `FixedBlockTime`.
- `foundry/crates/anvil/src/eth/api.rs`
  - `anvil_set_auto_mine(bool)` toggles auto vs none.
  - `anvil_set_interval_mining(secs)` maps `0 => None`, `>0 => FixedBlockTime`.
  - `evm_mine` mines regardless of current mode.
- `foundry/crates/anvil/core/src/eth/mod.rs`
  - RPC alias mapping:
    - `anvil_mine` alias `hardhat_mine`
    - `anvil_setAutomine` alias `evm_setAutomine`
    - `anvil_setIntervalMining` alias `evm_setIntervalMining`

### Hardhat EDR (RPC contract and interval model)
- `edr/crates/edr_provider/src/requests/methods.rs`
  - `evm_mine` returns string `"0"`.
  - `evm_setAutomine` returns `true`.
  - `evm_setIntervalMining` accepts fixed-or-disabled or `[min, max]` range.
  - `hardhat_mine` params are `(number_of_blocks, interval_in_seconds)`.
  - `IntervalConfig` type:
    - `FixedOrDisabled(u64)`
    - `Range([u64; 2])`
- `edr/crates/edr_provider/src/config.rs`
  - `FixedOrDisabled(0) => None` (disabled).
  - Non-zero fixed => fixed interval.
  - Range validates `min <= max`.
- `edr/crates/edr_provider/src/requests/eth/evm.rs`
  - `handle_set_automine_request` flips provider auto-mining state.
- `edr/crates/edr_provider/src/requests/eth/mine.rs`
  - `handle_set_interval_mining` starts/stops interval miner task.
- `edr/crates/edr_provider/src/interval.rs`
  - interval miner loop mines on schedule (milliseconds-based delay generation).
- `edr/crates/edr_provider/src/data.rs`
  - Provider stores:
    - `mining_config`
    - `is_auto_mining`
  - `set_auto_mining()` updates auto-mining runtime gate.

### Hardhat integration
- `hardhat/v-next/hardhat-network-helpers/src/internal/network-helpers/helpers/mine.ts`
  - helper sends `hardhat_mine` with `(blocks, interval)` quantities.
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/edr/utils/convert-to-edr.ts`
  - `hardhatMiningIntervalToEdrMiningInterval`:
    - numeric `0 => undefined` (disabled)
    - numeric `>0 => BigInt(value)`
    - tuple => `{ min, max }`
- `hardhat/v-next/hardhat/src/internal/builtin-plugins/network-manager/edr/edr-provider.ts`
  - network mining config is passed into EDR provider state (`autoMine` + converted `interval`).

## Upstream libraries we own

### `../voltaire/packages/voltaire-zig/src/jsonrpc/`
- Covers eth/debug/engine namespaces (65 methods in module docs).
- No `evm_*`, `hardhat_*`, or `anvil_*` dev-node mining methods found.
- Relevant files:
  - `jsonrpc/root.zig`
  - `jsonrpc/eth/methods.zig`
  - `jsonrpc/debug/methods.zig`
  - `jsonrpc/engine/methods.zig`

### `../voltaire/packages/voltaire-zig/src/state-manager/`
- `StateManager.zig` provides:
  - checkpoint/revert/commit
  - snapshot/revertToSnapshot
  - fork-aware reads via `JournaledState` + optional `ForkBackend`
- This is reusable for mining/snapshot behavior integration; do not reimplement in ZEVM.

### `../voltaire/packages/voltaire-zig/src/blockchain/`
- `Blockchain.zig` + `BlockStore.zig` provide canonical storage and optional fork-cache read path.
- Useful for later mining integration where mined blocks must be committed and canonicalized.

### `../voltaire/packages/voltaire-zig/src/evm/`
- EVM core exists but no mining scheduler/mode state there.

### `../guillotine-mini` (actual available path)
- `src/root.zig` exports EVM/interpreter/host interfaces.
- No `client/rpc` or `client/engine` source tree present in this checkout.

## Spec constraints relevant to mining state decisions

### `docs/specs/`
- `docs/specs/prd.md` explicitly lists mining modes as ZEVM target:
  - automine
  - manual mining (`evm_mine`, `hardhat_mine`)
  - interval mining

### `execution-apis/`
- No dev mining RPC methods in official execution API docs.
- `execution-apis/src/engine/paris.md`:
  - `payloadAttributes.timestamp` must be greater than head block timestamp.
- Cancun/Prague/other engine docs preserve timestamp validity checks around payload building.

### `execution-specs/src/ethereum/`
- Example: `execution-specs/src/ethereum/forks/prague/fork.py`
  - `if header.timestamp <= parent_header.timestamp: raise InvalidBlock`
- Same monotonic timestamp rule appears across fork implementations.

### `consensus-specs/specs/`
- Bellatrix and later specs enforce execution payload timestamp == slot time.
- Example:
  - `consensus-specs/specs/bellatrix/p2p-interface.md`
  - `consensus-specs/specs/bellatrix/validator.md`

### `yellowpaper/`
- `yellowpaper/Paper.tex` defines timestamp rule:
  - `H_s > P(H)_s`

### `EIPs/EIPS/`
- No EIP defines Hardhat/Anvil dev mining RPC semantics.
- Relevant post-merge context:
  - `https://eips.ethereum.org/EIPS/eip-3675` (PoS transition constants/validity updates)
  - `https://eips.ethereum.org/EIPS/eip-4399` (`mixHash`/`prevRandao` semantics)

### `ethereum-tests/`
- No direct dev-node RPC mining suite found.
- Useful timestamp validity fixtures exist in invalid-block tests:
  - `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/bcInvalidHeaderTest/timeDiff0Filler.json`
  - `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/bcInvalidHeaderTest/badTimestampFiller.yml`
  - `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/bcEIP3675/timestampPerBlockFiller.yml`

### `execution-spec-tests/tests/`
- No direct dev-node mining RPC method suite found.
- Good source for protocol-level fork/timestamp invariants, but not RPC mining UX contracts.

### `hive/simulators/ethereum/`
- Useful for consensus/engine/rpc interoperability generally.
- No direct `evm_setAutomine`/`hardhat_mine` behavioral suite identified in this pass.

## Behavioral deltas to keep in mind
- TEVM and Foundry interval inputs are generally seconds-oriented.
- EDR `evm_setIntervalMining` accepts millisecond interval values (and ranges).
- Historical upstream reference: EDR `evm_mine` returns `"0"`; Foundry `evm_mine` returns `"0x0"`.
- Current ZEVM contract: `zevm_mine` and accepted aliases (`evm_mine`, `anvil_mine`, `hardhat_mine`) return `true` per `docs/specs/json-rpc-contract.md` section 9.3.
- TEVM `anvil_setAutomine` and `anvil_setIntervalMining` return `null` in those procedures.

## Recommended ZEVM-001 implementation shape (state only)
- Add a mining state type in ZEVM (`src/mining.zig` is appropriate):
  - `MiningConfigType` enum: `auto`, `manual`, `interval`
  - `MiningConfig` struct:
    - `type: MiningConfigType`
    - `block_time: ?u64` (or equivalent optional integer) for interval value
- Store `MiningConfig` on the main ZEVM node/client struct (must be introduced if absent).
- Default value: auto.
- Keep this ticket to state ownership only:
  - no background timer/miner loop
  - no RPC handlers yet

## Candidate tests to port later (black-box style)

### TEVM
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.spec.ts`
- `../tevm-monorepo/packages/actions/src/anvil/anvilSetIntervalMiningProcedure.spec.ts`
- `../tevm-monorepo/packages/actions/src/anvil/anvilGetAutomineProcedure.spec.ts`
- `../tevm-monorepo/packages/actions/src/anvil/anvilGetIntervalMiningProcedure.spec.ts`
- `../tevm-monorepo/packages/actions/src/eth/ethJsonRpcAutomining.spec.ts`

### Foundry
- `foundry/crates/anvil/tests/it/anvil.rs` (`test_can_change_mining_mode`)
- `foundry/crates/anvil/tests/it/anvil_api.rs` (`evm_mine_blk_with_same_timestamp`)

### Ethereum tests corpus
- `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/bcInvalidHeaderTest/timeDiff0Filler.json`
- `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/bcInvalidHeaderTest/badTimestampFiller.yml`
- `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/bcEIP3675/timestampPerBlockFiller.yml`

## Final takeaways
- ZEVM currently needs a node/client runtime state owner before mining config can be persisted.
- TEVM gives the exact shape requested by the ticket and should be mirrored.
- Foundry + EDR provide strong behavior contracts for later RPC wiring and mode transitions.
- Protocol specs consistently require strictly increasing block timestamps; interval/manual mining must preserve this when implemented.
