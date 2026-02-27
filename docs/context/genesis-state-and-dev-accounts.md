# Research Context: genesis-state-and-dev-accounts

## Ticket Summary

Implement genesis state initialization with pre-funded dev accounts and a genesis block. This is the foundation that all RPC handlers depend on: without it, `eth_getBalance` returns 0, `eth_blockNumber` returns nothing, and `eth_accounts` is empty.

Three pieces:
1. **Genesis State** - 10 dev accounts from HD mnemonic, pre-funded with 10,000 ETH each
2. **Genesis Block** - Block 0 stored in Blockchain, set as canonical head
3. **Node Startup** - Wire everything together, print startup banner

---

## Reference Implementation Comparison

| Parameter | Hardhat/EDR | Anvil (Foundry) | TEVM | **ZEVM (target)** |
|---|---|---|---|---|
| Mnemonic | `test test test...junk` | `test test test...junk` | Same 10 addresses | `test test test...junk` |
| Chain ID | 31337 | 31337 | 900 | **31337** |
| Accounts | 20 | 10 | 10 | **10** |
| Balance | 10,000 ETH | 100 ETH | 1,000 ETH | **10,000 ETH** |
| Gas Limit | 30,000,000 | 30,000,000 | 30,000,000 | **30,000,000** |
| Base Fee | 1 gwei | 1 gwei | 1 gwei | **1 gwei** |
| Derivation | `m/44'/60'/0'/0/{i}` | `m/44'/60'/0'/0/{i}` | Hardcoded addrs | **Hardcoded** |

**Decision**: Use 10,000 ETH (matches Hardhat standard). Hardcode the 10 well-known addresses and private keys rather than implementing BIP-32/BIP-44 derivation at runtime.

---

## Well-Known Dev Accounts

Derived from mnemonic `test test test test test test test test test test test junk` via `m/44'/60'/0'/0/{i}`:

| Index | Address | Private Key |
|---|---|---|
| 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |
| 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | `0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6` |
| 4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` | `0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a` |
| 5 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` | `0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba` |
| 6 | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` | `0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e` |
| 7 | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` | `0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356` |
| 8 | `0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f` | `0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97` |
| 9 | `0xa0Ee7A142d267C1f36714E4a8F75612F20a79720` | `0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6` |

**Source**: These are the standard Hardhat/Anvil dev accounts. The first account (`0xf39F...`) is the default coinbase.

---

## Upstream Dependencies (voltaire)

### StateManager (`../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`)

**Already provides**:
- `StateManager.init(allocator, null)` - Initialize without fork backend
- `setBalance(address, balance)` - Set account balance
- `setNonce(address, nonce)` - Set account nonce
- `getBalance(address)` / `getNonce(address)` - Read state
- `checkpoint()` / `revert()` / `commit()` - Journaling
- `snapshot()` / `revertToSnapshot(id)` - Snapshot support

**Usage for genesis**: Call `setBalance(addr, 10000 * 10^18)` for each of the 10 accounts.

