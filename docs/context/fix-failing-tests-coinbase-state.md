# Context: fix-failing-tests-coinbase-state

## Failing Tests (3 of 52)

1. **`tx_processor_test.test.process simple ETH transfer`** — `receipt.status.?.success` is false (line 79)
2. **`tx_processor_test.test.sequential transactions increment nonce`** — `r1.status.?.success` is false (line 276)
3. **`consensus_verifier_test.test.applyUpdate handles majority and non-majority correctly`** — `maybe_checkpoint` is null (line 279)

The database test mentioned in the build output is a **transitive failure** (the test runner reports it as the test binary that failed, not an individual test failure).

---

## Root Cause Analysis

### Tests 1 & 2: guillotine-mini `CallParams.validate()` rejects gas=0

**The bug is in guillotine-mini, NOT in the StateManager coinbase lookup.**

The debug output showing `"no fork backend, returning empty account"` for coinbase address `0xCB` is a red herring — returning an empty account (balance=0) for an uninitialized coinbase is correct behavior. The real problem is upstream in guillotine-mini.

#### Trace

1. Test creates a simple ETH transfer: `gas_limit=21000`, `gas_price=1`, `value=1000`
2. `tx_processor.zig:116` calculates `intrinsic = intrinsicGas(data, false) = 21_000`
3. `tx_processor.zig:133` calculates `execution_gas = tx.gas_limit - intrinsic = 0`
4. `tx_processor.zig:150-166` creates `CallParams{ .call = { .gas = 0, ... } }` and calls `evm.call(call_params)`
5. **BUG**: `guillotine-mini/src/call_params.zig:70` validates: `if (self.getGas() == 0) return ValidationError.GasZeroError`
6. `guillotine-mini/src/evm.zig:526` catches validation error → returns `makeFailure(allocator, 0)`
7. `result.success = false` → receipt status is failure

#### Why this is wrong

Per the Ethereum execution specs (`execution-specs/src/ethereum/forks/shanghai/fork.py:545`):
```python
gas = tx.gas - intrinsic_gas  # Can be 0
```

The Python EVM (`paris/vm/interpreter.py:254`) handles gas=0 correctly:
```python
while evm.running and evm.pc < ulen(evm.code):  # Empty code → loop doesn't execute
```

A simple ETH transfer to an EOA (no code) is perfectly valid with 0 execution gas. The EVM should succeed immediately since there's no code to execute.

The comment in `call_params.zig:68` even acknowledges this: `// BUG: we should be checking if gas checks are disabled or not`

#### Fix location

- **File**: `../guillotine-mini/src/call_params.zig:70`
- **Fix**: Remove or disable the `GasZeroError` check. The EVM already handles gas=0 correctly — for empty accounts it returns success immediately (`evm.zig:648-659`), and for accounts with code the execution loop naturally handles 0 gas.

### Test 3: voltaire `calcSyncPeriod` computes epoch instead of sync period

**The bug is in voltaire's `consensus.zig`.**

#### Trace

1. Test creates store with `finalized_header.beacon.slot = 64`
2. Calls `applyUpdate` with majority update having `finalized_header.beacon.slot = 96`
3. `consensus_verifier.zig:283` enters `applyUpdateNoQuorumCheck`
4. **BUG**: `consensus.zig:10` computes `calcSyncPeriod(slot) = slot / SLOTS_PER_EPOCH`:
   - `store_period = 64 / 32 = 2` (WRONG — should be 0)
   - `update_finalized_period = 96 / 32 = 3` (WRONG — should be 0)
5. `consensus_verifier.zig:325`: `update_finalized_period (3) != store_period (2)` → returns null

#### Why this is wrong

Per consensus-specs (`altair/validator.md:163` and `altair/light-client/sync-protocol.md:318-319`):
```python
def compute_sync_committee_period_at_slot(slot: Slot) -> uint64:
    return compute_sync_committee_period(compute_epoch_at_slot(slot))

def compute_sync_committee_period(epoch: Epoch) -> uint64:
    return epoch // EPOCHS_PER_SYNC_COMMITTEE_PERIOD  # EPOCHS_PER_SYNC_COMMITTEE_PERIOD = 256
```

Correct formula: `period = (slot / 32) / 256 = slot / 8192`

Current formula: `period = slot / 32` (this gives the epoch number, not the period!)

#### Fix location

- **File**: `../voltaire/packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig`
  - **Add**: `pub const EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256;`
- **File**: `../voltaire/packages/voltaire-zig/src/primitives/consensus/consensus.zig:9-11`
  - **Fix**: Change `calcSyncPeriod` to:
    ```zig
    pub fn calcSyncPeriod(slot: u64) u64 {
        const epoch = slot / ConsensusSpec.SLOTS_PER_EPOCH;
        return epoch / ConsensusSpec.EPOCHS_PER_SYNC_COMMITTEE_PERIOD;
    }
    ```

