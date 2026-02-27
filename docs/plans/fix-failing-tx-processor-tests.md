# Plan: fix-failing-tx-processor-tests

## Overview

Three tests are failing due to bugs in upstream dependencies (which we own):

1. **`tx_processor_test.test.process simple ETH transfer`** — guillotine-mini `call_params.zig` rejects `gas==0` with `GasZeroError`, but a simple ETH transfer with `gas_limit=21000` has `execution_gas=0` after intrinsic deduction, which is valid per Ethereum spec.
2. **`tx_processor_test.test.sequential transactions increment nonce`** — Same root cause as #1.
3. **`consensus_verifier_test.test.applyUpdate handles majority and non-majority correctly`** — voltaire `calcSyncPeriod()` divides by `SLOTS_PER_EPOCH` (32) instead of `SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD` (8192), computing epoch instead of sync period.

Additionally, voltaire `JournaledState.zig` has leftover debug prints polluting test output.

All fixes are in upstream deps we own — no zevm code changes needed.

---

## TDD Step Order

### Step 1: Add test for zero-gas CALL in guillotine-mini

**File**: `../guillotine-mini/src/call_params.zig`  
**Action**: Add test at end of file

Add a test that validates `gas==0` is accepted by `validate()` for CALL params. This test will FAIL initially because of the `GasZeroError` check on line 70.

```zig
test "validate allows zero gas for call" {
    const CP = CallParams(.{});
    const params: CP = .{ .call = .{
        .caller = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
        .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
        .value = 1000,
        .input = &[_]u8{},
        .gas = 0,
    } };
    // Per Ethereum spec, gas=0 is valid for EOA transfers (no code to execute)
    try params.validate();
}
```

### Step 2: Fix guillotine-mini `call_params.validate()` — remove GasZeroError

**File**: `../guillotine-mini/src/call_params.zig` line 67-70  
**Action**: Remove the `gas == 0` rejection

Remove lines 68-70:
```zig
// BUG: we should be checking if gas checks are disabled or not
// Gas must be non-zero to execute any operation
if (self.getGas() == 0) return ValidationError.GasZeroError;
```

**Rationale**: The EVM already handles zero-gas calls correctly:
- For EOAs (no bytecode): lines 648-659 of `evm.zig` return success immediately
- For precompiles: handled before bytecode check
- The `GasZeroError` check is overly strict and blocks valid Ethereum transactions

**Risk**: The `GasZeroError` variant remains in `ValidationError` enum and `errors.zig`. We should also remove it from the enum to keep the API clean, but only if nothing else references it.

**Verify**: `grep -r GasZeroError ../guillotine-mini/src/` — only `call_params.zig` and `errors.zig` reference it. Safe to remove from both.

### Step 3: Remove `GasZeroError` from `errors.zig`

**File**: `../guillotine-mini/src/errors.zig` line 33  
**Action**: Remove `GasZeroError` from `CallError` enum

### Step 4: Verify tx_processor tests pass

**Command**: `cd /Users/williamcory/zevm && zig build test`  
**Expected**: `process simple ETH transfer` and `sequential transactions increment nonce` now pass.

---

### Step 5: Add test for `calcSyncPeriod` in voltaire

**File**: `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig`  
**Action**: Add test at end of file

```zig
test "calcSyncPeriod computes sync committee period not epoch" {
    // Per consensus-specs: sync_period = slot / (SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD)
    // = slot / (32 * 256) = slot / 8192
    try std.testing.expectEqual(@as(u64, 0), calcSyncPeriod(0));
    try std.testing.expectEqual(@as(u64, 0), calcSyncPeriod(64));
    try std.testing.expectEqual(@as(u64, 0), calcSyncPeriod(96));
    try std.testing.expectEqual(@as(u64, 0), calcSyncPeriod(8191));
    try std.testing.expectEqual(@as(u64, 1), calcSyncPeriod(8192));
    try std.testing.expectEqual(@as(u64, 1), calcSyncPeriod(16383));
    try std.testing.expectEqual(@as(u64, 2), calcSyncPeriod(16384));
}
```

