# Context: add-block-response-types-to-voltaire

## Ticket Info

- **Ticket ID:** `add-block-response-types-to-voltaire`
- **Category:** `cat-5-block-queries`
- **Goal:** Create a proper `BlockResponse` type in voltaire that matches the execution-apis specification for `eth_getBlockByNumber`/`eth_getBlockByHash` responses.

## Current State in Voltaire

### Existing Method Files

Located at:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByNumber/eth_getBlockByNumber.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByHash/eth_getBlockByHash.zig`

Both files currently have minimal placeholder `Result` types:

```zig
/// Result for `eth_getBlockByNumber`
pub const Result = struct {
    value: types.Quantity,
    // ... jsonStringify/jsonParseFromValue
};
```

This needs to be replaced with a proper `BlockResponse` type.

### Existing Type Infrastructure

Located at `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/`:
- `Quantity.zig` - Generic JSON value wrapper for hex quantities
- `Hash.zig` - 32-byte hash with JSON hex encoding
- `Address.zig` - 20-byte address with JSON hex encoding
- `BlockTag.zig` - Generic JSON value wrapper for block tags
- `BlockSpec.zig` - Block specification types

## Execution APIs Specification

### Block Schema (from `execution-apis/src/schemas/block.yaml`)

Required fields:
- `hash` - hash32
- `parentHash` - hash32
- `sha3Uncles` - hash32
- `miner` - address
- `stateRoot` - hash32
- `transactionsRoot` - hash32
- `receiptsRoot` - hash32
- `logsBloom` - bytes256
- `number` - uint
- `gasLimit` - uint
- `gasUsed` - uint
- `timestamp` - uint
- `extraData` - bytes
- `mixHash` - hash32
- `nonce` - bytes8
- `size` - uint
- `transactions` - array of hash32 OR array of TransactionInfo
- `uncles` - array of hash32

Optional fields (by fork):
- `difficulty` - uint (pre-merge, 0 post-merge)
- `totalDifficulty` - uint (pre-merge only)
- `baseFeePerGas` - uint (post-London/EIP-1559)
- `withdrawalsRoot` - hash32 (post-Shanghai/EIP-4895)
- `withdrawals` - array of Withdrawal (post-Shanghai)
- `blobGasUsed` - uint (post-Cancun/EIP-4844)
- `excessBlobGas` - uint (post-Cancun)
- `parentBeaconBlockRoot` - hash32 (post-Cancun)
- `requestsHash` - hash32 (post-Prague/EIP-7685)

### Block Method Specs (from `execution-apis/src/eth/block.yaml`)

Both `eth_getBlockByHash` and `eth_getBlockByNumber` return:
```yaml
result:
  name: Block information
  schema:
    oneOf:
      - $ref: '#/components/schemas/notFound'  # null
      - $ref: '#/components/schemas/Block'
