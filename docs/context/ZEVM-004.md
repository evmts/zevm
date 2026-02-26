# Context: ZEVM-004 - Implement evm_setAutomine RPC handler

## Ticket
- ID: `ZEVM-004`
- Category: `cat-6-mining`
- Goal: Implement `evm_setAutomine(enabled: boolean) -> null` RPC method
  - Enables/disables automine mode
  - When enabled, each transaction submission should automatically trigger block mining
  - Requires integration with transaction submission pipeline

## Method Signature
```
evm_setAutomine(enabled: boolean) -> null
```

## Current ZEVM Status
- `src/main.zig` is a simple entrypoint
- `src/root.zig` exports execution/light-client modules
- No node runtime struct with mining state yet (ZEVM-001 adds MiningConfig)
- No RPC handlers implemented yet
- HTTP JSON-RPC server is listed as needed in PRD (section 1)

## Reference Implementations

### TEVM (TypeScript) - Primary Reference
**File:** `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.js`

```javascript
export const anvilSetAutomineJsonRpcProcedure = (client) => {
    return async (request) => {
        const enabled = request.params[0]
        
        if (enabled) {
            client.miningConfig = { type: 'auto' }
        } else {
            // When disabling automine, switch to manual mining
            client.miningConfig = { type: 'manual' }
        }
        
        return {
            jsonrpc: '2.0',
            method: request.method,
            result: null,
            ...(request.id !== undefined ? { id: request.id } : {}),
        }
    }
}
```

Key behaviors:
- Single boolean parameter `enabled`
- Returns `null` on success
- Updates `client.miningConfig.type` to `'auto'` or `'manual'`

**File:** `../tevm-monorepo/packages/actions/src/Call/handleAutomining.js`
```javascript
export const handleAutomining = async (client, txHash, _reserved = false, mineAllTx = true) => {
    // Mine a single block
    const mineRes = await mineHandler(client)({
        ...(mineAllTx || txHash === undefined ? {} : { tx: txHash }),
        throwOnFail: false,
        blockCount: 1,
    })
    // ...
}
```

Integration point:
- Called from `eth_sendTransaction` and `eth_sendRawTransaction` handlers
- Only triggers automining when `client.miningConfig.type === 'auto'`

**File:** `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.spec.ts`
Tests:
- Enable automine: `params: [true]` → `miningConfig: { type: 'auto' }`
- Disable automine: `params: [false]` → `miningConfig: { type: 'manual' }`
- Returns proper JSON-RPC response with `result: null`

### Foundry Anvil (Rust)
**File:** `foundry/crates/anvil/src/eth/api.rs` (lines 2065-2082)

```rust
/// Handler for ETH RPC call: `evm_setAutomine`
pub async fn anvil_set_auto_mine(&self, enable_automine: bool) -> Result<()> {
    node_info!("evm_setAutomine");
    if self.miner.is_auto_mine() {
        if enable_automine {
            return Ok(());
        }
        self.miner.set_mining_mode(MiningMode::None);
    } else if enable_automine {
        let listener = self.pool.add_ready_listener();
        let mode = MiningMode::instant(1_000, listener);
        self.miner.set_mining_mode(mode);
    }
    Ok(())
}
```

**File:** `foundry/crates/anvil/src/eth/miner.rs`
- `MiningMode::Auto(ReadyTransactionMiner)` - automine mode
- `MiningMode::None` - manual mining
- `is_auto_mine()` returns true only for Auto mode
- `set_mining_mode()` updates mode and wakes the miner

**File:** `foundry/crates/anvil/core/src/eth/mod.rs` (line 381)
```rust
#[serde(rename = "anvil_setAutomine", alias = "evm_setAutomine", with = "sequence")]
SetAutomine(bool),
```

Method aliases supported:
- `anvil_setAutomine`
- `evm_setAutomine`

### Hardhat EDR (Rust)
**File:** `edr/crates/edr_provider/src/requests/eth/evm.rs` (lines 72-82)

