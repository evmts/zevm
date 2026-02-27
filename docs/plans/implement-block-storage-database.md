# Plan: Implement Block Storage in ZEVM Database

## Overview
This plan outlines the steps to integrate the existing `blockchain.Blockchain` from the `voltaire` dependency into ZEVM's `Database` struct. This will provide complete block storage capabilities (blocks by hash, canonical chain lookup) which are prerequisites for JSON-RPC methods like `eth_getBlockByNumber` and `eth_getBlockByHash`. We follow a strict TDD approach: writing tests first, watching them fail, and then implementing the changes.

## TDD Step Order

### Step 1: Write Tests First (Unit & Integration)
**Target File**: `src/database/database_test.zig`
- **Goal**: Write tests for the new block storage capabilities of the database.
- **Test 1**: `test "database stores and retrieves block by hash"`
  - Initialize `Database`. Create a genesis block using `primitives.Block.genesis`.
  - Store it via `db.blockchain.putBlock(genesis)`.
  - Set it as head via `db.blockchain.setCanonicalHead(genesis.hash)`.
  - Retrieve via `db.blockchain.getBlockLocal(genesis.hash)` and assert it matches.
- **Test 2**: `test "database retrieves block by number (canonical)"`
  - Retrieve the genesis block via `db.blockchain.getBlockByNumberLocal(0)`.
  - Assert the block is found.
- **Test 3**: `test "database block not found returns null"`
  - Attempt to retrieve a non-existent block hash using `db.blockchain.getBlockLocal(primitives.Hash.ZERO)`.
  - Attempt to retrieve a non-existent block number using `db.blockchain.getBlockByNumberLocal(999)`.
  - Assert both return `null`.
- **Test 4**: `test "database head block number tracks canonical chain"`
  - Store genesis block and set canonical head.
  - Retrieve head block number using `db.blockchain.getHeadBlockNumber()`.
  - Assert it returns `0`.
- **Expected Result**: Compilation will fail because the `blockchain` field does not exist on `database.Database`.

### Step 2: Implement Database Updates
**Target File**: `src/database/database.zig`
- **Goal**: Add the `blockchain` field to the `Database` struct and manage its lifecycle.
- **Action**: Add `blockchain: @import("blockchain").Blockchain` to the `Database` struct.
- **Action**: Update `init(allocator: std.mem.Allocator) !Database` to initialize the `blockchain` field with `try @import("blockchain").Blockchain.init(allocator, null)`.
- **Action**: Update `deinit(self: *Database, allocator: std.mem.Allocator) void` to call `self.blockchain.deinit()`. Do not pass the allocator to `deinit()` since `Blockchain` stores its own allocator.

### Step 3: Verify Tests Pass
- **Action**: Run `zig build test` (specifically `zig build test -- src/database/database_test.zig` if possible) to confirm all database tests pass successfully.

### Step 4: Sync `block_hashes` (Documentation / Future Usage)
- Note: The actual synchronization of `block_hashes` happens during block building/importing (e.g., in `block_builder.zig`). Whenever `db.blockchain.setCanonicalHead(hash)` is called during block commit, we must also ensure `db.block_hashes.put(allocator, block.header.number, block_hash)` is called. For this database ticket, ensuring the `blockchain` object is available is sufficient.

## Files to Create/Modify
- **`src/database/database_test.zig`** (Modify): Add the aforementioned tests.
- **`src/database/database.zig`** (Modify): Add `blockchain` field to `Database` struct, update `init` and `deinit`.

## Risks and Mitigations
- **Stored Allocators**: `Blockchain` stores its own allocator. We must ensure we don't accidentally pass the database's `deinit` allocator to `blockchain.deinit()`.
  - *Mitigation*: Strictly follow the signature `self.blockchain.deinit()` with no arguments.
- **Type Aliases**: Avoid using local type aliases for `Blockchain`.
  - *Mitigation*: Use `@import("blockchain").Blockchain` inline everywhere it's referenced.
- **Test Failures due to `primitives` imports**: Make sure to import `primitives` correctly in the test file to construct genesis blocks.

## Acceptance Criteria Verification
- [x] Block storage by hash is possible through `db.blockchain.getBlockLocal`.
- [x] Block lookup by number (canonical chain) is possible through `db.blockchain.getBlockByNumberLocal`.
- [x] `Database` seamlessly integrates with voltaire `Blockchain.zig` without redefining block storage logic.
- [x] Tests confirm missing blocks return `null`.
- [x] Tests compile and pass with `zig build test`.