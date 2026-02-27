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
- `setBalance(address, balance)` - Set account balance (u256)
- `setNonce(address, nonce)` - Set account nonce (u64)
- `setCode(address, code)` - Set account code ([]const u8)
- `setStorage(address, slot, value)` - Set storage (u256, u256)
- `getBalance(address)` / `getNonce(address)` / `getCode(address)` / `getStorage(address, slot)` - Read state
- `checkpoint()` / `revert()` / `commit()` - Journaling
- `snapshot()` / `revertToSnapshot(id)` - Snapshot support (returns u64 id)
- `clearCaches()` / `clearForkCache()` - Cache management

**Usage for genesis**: Call `setBalance(addr, 10000 * 10^18)` for each of the 10 accounts.

**Note**: `StateManager` stores an allocator internally (violates CLAUDE.md style for new code, but this is existing upstream code - don't refactor).

**Known issue**: `accountIterator()` is called in `database.zig:syncCachedAccountsToTrie` but does NOT exist in voltaire's `StateManager` or `JournaledState`. This must be fixed (either add it to voltaire or remove usage in zevm).

### Blockchain (`../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`)

**Already provides**:
- `Blockchain.init(allocator, null)` - Initialize without fork cache
- `putBlock(block)` - Store a block (validates parent linkage)
- `setCanonicalHead(hash)` - Set canonical chain head
- `getHeadBlockNumber()` - Get current head number (?u64)
- `getBlockByNumber(n)` / `getBlockByHash(h)` - Block retrieval (!?Block)
- `getBlockLocal(hash)` / `getBlockByNumberLocal(number)` - Local-only access
- `isCanonical(hash)` / `isCanonicalStrict(hash, throw)` - Canonicality checks
- `localBlockCount()` / `orphanCount()` / `canonicalChainLength()` - Statistics
- `last256BlockHashesLocal(tip_hash, &buf)` - Recent block hashes for BLOCKHASH opcode

**Usage for genesis**: Create genesis block via `primitives.Block.from(&header, &body, allocator)`, then `putBlock()` + `setCanonicalHead()`.

### Block Primitives

#### Block (`../voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig`)

```
Block struct fields: header, body, hash, size, total_difficulty(?u256)
```

Key functions:
- `Block.from(&header, &body, allocator)` - Create block from components, computes hash+size
- `Block.genesis(chain_id, allocator)` - Creates minimal genesis (only sets ommers_hash, tx_root, receipts_root, number=0)
- `Block.fromHeader(&header, allocator)` - Block with empty body
- `Block.postMerge(&header, &body, allocator)` - Post-merge block (no total_difficulty)

**`Block.genesis()` is too minimal** - it does NOT set gas_limit, base_fee_per_gas, timestamp, or beneficiary. We must construct our own genesis header.

#### BlockHeader (`../voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig`)

All fields with defaults (important ones for genesis):
```zig
parent_hash: Hash = ZERO,           // Genesis: 0x00..00 (correct default)
ommers_hash: Hash = ZERO,           // Genesis: EMPTY_OMMERS_HASH
beneficiary: Address = ZERO_ADDRESS, // Genesis: first dev account
state_root: Hash = ZERO,            // Genesis: computed from state
transactions_root: Hash = ZERO,     // Genesis: EMPTY_TRANSACTIONS_ROOT
receipts_root: Hash = ZERO,         // Genesis: EMPTY_RECEIPTS_ROOT
logs_bloom: [256]u8 = zeros,        // Genesis: all zeros
difficulty: u256 = 0,               // Genesis: 0 (post-merge)
number: u64 = 0,                    // Genesis: 0
gas_limit: u64 = 0,                 // Genesis: 30_000_000
gas_used: u64 = 0,                  // Genesis: 0
timestamp: u64 = 0,                 // Genesis: current time
extra_data: []const u8 = empty,     // Genesis: empty
mix_hash: Hash = ZERO,              // Genesis: 0x00..00 (prevRandao)
nonce: [8]u8 = zeros,               // Genesis: zeros
base_fee_per_gas: ?u256 = null,     // Genesis: 1_000_000_000 (1 gwei)
withdrawals_root: ?Hash = null,     // Genesis: null (not post-Shanghai for now)
```

Important constants:
- `EMPTY_OMMERS_HASH` = keccak256(RLP([])) = `0x1dcc4de8...`
- `EMPTY_TRANSACTIONS_ROOT` = keccak256 of empty MPT = `0x56e81f17...`
- `EMPTY_RECEIPTS_ROOT` = same as EMPTY_TRANSACTIONS_ROOT

#### BlockBody (`../voltaire/packages/voltaire-zig/src/primitives/BlockBody/BlockBody.zig`)

```zig
transactions: []const TransactionData = empty
ommers: []const UncleHeader = empty
withdrawals: ?[]const Withdrawal = null  // post-Shanghai
```

Constructors: `init()`, `postMerge()`, `postShanghai()`

#### Address (`../voltaire/packages/voltaire-zig/src/primitives/Address/address.zig`)

```zig
pub const Address = @This(); // struct with bytes: [20]u8
```

Key functions:
- `Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")` - Parse hex string (with/without 0x)
- `Address.ZERO_ADDRESS` / `Address.ZERO` - Zero address constant
- `Address.toU256(addr)` / `Address.fromU256(value)` - U256 conversion
- `address.format(...)` - std.fmt compatible formatting

### Crypto (`../voltaire/packages/voltaire-zig/src/crypto/`)

**Available (pure Zig)**:
- `bip39.zig` - Full BIP-39 mnemonic implementation
  - `mnemonicToSeed(words, passphrase, &seed)` - Mnemonic to 64-byte seed
  - `mnemonicStringToSeed(mnemonic_string, passphrase, &seed)` - String variant
  - `validateMnemonic(words)` - Checksum validation
  - `entropyToMnemonic(entropy, &indices)` - Entropy to word indices
  - `indicesToString(indices, &buf)` - Word indices to string
- `secp256k1.zig` - ECDSA operations
  - `recoverPubkey(hash, r, s, v)` - Public key recovery from signature
  - `unauditedRecoverAddress(hash, recoveryId, r, s)` - Address recovery
  - `verifySignature(hash, r, s, pub_key)` - Signature verification
- `signers.zig` - Key management
  - `LocalSigner.init(private_key)` - From 32-byte key, derives pubkey+address
  - `LocalSigner.fromHex(hex)` - From hex string (with/without 0x)
  - `LocalSigner.random()` - Generate random signer
  - `.address` field - Derived Ethereum address
  - `.signHash(hash)` / `.signMessage(message)` - Signing operations
  - `.deinit()` - Secure key cleanup
- `crypto.zig` - Low-level operations
  - `PrivateKey` = `[32]u8`
  - `PublicKey` struct with `.toAddress()` method
  - `unaudited_getPublicKey(private_key)` - Derive public key
  - `publicKeyToAddress(public_key)` - Derive address
  - `unaudited_randomPrivateKey()` - Generate random key
  - `unaudited_signHash(hash, private_key)` - RFC 6979 deterministic signing
  - `hashMessage(message)` - EIP-191 personal sign hash
  - `secureZeroMemory(&key)` - Secure cleanup

**NOT available in pure Zig**: BIP-32/BIP-44 HD key derivation
- `HDWallet/hdwallet.fuzz.zig` exists but is a FUZZ TEST SCAFFOLD ONLY (no actual implementation)
- It references a `HDWallet.fromSeed()`, `HDWallet.derivePath()` etc. that do NOT exist yet
- The actual HD derivation would require libwally-core C FFI (mentioned in comments)
- **Decision**: Hardcode the 10 well-known private keys. No runtime BIP-32 derivation needed.

---

## Upstream Dependencies (guillotine-mini)

### Architecture

Guillotine-mini is a **pure EVM library** - no RPC, no server. It provides:

### HostInterface (`../guillotine-mini/src/host.zig`)

Vtable-based interface for EVM state access:
```zig
pub const VTable = struct {
    getBalance: *const fn (*anyopaque, Address) u256,
    setBalance: *const fn (*anyopaque, Address, u256) void,
    getCode: *const fn (*anyopaque, Address) []const u8,
    setCode: *const fn (*anyopaque, Address, []const u8) void,
    getStorage: *const fn (*anyopaque, Address, u256) u256,
    setStorage: *const fn (*anyopaque, Address, u256, u256) void,
    getNonce: *const fn (*anyopaque, Address) u64,
    setNonce: *const fn (*anyopaque, Address, u64) void,
};
```

Already adapted in zevm via `HostAdapter` (`src/host_adapter.zig`).

### BlockContext (`../guillotine-mini/src/evm.zig`)

```zig
pub const BlockContext = struct {
    chain_id: u256,
    block_number: u64,
    block_timestamp: u64,
    block_difficulty: u256,
    block_prevrandao: u256,
    block_coinbase: primitives.Address,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,
    block_hashes: []const [32]u8 = &[_][32]u8{},
};
```

### EVM Initialization Pattern

```zig
const EvmType = guillotine_mini.Evm(.{});
var evm: EvmType = undefined;
evm.init(allocator, host_iface, hardfork, block_ctx, log_level);
evm.initTransactionState(blob_versioned_hashes);
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
- **BUG**: `syncCachedAccountsToTrie()` calls `self.state.accountIterator()` which does NOT exist in voltaire's StateManager. This will be a compile error if called.

### Other zevm modules
- `src/host_adapter.zig` - Adapts voltaire StateManager to guillotine-mini HostInterface
- `src/tx_processor.zig` - Transaction processing (intrinsic gas, nonce validation, EVM execution)
- `src/block_builder.zig` - Builds blocks from transaction lists
- `src/consensus_verifier.zig`, `src/beacon_api.zig`, `src/consensus_sync.zig`, `src/checkpoint.zig` - Consensus layer

### build.zig

zevm imports from voltaire: `primitives`, `state-manager`, `blockchain`, `crypto`, `precompiles`
zevm imports from guillotine-mini: `guillotine_mini` module

---

## Detailed Reference Implementation Notes

### Foundry Anvil (`foundry/crates/anvil/src/config.rs`, `lib.rs`)

- `DEFAULT_MNEMONIC = "test test test test test test test test test test test junk"` (line 84)
- `CHAIN_ID = 31337` (line 80)
- `DEFAULT_GAS_LIMIT = 30_000_000` (line 82)
- `INITIAL_BASE_FEE = 1_000_000_000` (1 gwei, in `fees.rs:25`)
- `INITIAL_GAS_PRICE = 1_875_000_000` (1.875 gwei, in `fees.rs:28`)
- 10 accounts, 100 ETH each, derivation path `m/44'/60'/0'/0/{i}`
- Default port: 8545
- Genesis timestamp: `duration_since_unix_epoch().as_secs()` (current time)
- Genesis block number: 0
- Startup sequence: generate accounts -> create NodeConfig -> setup backend -> create BlockEnv -> apply_genesis (fund accounts) -> deploy CREATE2 deployer -> print banner
- Banner format: ASCII art header + accounts table + private keys + wallet info + chain config

### Hardhat EDR (`edr/crates/edr_provider/src/config.rs`, `edr/crates/edr_defaults/src/lib.rs`)

- Does NOT use mnemonic derivation at runtime - uses 20 pre-generated SECRET_KEYS directly
- First key: `ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
- `DEV_CHAIN_ID = 31337`
- Default balance: 1000 ETH per account (from test config)
- Provider config struct stores `genesis_state: HashMap<Address, AccountOverride>` and `owned_accounts: Vec<SecretKey>`
- Coinbase: 0x0000000000000000000000000000000000000000

### TEVM (`../tevm-monorepo/packages/node/src/`)

- 10 prefunded accounts (+ zero address = 11 total genesis accounts)
- 1000 ETH per account
- Default chain ID: 900
- Genesis block: number=0, gasLimit=30_000_000n, stateRoot computed from genesis state
- Pre-deploys Multicall3 at `0xcA11bde05977b3631167028862bE2a173976CA11`
- Initialization: chain ID -> Common -> Blockchain -> StateManager (with genesis) -> EVM -> VM

---

## Implementation Plan

### 1. Hardcode Dev Accounts (in zevm, `src/genesis.zig`)

Create a constant table of 10 dev accounts with addresses and private keys as comptime-known byte arrays. No runtime BIP-32 derivation needed.

The addresses need to be constructed as `primitives.Address` with `.bytes` field. Private keys are `[32]u8`.

```zig
// Conceptual structure (use fully qualified types, no aliases)
pub const DEV_BALANCE: u256 = 10_000 * 1_000_000_000_000_000_000; // 10000 ETH in wei
pub const CHAIN_ID: u64 = 31337;
pub const DEFAULT_GAS_LIMIT: u64 = 30_000_000;
pub const DEFAULT_BASE_FEE: u256 = 1_000_000_000; // 1 gwei
pub const NUM_ACCOUNTS: usize = 10;
pub const MNEMONIC = "test test test test test test test test test test test junk";
pub const DERIVATION_PATH = "m/44'/60'/0'/0/";
```

### 2. Genesis Block Construction (in zevm)

Create a custom genesis block rather than using `Block.genesis()` directly, because we need to set `gas_limit`, `base_fee_per_gas`, and `timestamp`:

```zig
var header = primitives.BlockHeader.BlockHeader{
    .number = 0,
    .gas_limit = 30_000_000,
    .base_fee_per_gas = 1_000_000_000,  // 1 gwei
    .timestamp = @intCast(std.time.timestamp()),
    .beneficiary = DEV_ACCOUNTS[0].address,
    .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
    .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
    .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
    // parent_hash, difficulty, mix_hash all default to zero (correct for genesis)
};

const body = primitives.BlockBody.BlockBody.init();
const genesis_block = try primitives.Block.from(&header, &body, allocator);
```

### 3. Node Initialization Sequence (in zevm)

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

## Known Issues to Address

1. **`accountIterator()` missing**: `database.zig:56` calls `self.state.accountIterator()` which does not exist on voltaire's `StateManager`. Options:
   - Add `accountIterator()` to voltaire's JournaledState/StateManager (returns iterator over modified accounts)
   - Or track modified addresses separately in zevm's Database struct
   - Or remove `syncCachedAccountsToTrie()` and sync addresses explicitly

2. **`Block.genesis()` too minimal**: The existing `Block.genesis(chain_id, allocator)` doesn't set gas_limit, base_fee, timestamp. We must construct our own header. This is fine - no need to modify voltaire.

3. **Address construction from hex**: `Address.fromHex()` returns `!Address` (can fail). For comptime-known addresses, we should construct them directly from byte arrays to avoid runtime errors.

---

## Key Files to Modify/Create

### zevm (new/modified)
- `src/genesis.zig` (NEW) - Dev account constants, genesis block builder, node init, startup banner
- `src/main.zig` (MODIFY) - Wire genesis initialization into startup
- `src/database/database.zig` (MODIFY) - Potentially add `current_block_number` field
- `src/root.zig` (MODIFY) - Export genesis module

### voltaire (potential fix needed)
- `StateManager.zig` or `JournaledState.zig` - Add `accountIterator()` if zevm's `syncCachedAccountsToTrie` is needed. Alternatively, fix zevm to not need it.

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
COINBASE          = DEV_ACCOUNTS[0].address (0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
```

---

## Reference Files Read

### Voltaire (upstream, we own)
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` - State management with journaling and snapshots
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` - Block storage with fork cache support (527 lines + extensive tests)
- `../voltaire/packages/voltaire-zig/src/crypto/root.zig` - Crypto module index (bip39, secp256k1, signers, modexp, bn254, bls12_381, kzg)
- `../voltaire/packages/voltaire-zig/src/crypto/bip39.zig` - BIP-39 mnemonic to seed (full implementation with tests)
- `../voltaire/packages/voltaire-zig/src/crypto/secp256k1.zig` - ECDSA operations (AffinePoint, mulmod, signature recovery)
- `../voltaire/packages/voltaire-zig/src/crypto/signers.zig` - LocalSigner from private key (init, fromHex, random, signing)
- `../voltaire/packages/voltaire-zig/src/crypto/crypto.zig` - Core crypto (PrivateKey, PublicKey types, key derivation)
- `../voltaire/packages/voltaire-zig/src/crypto/HDWallet/hdwallet.fuzz.zig` - Fuzz test scaffold (NO actual HD derivation implementation)
- `../voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig` - Block struct, from(), genesis(), RLP encode, validation
- `../voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig` - BlockHeader struct, init(), genesis(), hash(), RLP encode/decode, validation
- `../voltaire/packages/voltaire-zig/src/primitives/Address/address.zig` - Address type with fromHex(), ZERO_ADDRESS, toU256()

### Guillotine-mini (upstream, we own)
- `../guillotine-mini/src/root.zig` - Module exports (Evm, HostInterface, BlockContext, CallParams, CallResult)
- `../guillotine-mini/src/host.zig` - HostInterface vtable definition
- `../guillotine-mini/src/evm.zig` - BlockContext struct, EVM initialization

### zevm (this repo)
- `src/main.zig` - Current stub (just prints "zevm - Ethereum local node")
- `src/root.zig` - Module exports (database, blockchain, host_adapter, tx_processor, block_builder, consensus modules)
- `src/database/database.zig` - Database wrapping StateManager + trie (has accountIterator bug)
- `src/database/accounts.zig` - Merkle Patricia Trie for accounts
- `src/database/block_hashes.zig` - Block number to hash mapping
- `src/database/contracts.zig` - Code hash to bytecode mapping
- `src/database/database_test.zig` - Existing database tests
- `src/host_adapter.zig` - StateManager to HostInterface adapter
- `src/block_builder.zig` - Transaction execution into blocks
- `src/tx_processor.zig` - Single transaction processing
- `build.zig` - Build configuration with voltaire + guillotine-mini deps

### Foundry Anvil (reference)
- `foundry/crates/anvil/src/config.rs` - DEFAULT_MNEMONIC, CHAIN_ID=31337, DEFAULT_GAS_LIMIT=30M, AccountGenerator with 10 accounts at 100 ETH, derivation path m/44'/60'/0'/0/{i}, startup banner format
- `foundry/crates/anvil/src/lib.rs` - Startup sequence, node initialization, genesis application
- `foundry/crates/anvil/src/eth/fees.rs` - INITIAL_BASE_FEE=1gwei, INITIAL_GAS_PRICE=1.875gwei

### Hardhat EDR (reference)
- `edr/crates/edr_provider/src/config.rs` - Provider config struct with genesis_state, owned_accounts, chain_id, coinbase
- `edr/crates/edr_defaults/src/lib.rs` - DEV_CHAIN_ID=31337, 20 SECRET_KEYS (pre-generated, no runtime derivation)
- `edr/crates/edr_napi_core/src/provider/config.rs` - NAPI config bridge

### TEVM (reference)
- `../tevm-monorepo/packages/node/src/createTevmNode.js` - Node creation with genesis state, chain ID resolution, state persistence
- `../tevm-monorepo/packages/node/src/GENESIS_STATE.js` - 10 prefunded accounts at 1000 ETH + Multicall3 predeploy
- `../tevm-monorepo/packages/utils/src/prefundedAccounts.ts` - Hardcoded addresses and private keys
- `../tevm-monorepo/packages/blockchain/src/createBaseChain.js` - Genesis block creation (number=0, gasLimit=30M)