**Note**: `StateManager` stores an allocator internally (violates CLAUDE.md style for new code, but this is existing upstream code - don't refactor).

### Blockchain (`../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`)

**Already provides**:
- `Blockchain.init(allocator, null)` - Initialize without fork cache
- `putBlock(block)` - Store a block
- `setCanonicalHead(hash)` - Set canonical chain head
- `getHeadBlockNumber()` - Get current head number
- `getBlockByNumber(n)` / `getBlockByHash(h)` - Block retrieval

**Usage for genesis**: Create genesis block via `Block.genesis(chain_id, allocator)`, then `putBlock()` + `setCanonicalHead()`.

### Block Primitives (`../voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig`)

**Block struct fields**:
```
header: BlockHeader, body: BlockBody, hash: Hash, size: u64, total_difficulty: ?u256
```

**BlockHeader struct fields** (all with defaults):
```
parent_hash: Hash = ZERO, ommers_hash: Hash = ZERO, beneficiary: Address = ZERO,
state_root: Hash = ZERO, transactions_root: Hash = ZERO, receipts_root: Hash = ZERO,
logs_bloom: [256]u8 = zeros, difficulty: u256 = 0, number: u64 = 0,
gas_limit: u64 = 0, gas_used: u64 = 0, timestamp: u64 = 0,
extra_data: []const u8 = empty, mix_hash: Hash = ZERO, nonce: [8]u8 = zeros,
base_fee_per_gas: ?u256 = null, withdrawals_root: ?Hash = null,
blob_gas_used: ?u64 = null, excess_blob_gas: ?u64 = null,
parent_beacon_block_root: ?Hash = null
```

**`Block.genesis(chain_id, allocator)`** exists but only sets:
- `ommers_hash = EMPTY_OMMERS_HASH`
- `transactions_root = EMPTY_TRANSACTIONS_ROOT`
- `receipts_root = EMPTY_RECEIPTS_ROOT`
- `number = 0`

**Missing from existing genesis**: `gas_limit`, `base_fee_per_gas`, `timestamp`, `beneficiary`. We need to create a custom genesis header with these fields set.

**`Block.from(&header, &body, allocator)`** - Create block from header+body, computes hash.

### Crypto (`../voltaire/packages/voltaire-zig/src/crypto/`)

**Available**:
- `bip39.zig` - Full BIP-39 mnemonic implementation (mnemonic-to-seed)
- `secp256k1.zig` - ECDSA signing, public key recovery, address derivation
- `signers.zig` - `LocalSigner.init(private_key)` / `LocalSigner.fromHex(hex)`

**NOT available in pure Zig**: BIP-32/BIP-44 HD key derivation (only via libwally-core C FFI in `c_api.zig`). This is fine because we will hardcode the 10 well-known private keys.

### Address Parsing (`../voltaire/packages/voltaire-zig/src/primitives/Address/address.zig`)

- `primitives.Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")` - Parse hex to Address

---

## Upstream Dependencies (guillotine-mini)

### HostInterface (`../guillotine-mini/src/host.zig`)

Vtable-based interface for EVM state access:
```zig
pub const VTable = struct {
    getBalance, setBalance, getCode, setCode,
    getStorage, setStorage, getNonce, setNonce
};
```

Already adapted in zevm via `HostAdapter` (`src/host_adapter.zig`).

### BlockContext (`../guillotine-mini/src/evm.zig`)

Used by `block_builder.zig`:
```zig
pub const BlockContext = struct {
    block_number: u64,
    block_gas_limit: u64,
    // ... other fields
};
```

---

## Existing zevm Code

### Database (`src/database/database.zig`)

```zig
pub const Database = struct {
    state: state_manager.StateManager,
    accounts: Accounts,        // Merkle Patricia Trie for state root
    contracts: Contracts,      // code_hash -> bytecode
    block_hashes: BlockHashes, // block_number -> hash
};
```

**Note**: `Database` wraps `StateManager` but does NOT currently have:
- `current_block_number` field (mentioned in ticket)
- Genesis initialization method
- The `accountIterator()` method called in `syncCachedAccountsToTrie` does not exist in voltaire's StateManager - this needs fixing

### BlockBuilder (`src/block_builder.zig`)

Already uses `state_manager.StateManager` + `guillotine_mini.HostInterface` + `guillotine_mini.BlockContext`.

### build.zig

zevm imports from voltaire: `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles`
zevm imports from guillotine-mini: `guillotine_mini` module

---

## Implementation Plan

### 1. Hardcode Dev Accounts (in zevm)

Create a constant table of 10 dev accounts with addresses and private keys as comptime-known byte arrays. No runtime BIP-32 derivation needed.

```zig
// Conceptual structure
pub const DevAccount = struct {
    address: primitives.Address,
    private_key: [32]u8,
};

pub const DEV_ACCOUNTS: [10]DevAccount = .{ ... };
pub const DEV_BALANCE: u256 = 10_000 * 1_000_000_000_000_000_000; // 10000 ETH
pub const CHAIN_ID: u64 = 31337;
pub const DEFAULT_GAS_LIMIT: u64 = 30_000_000;
pub const DEFAULT_BASE_FEE: u256 = 1_000_000_000; // 1 gwei
```

### 2. Genesis Block Construction (in zevm)

Create a custom genesis block rather than using `Block.genesis()` directly, because we need to set `gas_limit`, `base_fee_per_gas`, and `timestamp`:

```zig
var header = primitives.BlockHeader.init();
header.number = 0;
header.gas_limit = 30_000_000;
header.base_fee_per_gas = 1_000_000_000;
header.timestamp = @intCast(std.time.timestamp());
header.beneficiary = DEV_ACCOUNTS[0].address;
header.ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH;
header.transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT;
header.receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT;
// parent_hash, difficulty, mix_hash all default to zero

const body = primitives.BlockBody.init();
const genesis_block = try primitives.Block.from(&header, &body, allocator);
```

### 3. Node Initialization (in zevm)

```
1. Create StateManager (no fork backend)
2. For each dev account: setBalance(address, 10000 ETH)
3. Create genesis BlockHeader with gas_limit, base_fee, timestamp, coinbase
4. Build Block from header+body, compute hash
5. Create Blockchain, putBlock(genesis), setCanonicalHead(hash)
6. Store genesis hash in Database.block_hashes
7. Print startup banner
```

### 4. Startup Banner (in zevm)

Match Hardhat/Anvil format:
```
zevm - Ethereum local node
Chain ID: 31337

Available Accounts
==================
(0) 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (10000 ETH)
(1) 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (10000 ETH)
...

Private Keys
==================
(0) 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
(1) 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
...

Wallet
==================
Mnemonic: test test test test test test test test test test test junk
Derivation path: m/44'/60'/0'/0/

Base Fee: 1000000000 (1 gwei)
Gas Limit: 30000000
```

---

## Key Files to Modify/Create

### zevm (new/modified)
- `src/genesis.zig` (NEW) - Dev account constants, genesis block builder, startup banner
- `src/main.zig` (MODIFY) - Wire genesis initialization into startup
- `src/database/database.zig` (MODIFY) - Add `current_block_number` field if needed
- `src/root.zig` (MODIFY) - Export genesis module

### voltaire (potential fix needed)
- `StateManager.zig` - The `accountIterator()` method called in `database.zig:syncCachedAccountsToTrie` does not exist. Either:
  - Add it to voltaire's StateManager, OR
  - Fix zevm's `syncCachedAccountsToTrie` to not use it

---

## Constants Reference

```
CHAIN_ID          = 31337
GAS_LIMIT         = 30_000_000
BASE_FEE          = 1_000_000_000 (1 gwei)
DEV_BALANCE       = 10_000_000_000_000_000_000_000 (10,000 ETH in wei)
GENESIS_NUMBER    = 0
GENESIS_DIFFICULTY = 0
GENESIS_PARENT    = 0x00..00 (32 zero bytes)
MNEMONIC          = "test test test test test test test test test test test junk"
DERIVATION_PATH   = "m/44'/60'/0'/0/"
NUM_ACCOUNTS      = 10
COINBASE          = DEV_ACCOUNTS[0].address
```

---

## Reference Files Read

### Voltaire (upstream, we own)
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` - State management with journaling and snapshots
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` - Block storage with fork cache support
- `../voltaire/packages/voltaire-zig/src/crypto/root.zig` - Crypto module index (bip39, secp256k1, signers)
- `../voltaire/packages/voltaire-zig/src/crypto/bip39.zig` - BIP-39 mnemonic to seed
- `../voltaire/packages/voltaire-zig/src/crypto/secp256k1.zig` - ECDSA operations
- `../voltaire/packages/voltaire-zig/src/crypto/signers.zig` - LocalSigner from private key
- `../voltaire/packages/voltaire-zig/src/primitives/root.zig` - All primitive type exports

### Guillotine-mini (upstream, we own)
- `../guillotine-mini/src/root.zig` - Module exports (Evm, HostInterface, BlockContext)
- `../guillotine-mini/src/host.zig` - HostInterface vtable definition

### zevm (this repo)
- `src/main.zig` - Current stub (just prints "zevm - Ethereum local node")
- `src/root.zig` - Module exports
- `src/database/database.zig` - Database wrapping StateManager + trie
- `src/database/accounts.zig` - Merkle Patricia Trie for accounts
- `src/database/block_hashes.zig` - Block number to hash mapping
- `src/database/contracts.zig` - Code hash to bytecode mapping
- `src/database/database_test.zig` - Existing database tests
- `src/host_adapter.zig` - StateManager to HostInterface adapter
- `src/block_builder.zig` - Transaction execution into blocks
- `build.zig` - Build configuration with voltaire + guillotine-mini deps
- `build.zig.zon` - Dependency paths (../voltaire, ../guillotine-mini)

### Foundry Anvil (reference)
- `foundry/crates/anvil/src/config.rs` - DEFAULT_MNEMONIC, CHAIN_ID=31337, DEFAULT_GAS_LIMIT=30M, AccountGenerator with 10 accounts at 100 ETH, derivation path m/44'/60'/0'/0/{i}
- `foundry/crates/anvil/src/lib.rs` - Startup banner printing, node initialization

### Hardhat EDR (reference)
- `edr/crates/edr_provider/src/config.rs` - Provider config struct with genesis_state, owned_accounts
- `edr/crates/edr_defaults/src/lib.rs` - DEV_CHAIN_ID=31337, 20 SECRET_KEYS
- `edr/crates/edr_provider/src/data.rs` - DEFAULT_INITIAL_BASE_FEE_PER_GAS=1gwei, genesis block creation

### TEVM (reference)
- `../tevm-monorepo/packages/node/src/createTevmNode.js` - Node creation with genesis state
- `../tevm-monorepo/packages/node/src/GENESIS_STATE.js` - 10 prefunded accounts at 1000 ETH, Multicall3 predeploy