---

## Relevant Files

### zevm (this repo)
| File | Role |
|------|------|
| `src/tx_processor.zig` | Transaction processing — calls EVM with `execution_gas` that can be 0 |
| `src/tx_processor_test.zig` | Failing tests 1 & 2 |
| `src/consensus_verifier.zig` | Light client update logic — calls `calcSyncPeriod` |
| `src/consensus_verifier_test.zig` | Failing test 3 |
| `src/host_adapter.zig` | Bridges voltaire StateManager to guillotine-mini HostInterface |
| `src/block_builder.zig` | Block building (uses tx_processor) |

### voltaire (upstream — we own)
| File | Role |
|------|------|
| `packages/voltaire-zig/src/state-manager/StateManager.zig` | State access layer — `getBalance`/`setBalance` work correctly |
| `packages/voltaire-zig/src/state-manager/JournaledState.zig` | Read cascade: cache → fork → default empty account |
| `packages/voltaire-zig/src/state-manager/StateCache.zig` | `AccountState.init()` returns `{nonce:0, balance:0}` — correct |
| `packages/voltaire-zig/src/primitives/consensus/consensus.zig` | **BUG**: `calcSyncPeriod` computes epoch not period |
| `packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig` | Missing `EPOCHS_PER_SYNC_COMMITTEE_PERIOD` constant |

### guillotine-mini (upstream — we own)
| File | Role |
|------|------|
| `src/call_params.zig` | **BUG**: `validate()` rejects gas=0 with `GasZeroError` |
| `src/evm.zig` | EVM orchestrator — handles gas=0 correctly for empty accounts (line 648-659) but validate() blocks it |
| `src/host.zig` | HostInterface VTable definition |
| `src/call_result.zig` | CallResult type with `toOwnedResult` |

### Reference implementations
| File | Purpose |
|------|---------|
| `execution-specs/src/ethereum/forks/shanghai/fork.py:545` | Shows `gas = tx.gas - intrinsic_gas` (can be 0) |
| `execution-specs/src/ethereum/forks/paris/vm/interpreter.py:200-280` | Shows EVM handles gas=0 for empty accounts |
| `consensus-specs/specs/altair/validator.md:163` | `compute_sync_committee_period(epoch) = epoch // 256` |
| `consensus-specs/specs/altair/light-client/sync-protocol.md:318-319` | `compute_sync_committee_period_at_slot(slot)` formula |
| `consensus-specs/specs/altair/beacon-chain.md:125` | `EPOCHS_PER_SYNC_COMMITTEE_PERIOD = 256` |

---

## Implementation Plan

### Step 1: Fix guillotine-mini `CallParams.validate()` (upstream)

In `../guillotine-mini/src/call_params.zig`, remove the gas=0 rejection:

```zig
pub fn validate(self: @This()) ValidationError!void {
    // Gas=0 is valid for calls to EOAs (empty code) and simple transfers
    // where all gas is consumed by intrinsic costs.

    // EIP-3860: Limit init code size
    const MAX_INITCODE_SIZE = 49152;
    const MAX_INPUT_SIZE = 1024 * 1024 * 4;
    // ... rest of validation without the GasZeroError check
}
```

### Step 2: Fix voltaire `calcSyncPeriod` (upstream)

1. Add to `ConsensusSpec.zig`:
   ```zig
   pub const EPOCHS_PER_SYNC_COMMITTEE_PERIOD: u64 = 256;
   ```

2. Fix `consensus.zig`:
   ```zig
   pub fn calcSyncPeriod(slot: u64) u64 {
       const epoch = slot / ConsensusSpec.SLOTS_PER_EPOCH;
       return epoch / ConsensusSpec.EPOCHS_PER_SYNC_COMMITTEE_PERIOD;
   }
   ```

### Step 3: Remove debug prints from voltaire JournaledState

Remove the `std.debug.print("DEBUG: ...")` lines in `JournaledState.zig:80-104` that were added for debugging.

### Step 4: Verify

Run `zig build test` in zevm to confirm all 52 tests pass.

---

## Coinbase State Lookup — NOT the root cause

The original ticket hypothesized that JournaledState returning empty account for coinbase was the bug. **This is actually correct behavior:**

- In a dev node without a fork backend, uninitialized accounts return `AccountState.init()` (balance=0, nonce=0)
- `StateManager.getBalance(coinbase)` correctly returns 0
- `StateManager.setBalance(coinbase, 0 + gas_payment)` correctly creates the coinbase account
- This matches the Python reference: `coinbase_balance_after_mining_fee = get_account(state, coinbase).balance + U256(transaction_fee)` (`shanghai/fork.py:597-603`)

The coinbase account does NOT need pre-initialization. The problem was that the EVM call failed before reaching the coinbase payment code (line 192 of tx_processor.zig).
