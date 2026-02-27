# Plan: genesis-state-and-dev-accounts — Genesis State Initialization with Dev Accounts

## Overview

Implement genesis state initialization that pre-funds 10 dev accounts and creates a genesis block (block 0) — the foundation all RPC handlers depend on. Without this, `eth_getBalance` returns 0, `eth_blockNumber` returns nothing, and `eth_accounts` returns empty.

**Approach**: Create `src/genesis.zig` with:
1. Hardcoded dev account constants (10 addresses + private keys from the standard Hardhat/Anvil mnemonic)
2. A `GenesisConfig` struct holding chain parameters (chain_id, gas_limit, base_fee, etc.)
3. An `initGenesis()` function that funds accounts via voltaire's `StateManager.setBalance()`, builds a genesis block via `primitives.Block.from()`, stores it in voltaire's `Blockchain` via `putBlock()` + `setCanonicalHead()`, and records the genesis hash in `Database.block_hashes`
4. A `printBanner()` function that outputs the Hardhat/Anvil-style startup banner

**Key decisions**:
- Hardcode the 10 well-known private keys (no BIP-32/44 HD derivation — voltaire lacks it and all reference implementations hardcode anyway)
- Use 10,000 ETH per account (matches Hardhat default)
- Construct custom genesis header (voltaire's `Block.genesis()` is too minimal — missing gas_limit, base_fee, timestamp)
- Fix the `syncCachedAccountsToTrie` bug in `database.zig` (calls non-existent `accountIterator()`)

**Upstream dependencies used** (all from voltaire, nothing new needed):
- `StateManager.setBalance(address, balance)` — fund accounts
- `Blockchain.putBlock(block)` / `setCanonicalHead(hash)` — store genesis block
- `Block.from(&header, &body, allocator)` — build block with computed hash
- `crypto.signers.LocalSigner.fromHex(hex)` — verify private key → address derivation in tests
- `Address.fromHex(hex)` — parse hex addresses

## Files to Create/Modify

### New Files
- **`src/genesis.zig`** — Dev account constants, genesis config, `initGenesis()`, `printBanner()`
- **`src/genesis_test.zig`** — All unit + integration tests for genesis

### Modified Files
- **`src/root.zig`** — Export `genesis` module, add `genesis_test.zig` to test block
- **`src/database/database.zig`** — Remove broken `syncCachedAccountsToTrie` (calls non-existent `accountIterator()`), keep working `syncAccountToTrie`
- **`src/main.zig`** — Wire genesis initialization into startup

## TDD Step Order

### Step 1: Write genesis_test.zig — Dev Account Constants Tests

**File**: `src/genesis_test.zig`

Tests to write (all will fail initially — `genesis.zig` doesn't exist yet):

```zig
test "DEV_ACCOUNTS has exactly 10 entries"
// genesis.DEV_ACCOUNTS.len == 10

test "DEV_ACCOUNTS[0] address matches well-known Hardhat account 0"
// genesis.DEV_ACCOUNTS[0].address bytes match 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

test "DEV_ACCOUNTS[0] private key matches well-known Hardhat key 0"
// genesis.DEV_ACCOUNTS[0].private_key bytes match 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

test "all DEV_ACCOUNTS have unique addresses"
// no duplicates in the 10 addresses

test "private keys derive to correct addresses"
// For each account, use crypto.signers.LocalSigner.fromHex(private_key) and verify .address matches
// This validates our hardcoded addresses are consistent with the private keys
```

### Step 2: Write genesis_test.zig — Genesis Config Constants Tests

```zig
test "CHAIN_ID is 31337"
// genesis.CHAIN_ID == 31337

test "DEV_BALANCE is 10000 ETH in wei"
// genesis.DEV_BALANCE == 10_000 * 1_000_000_000_000_000_000

test "DEFAULT_GAS_LIMIT is 30 million"
// genesis.DEFAULT_GAS_LIMIT == 30_000_000

test "DEFAULT_BASE_FEE is 1 gwei"
// genesis.DEFAULT_BASE_FEE == 1_000_000_000
```

### Step 3: Implement genesis.zig — Constants Only

**File**: `src/genesis.zig`

Implement:
- `pub const CHAIN_ID: u64 = 31337;`
- `pub const DEV_BALANCE: u256 = 10_000 * 1_000_000_000_000_000_000;` (10,000 ETH)
- `pub const DEFAULT_GAS_LIMIT: u64 = 30_000_000;`
- `pub const DEFAULT_BASE_FEE: u256 = 1_000_000_000;` (1 gwei)
- `pub const NUM_ACCOUNTS: usize = 10;`
- `pub const MNEMONIC = "test test test test test test test test test test test junk";`
- `pub const DERIVATION_PATH = "m/44'/60'/0'/0/";`

Dev account struct and array:
```zig
pub const DevAccount = struct {
    address: primitives.Address,
    private_key: [32]u8,
};

pub const DEV_ACCOUNTS: [10]DevAccount = .{ ... };
```

Addresses constructed via comptime byte arrays (not runtime `fromHex`), e.g.:
```zig
.{
    .address = .{ .bytes = .{ 0xf3, 0x9f, 0xd6, 0xe5, 0x1a, 0xad, 0x88, 0xf6, 0xf4, 0xce, 0x6a, 0xb8, 0x82, 0x72, 0x79, 0xcf, 0xff, 0xb9, 0x22, 0x66 } },
    .private_key = .{ 0xac, 0x09, 0x74, ... },
},
```

**Update `src/root.zig`**: Add `pub const genesis = @import("genesis.zig");` and `_ = @import("genesis_test.zig");` to test block.

**Verify**: Steps 1+2 tests pass. Run `zig build test`.

### Step 4: Write genesis_test.zig — Genesis Block Construction Tests

```zig
test "createGenesisBlock returns block with number 0"
// const block = try genesis.createGenesisBlock(allocator);
// block.header.number == 0

test "createGenesisBlock has correct gas limit"
// block.header.gas_limit == 30_000_000

test "createGenesisBlock has correct base fee"
// block.header.base_fee_per_gas.? == 1_000_000_000

test "createGenesisBlock has zero parent hash"
// block.header.parent_hash == all zeros

test "createGenesisBlock has zero difficulty"
// block.header.difficulty == 0

test "createGenesisBlock has beneficiary set to account 0"
// block.header.beneficiary bytes == DEV_ACCOUNTS[0].address bytes

test "createGenesisBlock has empty transactions root"
// block.header.transactions_root == BlockHeader.EMPTY_TRANSACTIONS_ROOT

test "createGenesisBlock has empty ommers hash"
// block.header.ommers_hash == BlockHeader.EMPTY_OMMERS_HASH

test "createGenesisBlock has non-zero hash"
// block.hash is not all zeros (RLP-computed)

test "createGenesisBlock has non-zero timestamp"
// block.header.timestamp > 0 (uses current time)

test "createGenesisBlock has empty body"
// block.body.transactions.len == 0
// block.body.ommers.len == 0
```

### Step 5: Implement genesis.zig — createGenesisBlock

```zig
pub fn createGenesisBlock(allocator: std.mem.Allocator) !primitives.Block.Block {
    const header = primitives.BlockHeader.BlockHeader{
        .number = 0,
        .gas_limit = DEFAULT_GAS_LIMIT,
        .base_fee_per_gas = DEFAULT_BASE_FEE,
        .timestamp = @intCast(std.time.timestamp()),
        .beneficiary = DEV_ACCOUNTS[0].address,
        .difficulty = 0,
        .ommers_hash = primitives.BlockHeader.BlockHeader.EMPTY_OMMERS_HASH,
        .transactions_root = primitives.BlockHeader.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.BlockHeader.EMPTY_RECEIPTS_ROOT,
        // parent_hash defaults to ZERO, mix_hash defaults to ZERO — correct for genesis
    };
    const body = primitives.BlockBody.BlockBody.init();
    return primitives.Block.Block.from(&header, &body, allocator);
}
```

**Verify**: Step 4 tests pass. Run `zig build test`.

### Step 6: Write genesis_test.zig — State Initialization Tests

```zig
test "initGenesisState funds all 10 dev accounts"
// var db = try Database.init(allocator);
// try genesis.initGenesisState(&db.state);
// For each DEV_ACCOUNTS[i]:
//   balance = try db.state.getBalance(account.address);
//   expect(balance == DEV_BALANCE);

test "initGenesisState sets nonce 0 for all dev accounts"
// var db = try Database.init(allocator);
// try genesis.initGenesisState(&db.state);
// For each DEV_ACCOUNTS[i]:
//   nonce = try db.state.getNonce(account.address);
//   expect(nonce == 0);

test "initGenesisState does not affect non-dev addresses"
// var db = try Database.init(allocator);
// try genesis.initGenesisState(&db.state);
// random_addr = Address.fromHex("0x0000000000000000000000000000000000000001");
// balance = try db.state.getBalance(random_addr);
// expect(balance == 0);
```

### Step 7: Implement genesis.zig — initGenesisState

```zig
pub fn initGenesisState(state: *state_manager.StateManager) !void {
    for (DEV_ACCOUNTS) |account| {
        try state.setBalance(account.address, DEV_BALANCE);
    }
}
```

**Verify**: Step 6 tests pass. Run `zig build test`.

### Step 8: Write genesis_test.zig — Full Node Init Integration Tests

```zig
test "initGenesis stores genesis block in blockchain"
// var blockchain = try Blockchain.init(allocator, null);
// var db = try Database.init(allocator);
// const result = try genesis.initGenesis(allocator, &db, &blockchain);
// const head = blockchain.getHeadBlockNumber();
// expect(head != null);
// expect(head.? == 0);

test "initGenesis records genesis hash in block_hashes"
// var blockchain = try Blockchain.init(allocator, null);
// var db = try Database.init(allocator);
// const result = try genesis.initGenesis(allocator, &db, &blockchain);
// const hash = db.block_hashes.get(0);
// expect(hash != null);
// expect(hash.? == result.genesis_hash);

test "initGenesis returns correct chain_id"
// result.chain_id == 31337

test "initGenesis returns genesis hash"
// result.genesis_hash is not all zeros

test "initGenesis returns all 10 managed accounts"
// result.managed_accounts.len == 10
// result.managed_accounts[0].address == DEV_ACCOUNTS[0].address

test "initGenesis returns coinbase as first dev account"
// result.coinbase == DEV_ACCOUNTS[0].address

test "initGenesis balances are queryable after init"
// For each DEV_ACCOUNTS[i]:
//   balance = try db.state.getBalance(account.address);
//   expect(balance == DEV_BALANCE);

test "initGenesis genesis block retrievable by hash from blockchain"
// const block = try blockchain.getBlockByHash(result.genesis_hash);
// expect(block != null);
// expect(block.?.header.number == 0);

test "initGenesis genesis block retrievable by number from blockchain"
// const block = try blockchain.getBlockByNumber(0);
// expect(block != null);
// expect(block.?.header.number == 0);
```

### Step 9: Implement genesis.zig — initGenesis (Full Initialization)

```zig
pub const GenesisResult = struct {
    chain_id: u64,
    genesis_hash: primitives.Hash.Hash,
    coinbase: primitives.Address,
    managed_accounts: []const DevAccount,
};

pub fn initGenesis(
    allocator: std.mem.Allocator,
    db: *database.Database,
    blockchain: *blockchain_mod.Blockchain,
) !GenesisResult {
    // 1. Fund all dev accounts
    try initGenesisState(&db.state);

    // 2. Create genesis block
    const genesis_block = try createGenesisBlock(allocator);

    // 3. Store in blockchain
    try blockchain.putBlock(genesis_block);
    try blockchain.setCanonicalHead(genesis_block.hash);

    // 4. Record hash in block_hashes (for BLOCKHASH opcode)
    try db.block_hashes.put(allocator, 0, genesis_block.hash);

    return .{
        .chain_id = CHAIN_ID,
        .genesis_hash = genesis_block.hash,
        .coinbase = DEV_ACCOUNTS[0].address,
        .managed_accounts = &DEV_ACCOUNTS,
    };
}
```

**Verify**: Step 8 tests pass. Run `zig build test`.

### Step 10: Write genesis_test.zig — Banner Output Test

```zig
test "printBanner writes account addresses and private keys"
// Capture output via ArrayList writer
// var buf = std.ArrayList(u8).init(allocator);
// try genesis.printBanner(buf.writer());
// const output = buf.items;
// expect(std.mem.indexOf(u8, output, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266") != null);
// expect(std.mem.indexOf(u8, output, "10000 ETH") != null);
// expect(std.mem.indexOf(u8, output, "31337") != null);
// expect(std.mem.indexOf(u8, output, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") != null);
// expect(std.mem.indexOf(u8, output, "Available Accounts") != null);
// expect(std.mem.indexOf(u8, output, "Private Keys") != null);
```

### Step 11: Implement genesis.zig — printBanner

```zig
pub fn printBanner(writer: anytype) !void {
    try writer.writeAll("\nzevm - Ethereum local node\n");
    try writer.print("Chain ID: {d}\n\n", .{CHAIN_ID});
    try writer.writeAll("Available Accounts\n==================\n");
    for (DEV_ACCOUNTS, 0..) |account, i| {
        // Format: (0) 0xf39F...2266 (10000 ETH)
        try writer.print("({d}) 0x{} (10000 ETH)\n", .{ i, std.fmt.fmtSliceHexLower(&account.address.bytes) });
    }
    try writer.writeAll("\nPrivate Keys\n==================\n");
    for (DEV_ACCOUNTS, 0..) |account, i| {
        try writer.print("({d}) 0x{}\n", .{ i, std.fmt.fmtSliceHexLower(&account.private_key) });
    }
    try writer.print("\nWallet\n==================\nMnemonic: {s}\nDerivation path: {s}\n", .{ MNEMONIC, DERIVATION_PATH });
    try writer.print("\nBase Fee: {d} (1 gwei)\nGas Limit: {d}\n\n", .{ @as(u64, @intCast(DEFAULT_BASE_FEE)), DEFAULT_GAS_LIMIT });
}
```

**Verify**: Step 10 test passes. Run `zig build test`.

### Step 12: Fix database.zig — Remove Broken syncCachedAccountsToTrie

**File**: `src/database/database.zig`

Remove `syncCachedAccountsToTrie` method entirely. It calls `self.state.accountIterator()` which doesn't exist in voltaire's `StateManager`. The working `syncAccountToTrie(address)` method remains — callers should track dirty addresses and sync them explicitly.

**Verify**: Existing database tests still pass. Run `zig build test`.

### Step 13: Wire genesis into main.zig

**File**: `src/main.zig`

```zig
const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize database (StateManager + trie + block_hashes)
    var db = try zevm.database.Database.init(allocator);
    defer db.deinit(allocator);

    // Initialize blockchain
    var blockchain = try zevm.blockchain.Blockchain.init(allocator, null);
    defer blockchain.deinit();

    // Initialize genesis state + block
    const result = try zevm.genesis.initGenesis(allocator, &db, &blockchain);
    _ = result;

    // Print startup banner
    const stdout = std.io.getStdOut().writer();
    try zevm.genesis.printBanner(stdout);
}
```

**Verify**: `zig build run` prints the banner with all 10 accounts. `zig build test` still passes.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `Block.from()` computes hash via RLP — if BlockHeader field ordering changes upstream, hash changes | Genesis hash would differ from Hardhat/Anvil | Accept: genesis hash doesn't need to match other implementations since we're an independent chain |
| `Blockchain.putBlock()` may validate more than parent linkage in future | Genesis init could break | Low risk: voltaire tests already cover genesis block storage; block number 0 is special-cased |
| `syncCachedAccountsToTrie` removal breaks downstream code | Compile errors | No downstream callers exist yet — only the broken method itself references `accountIterator()` |
| Comptime address bytes could have typos | Wrong accounts funded | Test in Step 1 verifies private key → address derivation via `LocalSigner.fromHex()` |
| `std.time.timestamp()` may not be available on all targets | Genesis block fails | Use `@intCast(std.time.timestamp())` — works on all supported host targets |
| 3 pre-existing test failures (tx_processor, consensus_verifier) | `zig build test` reports failures | These are pre-existing and unrelated to genesis. Document them but don't block on fixing. |

## Verification Against Acceptance Criteria

| # | Criterion | How Verified |
|---|-----------|-------------|
| 1 | 10 dev accounts generated from standard mnemonic | Test: `DEV_ACCOUNTS has exactly 10 entries` + `private keys derive to correct addresses` |
| 2 | Each account pre-funded with 10000 ETH | Test: `initGenesisState funds all 10 dev accounts` (checks balance == 10000 ETH) |
| 3 | Private keys stored for transaction signing | Test: `DEV_ACCOUNTS[0] private key matches well-known Hardhat key 0` + all 10 keys in constant array |
| 4 | Genesis block (block 0) created with correct header fields | Tests: `createGenesisBlock returns block with number 0`, gas_limit, base_fee, parent_hash, difficulty, beneficiary, timestamps, roots |
| 5 | Genesis block stored in voltaire Blockchain as canonical head | Test: `initGenesis stores genesis block in blockchain` (checks `getHeadBlockNumber() == 0`) |
| 6 | StateManager initialized with genesis account balances | Test: `initGenesis balances are queryable after init` |
| 7 | NodeConfig initialized with chain_id=31337, coinbase=account[0], managed_accounts=all 10 | Tests: `initGenesis returns correct chain_id`, `returns coinbase as first dev account`, `returns all 10 managed accounts` |
| 8 | Startup banner prints account addresses and private keys | Test: `printBanner writes account addresses and private keys` (checks for address strings, key strings, "Available Accounts", "Private Keys") |
| 9 | eth_getBalance for dev accounts returns 10000 ETH after genesis | Covered by criterion #6 — StateManager is the backing store for eth_getBalance RPC handler |
| 10 | eth_blockNumber returns 0x0 after genesis | Covered by criterion #5 — `getHeadBlockNumber() == 0` is the backing query for eth_blockNumber |
| 11 | eth_accounts returns all 10 dev account addresses | Covered by criterion #7 — `managed_accounts` array is the backing data for eth_accounts |
| 12 | eth_chainId returns 0x7a69 (31337) | Covered by criterion #7 — `chain_id == 31337` (0x7a69) in GenesisResult |
| 13 | zig build test passes | Run `zig build test` after each step; all new tests pass (pre-existing failures are unrelated) |

## Summary of Implementation Order

1. **Write tests** for dev account constants (Step 1-2)
2. **Implement** constants in `genesis.zig` (Step 3) — tests pass ✓
3. **Write tests** for genesis block construction (Step 4)
4. **Implement** `createGenesisBlock()` (Step 5) — tests pass ✓
5. **Write tests** for state initialization (Step 6)
6. **Implement** `initGenesisState()` (Step 7) — tests pass ✓
7. **Write tests** for full integration (Step 8)
8. **Implement** `initGenesis()` returning `GenesisResult` (Step 9) — tests pass ✓
9. **Write tests** for banner output (Step 10)
10. **Implement** `printBanner()` (Step 11) — tests pass ✓
11. **Fix** `database.zig` broken method (Step 12) — existing tests still pass ✓
12. **Wire** into `main.zig` (Step 13) — `zig build run` prints banner ✓
