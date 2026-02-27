# Research Context: fix-failing-tx-processor-tests

## Failing Tests

### 1. `tx_processor_test.test.process simple ETH transfer` (line 79)
### 2. `tx_processor_test.test.sequential transactions increment nonce` (line 276)
### 3. `consensus_verifier_test.test.applyUpdate handles majority and non-majority correctly` (line 279)

---

## Root Cause Analysis

### tx_processor failures (tests 1 & 2)

**Root cause**: guillotine-mini's `CallParams.validate()` rejects `gas == 0` with `GasZeroError`.

**File**: `../guillotine-mini/src/call_params.zig` line 70:
```zig
if (self.getGas() == 0) return ValidationError.GasZeroError;
```

**How it happens**:
1. `tx_processor.processTransaction()` calculates `execution_gas = tx.gas_limit - intrinsicGas(...)` (line 133)
2. For a simple ETH transfer: `gas_limit=21_000`, `intrinsicGas=21_000` → `execution_gas = 0`
3. The EVM's `call()` method validates params at line 526, which calls `params.validate()`
4. `validate()` rejects gas=0 → `makeFailure()` returns `success=false`
5. `tx_processor` sees `result.success == false` and reverts

**Why this is wrong**: Per the Ethereum execution spec (e.g., `execution-specs/src/ethereum/forks/cancun/fork.py` line 735: `gas = tx.gas - intrinsic_gas`), a simple ETH transfer to an EOA with `gas_limit == intrinsic_gas` is perfectly valid — the EVM receives 0 execution gas, but since there's no code to execute, it succeeds immediately. The `GasZeroError` check is overly strict; it should only apply when there IS code to execute.

**Fix location**: `../guillotine-mini/src/call_params.zig` line 70 — Remove or relax the `gas == 0` validation. The comment on line 68 even acknowledges this: `// BUG: we should be checking if gas checks are disabled or not`.

**Alternative fix**: In `tx_processor.zig`, handle the zero-gas EOA case BEFORE routing through the EVM — detect that `execution_gas == 0 && tx.to != null && code.len == 0`, do the value transfer directly in the StateManager, and skip the EVM entirely. However, fixing it in guillotine-mini is better since EVM `call()` already handles `bytecode.len == 0` correctly (lines 648-659 return success), and the validate() check is the only blocker.

**Tests affected**: `process simple ETH transfer`, `sequential transactions increment nonce`, `gas accounting: sender pays gas, coinbase receives` (all use gas_limit=21_000 for simple transfers).

**Proof**: Adding debug print at `params.validate()` confirms: `"FAIL at params.validate"` is printed for all failing tests. The one passing test (`precompile call`) uses `gas_limit=25_000` → `execution_gas=4000 > 0`.

### consensus_verifier failure (test 3)

**Root cause**: voltaire's `calcSyncPeriod()` computes the epoch number, not the sync committee period.

**File**: `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig` line 9-11:
```zig
pub fn calcSyncPeriod(slot: u64) u64 {
    return slot / ConsensusSpec.SLOTS_PER_EPOCH; // Divides by 32 → gives epoch, NOT sync period
}
```

**Correct formula** (per `consensus-specs/specs/altair/validator.md` line 164):
```python
def compute_sync_committee_period(epoch):
    return epoch // EPOCHS_PER_SYNC_COMMITTEE_PERIOD  # 256 on mainnet
```
So `sync_period = slot / (SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD)` = `slot / (32 * 256)` = `slot / 8192`

**How it breaks the test**:
1. Store has `finalized_header.beacon.slot = 64` → `calcSyncPeriod(64) = 64/32 = 2`
2. Update has `finalized_header.beacon.slot = 96` → `calcSyncPeriod(96) = 96/32 = 3`
3. In `applyUpdateNoQuorumCheck` (line 324-327): `store.next_sync_committee_pubkeys == null` and `update_finalized_period (3) != store_period (2)` → **returns null**
4. Test expects `!= null` (line 279) → FAIL