```

## Reference Implementations

### Hardhat EDR (Rust)

File: `edr/crates/edr_provider/src/requests/eth/blocks.rs`

Key patterns:
- Uses `L1RpcBlock<HashOrTransaction<RpcTransactionT>>` as return type
- `HashOrTransaction` enum handles the `hydrated` toggle:
  ```rust
  #[serde(untagged)]
  pub enum HashOrTransaction<RpcTransactionT> {
      Hash(B256),
      Transaction(RpcTransactionT),
  }
  ```
- `block_to_rpc_output()` function constructs the response:
  - Sets `mix_hash` and `nonce` to `None` for pending blocks
  - Sets `number` to `None` for pending blocks
  - Includes `total_difficulty` (optional, pre-merge only)
  - Conditionally includes withdrawals, blob fields, base fee

### Foundry Anvil (Rust)

File: `foundry/crates/anvil/core/src/eth/block.rs`

Key patterns:
- Uses alloy's `Header` struct with all block fields
- `BlockInfo` struct combines block, transactions, and receipts
- Header fields include all fork-specific optional fields as `Option<T>`

### TEVM (TypeScript)

File: `/Users/williamcory/tevm-monorepo/packages/actions/src/utils/blockToJsonRpcBlock.js`

Key patterns:
- Converts internal Block to JSON-RPC response format
- Conditionally includes fields based on fork:
  ```javascript
  ...(header.withdrawalsRoot !== undefined
      ? { withdrawalsRoot: header.withdrawalsRoot, withdrawals: json.withdrawals }
      : {}),
  ...(header.blobGasUsed !== undefined ? { blobGasUsed: header.blobGasUsed } : {}),
  ```
- `transactions` array contains either hex hashes or full transaction objects

## Voltaire Primitives Available

### Block Structure

From `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig`:
```zig
pub const Block = struct {
    header: BlockHeader.BlockHeader,
    body: BlockBody.BlockBody,
    hash: Hash.Hash,
    size: u64,
    total_difficulty: ?u256 = null,
};
```

### BlockHeader Structure

From `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig`:
```zig
pub const BlockHeader = struct {
    parent_hash: Hash.Hash = Hash.ZERO,
    ommers_hash: Hash.Hash = Hash.ZERO,
    beneficiary: Address.Address = Address.ZERO_ADDRESS,
    state_root: Hash.Hash = Hash.ZERO,
    transactions_root: Hash.Hash = Hash.ZERO,
    receipts_root: Hash.Hash = Hash.ZERO,
    logs_bloom: [BLOOM_SIZE]u8 = [_]u8{0} ** BLOOM_SIZE,
    difficulty: u256 = 0,
    number: BlockNumber.BlockNumber = 0,
    gas_limit: u64 = 0,
    gas_used: u64 = 0,
    timestamp: u64 = 0,
    extra_data: []const u8 = &[_]u8{},
    mix_hash: Hash.Hash = Hash.ZERO,
    nonce: [NONCE_SIZE]u8 = [_]u8{0} ** NONCE_SIZE,
    base_fee_per_gas: ?u256 = null,
    withdrawals_root: ?Hash.Hash = null,
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
    parent_beacon_block_root: ?Hash.Hash = null,
};
```

### BlockBody Structure

From `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockBody/BlockBody.zig`:
```zig
pub const BlockBody = struct {
    transactions: []const TransactionData = &[_]TransactionData{},
    ommers: []const UncleHeader = &[_]UncleHeader{},
    withdrawals: ?[]const Withdrawal = null,
};

