# Plan: Fix Failing Tests (Coinbase State & Consensus)

## Overview of the approach
The current 3 failing tests in `zevm` are caused by two separate upstream bugs, neither of which is actually an issue with the StateManager's coinbase account lookup.
1.  **`guillotine-mini`**: `CallParams.validate()` incorrectly rejects `gas=0` with `GasZeroError`. A simple ETH transfer with a `gas_limit` equal to the intrinsic gas leaves 0 execution gas, which is perfectly valid and should succeed immediately.
2.  **`voltaire`**: `calcSyncPeriod` computes the epoch number (`slot / 32`) instead of the sync committee period (`(slot / 32) / 256`).

The plan is to fix these upstream bugs using a TDD approach where we first add targeted tests in the upstream repositories to reproduce the isolated failures, then apply the fixes, and finally verify that the `zevm` integration tests pass.

## TDD Step Order (Tests before implementation)

### Step 1: Upstream fix in `guillotine-mini` (Gas Validation)
1.  **Test**: Add a unit test in `../guillotine-mini/src/call_params.zig` (or its corresponding test file) that constructs a `CallParams` with `gas=0` and asserts that `validate()` does *not* return an error.
2.  **Implementation**: Modify `CallParams.validate()` in `../guillotine-mini/src/call_params.zig` to remove or bypass the `if (self.getGas() == 0) return ValidationError.GasZeroError;` check.

### Step 2: Upstream fix in `voltaire` (Sync Period Calculation)
1.  **Test**: Add a unit test in `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig` (or its test file) that calls `calcSyncPeriod(8192)` and asserts the result is `1`, and `calcSyncPeriod(8191)` returns `0`.
2.  **Implementation**:
    *   Add `pub const EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256;` to `../voltaire/packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig`.
    *   Update the `calcSyncPeriod` function in `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig` to correctly divide the epoch by `EPOCHS_PER_SYNC_COMMITTEE_PERIOD`.

### Step 3: Upstream clean-up in `voltaire`
1.  **Implementation**: Remove the debug prints added during investigation in `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig` (around lines 80-104).

### Step 4: Downstream verification in `zevm`
1.  **Test (Integration)**: Run the existing failing tests in `zevm` (`tx_processor_test.zig` and `consensus_verifier_test.zig`) to ensure they now pass due to the upstream fixes.

## Files to Create/Modify

### Modify
*   `../guillotine-mini/src/call_params.zig`
    *   `pub fn validate(self: @This()) ValidationError!void`
*   `../voltaire/packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig`
    *   Add `pub const EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256;`
*   `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig`
    *   `pub fn calcSyncPeriod(slot: u64) u64`
*   `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig`
    *   Remove debug print statements.

## Tests to Write

### Unit Tests (Upstream)
*   **`guillotine-mini`**: A test verifying `CallParams` with `gas=0` passes validation.
*   **`voltaire`**: A test verifying `calcSyncPeriod` correctly calculates the period using the formula `(slot / 32) / 256`.

### Integration Tests
*   No new integration tests are strictly required, as the existing `zevm` tests (`tx_processor_test.zig` and `consensus_verifier_test.zig`) that currently fail will serve as our integration tests to verify the fixes.

## Risks and Mitigations
*   **Risk**: Allowing `gas=0` in `CallParams.validate()` might expose other areas of the EVM interpreter that incorrectly handle zero gas if they implicitly relied on this validation.
    *   **Mitigation**: Rely on the existing `guillotine-mini` test suite to catch any immediate regressions. The Python reference implementation confirms zero gas is valid and handled properly by empty execution loops.
*   **Risk**: Upstream changes might break other downstream projects relying on `voltaire` or `guillotine-mini`.
    *   **Mitigation**: The fixes align with the Ethereum specification (Execution and Consensus specs). Breaking downstream projects implies those projects were relying on incorrect behavior. Ensure all upstream tests pass before verifying `zevm`.

## How to Verify Against Acceptance Criteria
1.  All 52 tests in `zevm` must pass when running `zig build test`.
2.  The specific tests `tx_processor_test.test.process simple ETH transfer`, `tx_processor_test.test.sequential transactions increment nonce`, and `consensus_verifier_test.test.applyUpdate handles majority and non-majority correctly` should succeed without errors.