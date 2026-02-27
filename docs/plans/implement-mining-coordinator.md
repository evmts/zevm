# Implementation Plan: MiningCoordinator

## Overview
This plan details the implementation of the `MiningCoordinator` and `MiningMode` state management in ZEVM. The `MiningCoordinator` acts as the scheduling layer over the existing `block_builder` and `tx_processor`, managing the transaction pool and dictating when blocks are built according to the configured `MiningMode` (`auto`, `manual`, or `interval`). We strictly follow a Test-Driven Development (TDD) approach, writing unit and integration tests before the implementation.

## TDD Step Order

### Step 1: `MiningMode` and basic `MiningCoordinator` state tests
*   **Test:** Write unit tests for `MiningCoordinator.init` and `MiningCoordinator.deinit`, ensuring default state is correct.
*   **Test:** Write unit tests for `MiningCoordinator.setMode`, verifying mode transitions and timer invalidation when switching away from `interval`.
*   **Implementation:** Create `src/mining_coordinator.zig`, define the `MiningMode` enum, and implement `MiningCoordinator` struct with `init`, `deinit`, and `setMode` methods.

### Step 2: Transaction submission (`submitTx`) tests
*   **Test:** Write tests for `submitTx` in `manual` mode (tx should be queued, no block mined).
*   **Test:** Write tests for `submitTx` in `auto` mode (tx should be queued, and a block should be mined immediately).
*   **Implementation:** Implement the pending transaction pool (e.g., `std.ArrayList(tx_processor.ExecutionTx)`) and `submitTx` method. Wire it to call `mineBlock` internally if mode is `auto`.

### Step 3: Single block mining (`mineBlock`) tests
*   **Test:** Write tests for `mineBlock` to ensure it passes pending transactions to `block_builder.buildBlock`, clears the mined transactions from the pool, and handles monotonic timestamps correctly.
*   **Implementation:** Implement `mineBlock` method in `MiningCoordinator`. Integrate with `src/block_builder.zig` to execute transactions and produce a block.

### Step 4: Multi-block mining (`mineBlocks`) tests
*   **Test:** Write tests for `mineBlocks(count, interval)`, verifying that it mines `count` blocks.
*   **Test:** Verify that block timestamps increment by `interval` for subsequent blocks.
*   **Implementation:** Implement `mineBlocks` method, applying the correct timestamp logic for each block and calling the block builder iteratively.

### Step 5: Interval mining configuration (`setIntervalMining`) tests
*   **Test:** Write tests for `setIntervalMining(seconds)`, verifying that `seconds > 0` switches mode to `interval` and sets up the timer config, while `0` switches mode to `manual` (following Foundry/Voltaire-TS conventions).
*   **Implementation:** Implement `setIntervalMining(seconds)`. Manage the interval timer state.

## Files to Create/Modify

### Create: `src/mining_coordinator.zig`
*   `pub const MiningMode = enum { auto, manual, interval };`
*   `pub const MiningCoordinator = struct { ... }`
*   `pub fn init(allocator: std.mem.Allocator) !MiningCoordinator`
*   `pub fn deinit(self: *MiningCoordinator) void`
*   `pub fn setMode(self: *MiningCoordinator, mode: MiningMode) void`
*   `pub fn submitTx(self: *MiningCoordinator, tx: tx_processor.ExecutionTx) !void`
*   `pub fn mineBlock(self: *MiningCoordinator, ...) !BlockResult`
*   `pub fn mineBlocks(self: *MiningCoordinator, count: u64, interval: u64, ...) !void`
*   `pub fn setIntervalMining(self: *MiningCoordinator, seconds: u64) void`

### Modify: `src/root.zig`
*   Add `pub const mining_coordinator = @import("mining_coordinator.zig");`

## Tests to Write (Unit + Integration)

### Create: `src/mining_coordinator.zig` (Inline tests)
*   `test "MiningCoordinator init and deinit"`
*   `test "MiningCoordinator setMode transitions"`
*   `test "MiningCoordinator submitTx queues in manual mode"`
*   `test "MiningCoordinator submitTx mines immediately in auto mode"`
*   `test "MiningCoordinator mineBlock drains pending pool"`
*   `test "MiningCoordinator mineBlocks handles timestamp intervals"`
*   `test "MiningCoordinator setIntervalMining toggles modes"`

## Risks and Mitigations

*   **Risk:** `interval` mode requires a background timer, which might be complex depending on Zig's event loop/async setup in ZEVM.
    *   **Mitigation:** For this iteration, manage the timer state and expose a `tick()` method or rely on the host event loop to drive interval mining. The scope is primarily state management.
*   **Risk:** Memory leaks from unmanaged transaction queues.
    *   **Mitigation:** Ensure `deinit` properly frees the transaction pool. Use Zig's `std.testing.allocator` to catch leaks during tests.
*   **Risk:** Breaking existing `block_builder` assumptions.
    *   **Mitigation:** Do not modify `block_builder` directly unless necessary. Pass data to it exactly as `block_builder_test.zig` currently does.

## How to Verify Against Acceptance Criteria
*   Run `zig build test` to verify all TDD steps pass without memory leaks.
*   Ensure `MiningCoordinator` supports `auto`, `manual`, and `interval` modes.
*   Verify `submitTx` behaves correctly based on the active mode.
*   Verify `mineBlocks` creates the correct number of blocks with appropriate timestamp increments.
*   Verify the integration code uses fully qualified paths and explicit allocators (Zig Style guidelines).