```rust
pub fn handle_set_automine_request<
    ChainSpecT: ProviderSpec<TimerT>,
    TimerT: Clone + TimeSinceEpoch,
>(
    data: &mut ProviderData<ChainSpecT, TimerT>,
    automine: bool,
) -> Result<bool, ProviderErrorForChainSpec<ChainSpecT>> {
    data.set_auto_mining(automine);
    Ok(true)
}
```

**File:** `edr/crates/edr_provider/src/data.rs`
```rust
pub struct ProviderData<...> {
    is_auto_mining: bool,
    // ...
}

pub fn is_auto_mining(&self) -> bool {
    self.is_auto_mining
}

pub fn set_auto_mining(&mut self, enabled: bool) {
    self.is_auto_mining = enabled;
}
```

**File:** `edr/crates/edr_provider/src/requests/hardhat/config.rs`
```rust
pub fn handle_get_automine_request<...>(
    data: &ProviderData<ChainSpecT, TimerT>,
) -> Result<bool, ProviderErrorForChainSpec<ChainSpecT>> {
    Ok(data.is_auto_mining())
}
```

Transaction submission integration:
```rust
// In send_transaction logic (data.rs line 2545)
let snapshot_id = if self.is_auto_mining {
    // Validate and mine immediately
    self.validate_auto_mine_transaction(&transaction)?;
    // ... mine block
}
```

## Voltaire (Upstream Dependency)

### Current Status
**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/`
- Has `eth/` namespace with 40+ methods
- Has `debug/` namespace
- Has `engine/` namespace
- **No `anvil/` or `evm/` namespace** - these need to be added

**File:** `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
```zig
pub const JsonRpcMethod = union(enum) {
    engine: engineMethods.EngineMethod,
    eth: ethMethods.EthMethod,
    debug: debugMethods.DebugMethod,
    // anvil/evm methods need to be added
```

### What Needs to Be Added to Voltaire
Based on the pattern in `eth/methods.zig`, need to create:
- `anvil/methods.zig` or `evm/methods.zig` with method definitions
- Individual method files like `setAutomine/evm_setAutomine.zig`

**Example from eth/blockNumber/eth_blockNumber.zig:**
```zig
pub const method = "eth_blockNumber";

pub const Params = struct {};

pub const Result = primitives.Quantity;
```

For `evm_setAutomine`:
```zig
pub const method = "evm_setAutomine";  // or "anvil_setAutomine"

pub const Params = struct {
    enabled: bool,
};

pub const Result = ?void;  // null
```

### State Manager Integration
**File:** `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`
- Has `JournaledState` with checkpoint/revert
- Has snapshot/revert functionality
- Mining state should be added here or in a higher-level node struct

## Integration Points in ZEVM

### 1. Mining State (Depends on ZEVM-001)
The `evm_setAutomine` handler needs to update mining configuration:
```zig
// In ZEVM node/client struct
mining_config: MiningConfig,

const MiningConfig = union(enum) {
    auto: void,
    manual: void,
    interval: struct { block_time: u64 },
};
```

### 2. Transaction Submission Pipeline
When `eth_sendTransaction` or `eth_sendRawTransaction` is called:
1. Validate and add transaction to mempool
2. Check `mining_config` - if `auto`, trigger block mining
3. Return transaction hash

### 3. RPC Handler Implementation
```zig
// src/rpc/evm/setAutomine.zig
pub const method = "evm_setAutomine";

pub const Params = struct {
    enabled: bool,
};

pub const Result = @Type(.null);

pub fn handler(node: *Node, params: Params) !Result {
    if (params.enabled) {
        node.mining_config = .{ .auto = {} };
    } else {
        node.mining_config = .{ .manual = {} };
    }
    return null;
}
```

## RPC Method Aliases
Per Foundry's implementation:
- `evm_setAutomine` - original Hardhat method name
- `anvil_setAutomine` - Anvil alias