pub const Withdrawal = struct {
    index: u64 = 0,
    validator_index: u64 = 0,
    address: Address.Address = Address.ZERO_ADDRESS,
    amount: u64 = 0,
};
```

## Test Vectors

From `execution-apis/tests/eth_getBlockByNumber/`:

### Cancun Block Example (get-block-cancun-fork.io)
```json
{
  "baseFeePerGas": "0x822595b",
  "blobGasUsed": "0x20000",
  "difficulty": "0x0",
  "excessBlobGas": "0x0",
  "extraData": "0x",
  "gasLimit": "0x47e7c40",
  "gasUsed": "0x3b27a",
  "hash": "0x60d8d4c8d64367b4436e63f43addb9e3bd99a5a4176b84429fc4f22e27a7ee63",
  "logsBloom": "0x0000...",
  "miner": "0x0000000000000000000000000000000000000000",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "nonce": "0x0000000000000000",
  "number": "0x2a",
  "parentBeaconBlockRoot": "0x83472eda6eb475906aeeb7f09e757ba9f6663b9f6a5bf8611d6306f677f67ebd",
  "parentHash": "0x9c1ebc6ea2a8e7a58a8bc73ded493f98bb86d4456bdf883328413163a1ab55a8",
  "receiptsRoot": "0xd986dfa6b469d59e2b16338ad9b4e757dd3d29deda9676d4d1dde8ec7721ea54",
  "sha3Uncles": "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
  "size": "0x49f",
  "stateRoot": "0x4d368dd9b1ba388fb07796f48729d7ee7d1be7c69eda22184b6acd0b98c6a6eb",
  "timestamp": "0x1a4",
  "transactions": ["0x6bcea0da8e703d3283c8f1124377a63023290cd188de3274d12441e15dc14794", ...],
  "transactionsRoot": "0xa16f5ce410d10f0b13a7b35739d5b877b7b02a0e01e46a2915c194cd5bec3380",
  "uncles": [],
  "withdrawals": [],
  "withdrawalsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"
}
```

### Genesis Block Example (get-genesis.io)
```json
{
  "difficulty": "0x20000",
  "extraData": "0x68697665636861696e",
  "gasLimit": "0x23f3e20",
  "gasUsed": "0x0",
  "hash": "0x79e0f5ffb6a0c9f54d507dbbadc935603ac1db86d32f7857472180a75ec11f90",
  "logsBloom": "0x0000...",
  "miner": "0x0000000000000000000000000000000000000000",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "nonce": "0x0000000000000000",
  "number": "0x0",
  "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "receiptsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
  "sha3Uncles": "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
  "size": "0x205",
  "stateRoot": "0xe5d8b049a78427be8c23ebd6811ed436b3a36cc117954b496848b90f0c654844",
  "timestamp": "0x0",
  "transactions": [],
  "transactionsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
  "uncles": []
}
```

## Implementation Plan

### 1. Create `BlockResponse.zig` Type

Location: `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockResponse.zig`

The type should include:

```zig
pub const BlockResponse = struct {
    // Required fields
    hash: Hash,
    parentHash: Hash,
    sha3Uncles: Hash,
    miner: Address,
    stateRoot: Hash,
    transactionsRoot: Hash,
    receiptsRoot: Hash,
    logsBloom: LogsBloom, // [256]u8 wrapper
    number: Quantity,
    gasLimit: Quantity,
    gasUsed: Quantity,
    timestamp: Quantity,
    extraData: Data, // variable hex bytes
    mixHash: Hash,
    nonce: Nonce, // [8]u8 wrapper
    size: Quantity,
    transactions: std.json.Value, // Array of hashes OR Transaction objects
    uncles: std.json.Value, // Array of hash strings
    
    // Optional fork-specific fields
    difficulty: ?Quantity = null,
    totalDifficulty: ?Quantity = null,
    baseFeePerGas: ?Quantity = null,
    withdrawalsRoot: ?Hash = null,
    withdrawals: ?std.json.Value = null,
    blobGasUsed: ?Quantity = null,
    excessBlobGas: ?Quantity = null,
    parentBeaconBlockRoot: ?Hash = null,
    requestsHash: ?Hash = null,
};
```

### 2. Create `TransactionInfo.zig` Type (for hydrated transactions)

Location: `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/TransactionInfo.zig`

Must support all transaction types (legacy, 2930, 1559, 4844, 7702) with proper field selection per type.

### 3. Create `Withdrawal.zig` Type

Location: `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Withdrawal.zig`

```zig
pub const Withdrawal = struct {
    index: Quantity,
    validatorIndex: Quantity,
    address: Address,
    amount: Quantity,
};
```

### 4. Update `eth_getBlockByNumber.zig`

- Change `Result` to use `BlockResponse`
- Update Params to use proper `BlockNumberOrTag` type instead of `Quantity`

### 5. Update `eth_getBlockByHash.zig`

- Change `Result` to use `BlockResponse`

### 6. Update `types.zig`

Export new types:
```zig
pub const BlockResponse = @import("types/BlockResponse.zig");
pub const TransactionInfo = @import("types/TransactionInfo.zig");
pub const Withdrawal = @import("types/Withdrawal.zig");
```

## Related Files Summary

| File | Purpose |
|------|---------|
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByNumber/eth_getBlockByNumber.zig` | Method definition to update |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getBlockByHash/eth_getBlockByHash.zig` | Method definition to update |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` | Type exports to update |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig` | Source block structure |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig` | Source header fields |
| `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockBody/BlockBody.zig` | Source body/withdrawals |
| `execution-apis/src/schemas/block.yaml` | Block schema spec |
| `execution-apis/src/schemas/transaction.yaml` | Transaction schema spec |
| `execution-apis/tests/eth_getBlockByNumber/` | Test vectors |

## JSON Serialization Notes

Per EIP-1474:
- **QUANTITY**: Hex-encoded, 0x-prefixed, no leading zeros (except `0x0`)
- **DATA**: Hex-encoded, 0x-prefixed, two hex digits per byte
- Optional fields should be omitted when null (not serialized as `null`)

## Next Steps After Implementation

1. Update ZEVM's block query handlers to use the new `BlockResponse` type
2. Implement conversion from `primitives.Block` to `BlockResponse`
3. Handle transaction hydration (full tx objects vs hashes)
4. Test against execution-apis test vectors
5. Run hive rpc-compat simulator for validation
