# Agent A — tx_processor.zig

## What changed

Edited `src/tx_processor.zig` only.

- **Top-level CALL/CREATE bytecode wiring.** Before calling
  `evm.call(...)`, we now seed the EVM with the right bytecode:
  - For `tx.to != null` (CALL), fetch the recipient's deployed code via
    `sm.getCode(to)` and `evm.setBytecode(code)`. EOAs / non-existent accounts
    return an empty slice from the state manager, so EOA→EOA transfers and
    precompile calls keep their existing behavior. For an actual contract
    target, the EVM frame now executes the deployed bytecode instead of
    short-circuiting to "empty account success".
  - For `tx.to == null` (CREATE), set the bytecode to the init code so the
    top-level frame actually runs the constructor.
  Also wired `evm.origin = caller` and `evm.gas_price = effective_gas_price`
  so ORIGIN/GASPRICE opcodes and EIP-2929/3651 pre-warming see the right
  values.

- **Fork pinning.** Added `pub fn resolveHardfork(block_ctx) Hardfork` which
  currently returns `.CANCUN` regardless of input. The result is passed to
  `EvmType.init`, replacing the previous `null` (which made guillotine-mini
  default to `Hardfork.DEFAULT == PRAGUE`). The block_ctx parameter is
  retained on the helper so the chain_id/timestamp branching can be wired up
  later without touching callers.

- **EIP-1559 base-fee burn / coinbase tip-only.**
  - Validate `tx.gas_price >= block_ctx.block_base_fee` and return a new
    `TxError.GasPriceBelowBaseFee` otherwise.
  - Treat `effective_gas_price = tx.gas_price` for the legacy-only
    `ExecutionTx` shape we have today.
  - Sender debit is unchanged (`effective_gas_price * gas_used` via the
    upfront max charge plus refund).
  - Coinbase now only earns the priority tip:
    `(effective_gas_price - base_fee) * effective_gas_used`. The base fee is
    burned (no transfer). When `base_fee == 0` (pre-London or current default
    test fixtures) this collapses to the legacy "all fee → coinbase"
    behavior, so `gas accounting: sender pays gas, coinbase receives` still
    holds.
  - Skipped writing to coinbase if the priority tip is zero, to avoid
    unnecessary state churn.

- Defensive guard on `gas_consumed` when `result.gas_left > execution_gas`
  (shouldn't happen, but avoids a u64 underflow if a future EVM bug regresses
  this).

## Intentionally skipped

- **Typed transactions** (EIP-2930 / 1559 / 4844 / 7702). `ExecutionTx` only
  carries a `LegacyTransaction`; threading typed-fee fields requires changes
  in callers (block_builder, mining_coordinator, RPC submission), which are
  outside this agent's file scope. The base-fee burn logic is already shaped
  for type-2 — once a typed tx surfaces here, replace `effective_gas_price`
  with `min(maxFeePerGas, baseFee + maxPriorityFeePerGas)` and the rest of
  the math is correct.
- **EIP-3860 initcode word metering / size cap**, **EIP-3607
  sender-with-code rejection**, **EIP-2930 access-list intrinsic charging**,
  **EIP-4844 blob-gas accounting**, **logs bloom population**. All flagged in
  REVIEWS.md; out of scope per ticket.
- **No new tests** per task instructions.
- **No build run** per task instructions.

## Reviewer focus

- `resolveHardfork` is a placeholder that ignores `block_ctx`. It needs a
  proper mainnet activation table once we care about historical replay or
  multi-chain support. Today it is correct for any post-Cancun, pre-Prague
  scenario, which covers our local dev/hive targets but not historical
  fixtures.
- The new `TxError.GasPriceBelowBaseFee` is unhandled in
  `block_builder.zig:152-158`. It currently falls through to the
  inferred-error-union catch-all, which surfaces as a generic build/block
  failure rather than the cleaner `error.InvalidIncludedTransaction`. If
  block_builder's behavior matters, add `TxError.GasPriceBelowBaseFee` to
  that switch arm.
- `evm.origin` / `evm.gas_price` are public fields on `guillotine_mini.Evm`.
  We rely on those staying accessible. If guillotine-mini ever encapsulates
  them, switch to whatever setter API replaces them.
- `sm.getCode(to)` runs every call, including EOA→EOA. For a real fork
  backend this hits RPC for the target on every transfer. Cheap today
  (in-memory state), but when fork mode lands, consider gating with an
  "account has code" probe first, or relying on the EVM's existing host
  callbacks rather than pre-fetching.
- The reported "tx_processor tests are failing" framing in the ticket did
  not reproduce in `zig build test` against the current tree — the actual
  failures are in `block_builder_test` (gas-limit enforcement) and
  `mining_test` (blob base-fee fork fractions), neither of which this agent
  is allowed to touch. The bytecode-wiring fix here is still required for
  any contract call/create test that gets added later.