Both should be supported for compatibility.

## JSON-RPC Request/Response Format

Request:
```json
{
  "jsonrpc": "2.0",
  "method": "evm_setAutomine",
  "params": [true],
  "id": 1
}
```

Response (success):
```json
{
  "jsonrpc": "2.0",
  "result": null,
  "id": 1
}
```

Response (already in requested mode - optional optimization):
```json
{
  "jsonrpc": "2.0",
  "result": null,
  "id": 1
}
```

## Tests to Port

### TEVM
**File:** `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.spec.ts`
- Test enable automine from manual mode
- Test disable automine from auto mode
- Test id preservation in response

### Foundry
**File:** `foundry/crates/anvil/tests/it/anvil.rs`
```rust
#[tokio::test(flavor = "multi_thread")]
async fn test_can_change_mining_mode() {
    assert!(api.anvil_get_auto_mine().unwrap());  // default is auto
    api.anvil_set_interval_mining(1).unwrap();
    assert!(!api.anvil_get_auto_mine().unwrap());  // interval disables auto
    // ...
}
```

### EDR
**File:** `edr/crates/edr_provider/tests/integration/eth_request_serialization.rs`
Tests for `evm_setAutomine` request serialization

## Related Methods
These should be implemented together or after `evm_setAutomine`:

1. `anvil_getAutomine` / `evm_getAutomine` - Get current automine status
2. `anvil_setIntervalMining` / `evm_setIntervalMining` - Set interval mining
3. `anvil_getIntervalMining` - Get interval mining status
4. `evm_mine` / `anvil_mine` / `hardhat_mine` - Manual mine

## Implementation Notes

1. **Upstream First**: Add JSON-RPC types to `voltaire` first, then wire up handler in ZEVM
2. **State Management**: Mining config should be part of ZEVM's node/client runtime state
3. **Transaction Integration**: The automining logic needs to be triggered after successful transaction submission
4. **Thread Safety**: If ZEVM uses multi-threading, mining mode changes need proper synchronization
5. **Default Behavior**: Default should be automine enabled (matches Hardhat/Anvil/TEVM)

## Dependencies
- ZEVM-001: MiningConfig type and state management (adds the mining state)
- HTTP JSON-RPC server infrastructure (needed to expose the handler)

## Files to Modify

### In Voltaire (Upstream)
- Add to `../voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`:
  - `anvil: anvilMethods.AnvilMethod` or `evm: evmMethods.EvmMethod`
- Create `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/methods.zig` or `evm/methods.zig`
- Create `../voltaire/packages/voltaire-zig/src/jsonrpc/anvil/setAutomine/anvil_setAutomine.zig`
- Create `../voltaire/packages/voltaire-zig/src/jsonrpc/evm/setAutomine/evm_setAutomine.zig`

### In ZEVM
- Create `src/rpc/` directory structure
- Create `src/rpc/evm/setAutomine.zig` - Handler implementation
- Create `src/rpc/router.zig` - Route requests to handlers
- Modify `src/main.zig` or create `src/node.zig` - Node runtime with mining state

## References Summary
| File | Purpose |
|------|---------|
| `../tevm-monorepo/packages/actions/src/anvil/anvilSetAutomineProcedure.js` | Primary reference implementation |
| `../tevm-monorepo/packages/actions/src/Call/handleAutomining.js` | Automining trigger logic |
| `foundry/crates/anvil/src/eth/api.rs` | Anvil API with set_auto_mine |
| `foundry/crates/anvil/src/eth/miner.rs` | MiningMode enum and Miner struct |
| `foundry/crates/anvil/core/src/eth/mod.rs` | RPC method aliases |
| `edr/crates/edr_provider/src/requests/eth/evm.rs` | EDR setAutomine handler |
| `edr/crates/edr_provider/src/data.rs` | Provider data with is_auto_mining |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` | Pattern for method definitions |