**With correct formula**: `calcSyncPeriod(64) = 64/8192 = 0`, `calcSyncPeriod(96) = 96/8192 = 0` → same period → proceeds to update finalized header → slot 96 % 32 == 0 → returns `beaconHeaderRoot(...)` → not null ✓

**Fix location**: `../voltaire/packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig` — Add `EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256;`  
Then `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig` line 10 — Change to:
```zig
return slot / (ConsensusSpec.SLOTS_PER_EPOCH * ConsensusSpec.EPOCHS_PER_SYNC_COMMITTEE_PERIOD);
```

---

## Additional Issue: Debug prints in JournaledState

**File**: `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig` lines 80-103

The `getAccount` method has leftover `std.debug.print` statements that pollute test output with hundreds of lines of debug noise. These should be removed.

---

## Relevant Files

### zevm (test & implementation)
- `src/tx_processor.zig` — Transaction processing (the code under test)
- `src/tx_processor_test.zig` — Failing tests for tx_processor  
- `src/consensus_verifier.zig` — Consensus verification with applyUpdate
- `src/consensus_verifier_test.zig` — Failing test for consensus verifier
- `src/host_adapter.zig` — Bridges StateManager to EVM HostInterface
- `src/block_builder.zig` — Uses tx_processor for block building

### guillotine-mini (upstream — fix here)
- `src/call_params.zig` — **FIX**: Remove `GasZeroError` validation at line 70
- `src/evm.zig` — EVM `call()` method that routes through validate()
- `src/call_result.zig` — CallResult type with success/failure/toOwnedResult
- `src/host.zig` — HostInterface VTable definition
- `src/evm_config.zig` — Default config (PRAGUE hardfork, etc.)

### voltaire (upstream — fix here)
- `packages/voltaire-zig/src/primitives/consensus/consensus.zig` — **FIX**: `calcSyncPeriod` divides by epoch, not sync period
- `packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig` — **FIX**: Add `EPOCHS_PER_SYNC_COMMITTEE_PERIOD = 256`
- `packages/voltaire-zig/src/state-manager/JournaledState.zig` — **CLEANUP**: Remove debug prints
- `packages/voltaire-zig/src/state-manager/StateManager.zig` — StateManager wrapping JournaledState
- `packages/voltaire-zig/src/primitives/LightClientUpdate/LightClientUpdate.zig` — GenericUpdate, LightClientStore types

### Reference specs
- `execution-specs/src/ethereum/forks/cancun/fork.py` lines 713-735 — Shows `gas = tx.gas - intrinsic_gas` passed to EVM (can be 0)
- `consensus-specs/specs/altair/validator.md` line 164 — `compute_sync_committee_period(epoch) = epoch // EPOCHS_PER_SYNC_COMMITTEE_PERIOD`
- `consensus-specs/specs/altair/beacon-chain.md` line 125 — `EPOCHS_PER_SYNC_COMMITTEE_PERIOD = 256`
- `consensus-specs/presets/mainnet/altair.yaml` line 17 — `EPOCHS_PER_SYNC_COMMITTEE_PERIOD: 256`

---

## Fix Plan

### Fix 1: guillotine-mini `call_params.zig` — Remove gas==0 rejection
Remove or relax the `GasZeroError` check. The EVM already handles zero-gas calls correctly for EOAs (bytecode.len == 0 → immediate success at lines 648-659 of evm.zig). The validate() comment acknowledges this is a known issue.

### Fix 2: voltaire `ConsensusSpec.zig` + `consensus.zig` — Fix sync period calculation
1. Add `EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256` to ConsensusSpec
2. Change `calcSyncPeriod` to `slot / (SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD)`

### Fix 3: voltaire `JournaledState.zig` — Remove debug prints
Remove the ~10 `std.debug.print` calls from the `getAccount` method that pollute test output.

### Verification
Run `zig build test` in zevm — all 52 tests should pass (49 currently passing + 3 fixed).