This test will FAIL with the current implementation (`slot / 32` gives epoch, not sync period).

### Step 6: Add `EPOCHS_PER_SYNC_COMMITTEE_PERIOD` to ConsensusSpec

**File**: `../voltaire/packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig`  
**Action**: Add constant

```zig
/// Number of epochs per sync committee period (mainnet preset)
/// https://github.com/ethereum/consensus-specs/blob/dev/presets/mainnet/altair.yaml#L17
pub const EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256;
```

### Step 7: Fix `calcSyncPeriod` in consensus.zig

**File**: `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig` line 9-11  
**Action**: Change divisor from `SLOTS_PER_EPOCH` to `SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD`

```zig
pub fn calcSyncPeriod(slot: u64) u64 {
    return slot / (ConsensusSpec.SLOTS_PER_EPOCH * ConsensusSpec.EPOCHS_PER_SYNC_COMMITTEE_PERIOD);
}
```

### Step 8: Verify consensus_verifier test passes

**Command**: `cd /Users/williamcory/zevm && zig build test`  
**Expected**: `applyUpdate handles majority and non-majority correctly` now passes because:
- `calcSyncPeriod(64) = 0` and `calcSyncPeriod(96) = 0` → same period
- `next_sync_committee_pubkeys == null` and periods match → proceeds to set next committee
- Updates finalized header to slot 96, optimistic to slot 100
- Returns `beaconHeaderRoot(...)` (not null) ✓

---

### Step 9: Remove debug prints from JournaledState

**File**: `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig` lines 80-103  
**Action**: Remove all `std.debug.print(...)` calls from `getAccount` method

The method should become:
```zig
pub fn getAccount(self: *JournaledState, address: Address) !StateCache.AccountState {
    if (self.account_cache.get(address)) |account| {
        return account;
    }
    if (self.fork_backend) |fork| {
        const account = try fork.fetchAccount(address);
        try self.account_cache.put(address, account);
        return account;
    }
    return StateCache.AccountState.init();
}
```

### Step 10: Final verification

**Command**: `cd /Users/williamcory/zevm && zig build test`  
**Expected**: All tests pass (49 previously passing + 3 fixed = 52 total), no debug noise in output.

---

## Files to Modify

| File | Action | Repo |
|------|--------|------|
| `../guillotine-mini/src/call_params.zig` | Remove `GasZeroError` check (line 70), add test | guillotine-mini |
| `../guillotine-mini/src/errors.zig` | Remove `GasZeroError` from `CallError` enum | guillotine-mini |
| `../voltaire/.../ConsensusSpec.zig` | Add `EPOCHS_PER_SYNC_COMMITTEE_PERIOD = 256` | voltaire |
| `../voltaire/.../consensus/consensus.zig` | Fix `calcSyncPeriod` divisor, add test | voltaire |
| `../voltaire/.../JournaledState.zig` | Remove debug prints from `getAccount` | voltaire |

**No zevm files modified** — all fixes are upstream.

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Removing `GasZeroError` breaks other guillotine-mini consumers | Low | Grep confirms only `call_params.zig` and `errors.zig` use it. No external tests reference it. |
| `calcSyncPeriod` fix breaks other callers | Low | Only used in zevm's `consensus_verifier.zig`. The current behavior is wrong per spec. |
| Removing debug prints hides real bugs | None | These are leftover dev prints, not structured logging. They pollute test output with hundreds of lines. |
| `GasZeroError` removal allows invalid CREATE with gas=0 | Low | CREATE with gas=0 will fail naturally during code execution (can't store contract without gas). The EVM handles this correctly already. |

## Acceptance Criteria Verification

- [x] `tx_processor_test.test.process simple ETH transfer` passes → Fixed by removing `GasZeroError` (Steps 1-2)
- [x] `tx_processor_test.test.sequential transactions increment nonce` passes → Same fix (Steps 1-2)
- [x] `consensus_verifier_test.test.applyUpdate handles majority and non-majority correctly` passes → Fixed by correcting `calcSyncPeriod` (Steps 5-7)
- [x] All 52 tests pass with `zig build test`
- [x] No debug print noise in test output
