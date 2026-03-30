# ZEVM-001: Create MiningConfig type and state management

## Overview of the approach
The objective of this ticket is to introduce `MiningConfig` state tracking into the ZEVM runtime, strictly mirroring the TEVM `MiningConfig` shape (`auto`, `manual`, and `interval` with an optional `blockTime`). Since ZEVM does not currently have a central node runtime or state struct (as evidenced by `main.zig` and `root.zig` structure), we will introduce a minimal `Node` struct (`ZevmNode`) to serve as the state owner for this configuration. 

The task will be performed using Test-Driven Development (TDD). We will define the required test cases for the structs first, ensuring they capture default modes and state changes.

## TDD step order (tests before implementation)

1. **Test 1 (`src/mining_test.zig`)**: Write unit tests asserting that the `MiningConfig` type exists, defaults to `auto`, and correctly holds a `blockTime` integer in `interval` mode.
2. **Implementation 1 (`src/mining.zig`)**: Create the `MiningConfigType` enum and `MiningConfig` tagged union to satisfy Test 1. Follow strict Zig style guidelines (no local type aliases, fully qualified paths).
3. **Test 2 (`src/node_test.zig`)**: Write unit tests asserting that a `ZevmNode` struct can be initialized with a default `MiningConfig` (`auto`), and that a setter function successfully updates the internal mining mode state.
4. **Implementation 2 (`src/node.zig`)**: Implement the `ZevmNode` struct, managing `MiningConfig` initialization and state mutations.
5. **Test 3 (Integration/Export tests)**: Update `src/root.zig` test block to include the new modules, ensuring they pass under `zig build test`.
6. **Implementation 3 (Wiring)**: Expose `mining.zig` and `node.zig` publicly in `src/root.zig`.

## Files to create/modify

### New Files

- **`src/mining.zig`**
  ```zig
  const std = @import("std");

  pub const MiningConfigType = enum {
      auto,
      manual,
      interval,
  };

  pub const MiningConfig = union(MiningConfigType) {
      auto: void,
      manual: void,
      interval: struct {
          block_time: u64,
      },

      pub fn default() MiningConfig;
  };
  ```

- **`src/mining_test.zig`**
  Unit tests covering default config behavior, mode creation, and payload extraction.

- **`src/node.zig`**
  ```zig
  const std = @import("std");
  const mining = @import("mining.zig");

  pub const ZevmNode = struct {
      mining_config: mining.MiningConfig,

      pub fn init() ZevmNode;
      pub fn setMiningConfig(self: *ZevmNode, config: mining.MiningConfig) void;
  };
  ```

- **`src/node_test.zig`**
  Unit tests validating state ownership and mutations inside `ZevmNode`.

### Modified Files

- **`src/root.zig`**
  ```zig
  pub const mining = @import("mining.zig");
  pub const node = @import("node.zig");

  test {
      // ... existing tests
      _ = @import("mining_test.zig");
      _ = @import("node_test.zig");
  }
  ```

## Tests to write

### Unit Tests
- `test "MiningConfig default is auto"`: Validates that calling `MiningConfig.default()` returns an `auto` variant.
- `test "MiningConfig interval holds block time"`: Validates creating an `interval` variant with `block_time: 15` and extracting the value safely.
- `test "ZevmNode initializes with default auto mode"`: Instantiates a `ZevmNode` and asserts its initial `mining_config` is `auto`.
- `test "ZevmNode updates mining config state"`: Instantiates a `ZevmNode` and asserts that `setMiningConfig` alters the configuration to `interval` or `manual` correctly.

### Integration Tests
- Verify that `zig build test` natively picks up the new module structures when bound through `src/root.zig`. No heavy EVM integration tests are needed at this stage since RPC and timer execution logic is explicitly deferred to later tickets.

## Risks and mitigations

- **Risk:** Zig tagged union complexities around empty payloads.
  - **Mitigation:** We explicitly use `void` for `auto` and `manual` variants to match Zig's tagged union syntax seamlessly, ensuring `blockTime` only occupies memory space when the `interval` tag is active.
- **Risk:** Over-engineering the `ZevmNode` struct prematurely.
  - **Mitigation:** Strict scope adherence. `ZevmNode` will only contain `MiningConfig` for now. Network bindings, DB integrations, and allocators will be layered in by subsequent architectural tickets to prevent scope creep.
- **Risk:** Handling `blockTime` value of `0` in `interval` mode (which TEVM maps to manual mining without a periodic trigger).
  - **Mitigation:** Ensure `u64` is used to allow `0`, with clear documentation defining `0` as "interval configuration without periodic execution".

## Verification against acceptance criteria
- **Does it track mining mode?** Yes, via the `MiningConfigType` enum and tagged union implementation.
- **Are auto, manual, and interval modes represented?** Yes, they match the TEVM structural requirements.
- **Is it stored in the main node/client struct?** Yes, `ZevmNode` encapsulates `MiningConfig`.
- **Is it test-driven?** Yes, the plan maps test definitions before structural implementations.
