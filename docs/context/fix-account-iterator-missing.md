# Context: fix-account-iterator-missing

## Problem

`Database.syncCachedAccountsToTrie()` at `src/database/database.zig:55-60` calls `self.state.accountIterator()`, but `StateManager` in voltaire (`../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`) does not expose an `accountIterator()` method. This is blocking state root computation after block execution.

## Root Cause

The `StateManager` wraps `JournaledState`, which wraps `AccountCache` (a `std.AutoHashMap(Address, AccountState)`). The underlying data structure supports `.iterator()`, but no public method exposes it through the `StateManager` → `JournaledState` chain.

## Relevant Files

### zevm (this repo)
- `src/database/database.zig` — Lines 55-60: `syncCachedAccountsToTrie` calls the missing method; Lines 37-53: `syncAccountToTrie` works fine for single accounts
- `src/database/accounts.zig` — Merkle Patricia Trie wrapper for account state roots
- `src/database/database_test.zig` — Existing tests for accounts trie (all pass)
- `src/block_builder.zig` — Line 27 comment says caller should call `syncAccountToTrie` per modified address

### voltaire (upstream, we own it)
- `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` — Main API, missing `accountIterator()`
- `../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig` — Wraps `AccountCache`, no iterator exposed
- `../voltaire/packages/voltaire-zig/src/state-manager/StateCache.zig` — `AccountCache` has `cache: std.AutoHashMap(Address, AccountState)` which supports `.iterator()`
- `../voltaire/packages/voltaire-zig/src/state-manager/root.zig` — Re-exports; no iterator type exported

## Solution Options

### Option A: Add `accountIterator()` to StateManager (recommended)

Add an iterator method that delegates through the chain:

1. **StateManager** → add `accountIterator()` that returns `self.journaled_state.account_cache.cache.iterator()`
2. Return type: `std.AutoHashMap(primitives.Address, StateCache.AccountState).Iterator`

This is a 1-line method on StateManager. No changes needed on JournaledState since `account_cache` is already a public field.

### Option B: Track dirty addresses in Database

Instead of iterating all accounts, track which addresses were modified during block execution and only sync those. This is what the block builder comment already suggests (line 27).

- Pros: More efficient — only syncs modified accounts, not entire cache
- Cons: Requires threading dirty-address tracking through tx processing

### Option C: Expose cache directly (not recommended)

Access `self.state.journaled_state.account_cache.cache.iterator()` directly from Database. Violates encapsulation.

## Recommended Approach

**Do both Option A and Option B:**

1. **Short-term (Option A):** Add `accountIterator()` to `StateManager` in voltaire. This is a trivial 1-method addition that unblocks `syncCachedAccountsToTrie`.

2. **Long-term (Option B):** The block builder should track which addresses were touched during execution and pass them to `syncAccountToTrie` individually. This avoids iterating the entire account cache (which includes fork-fetched accounts that haven't changed).

## Reference Implementation Patterns

### EDR (Rust) — Commit-based dirty tracking
- `edr/crates/state/persistent_trie/src/state.rs:51-73` — `commit()` receives a `HashMap<Address, Account>` of changes from revm, iterates only touched accounts, and updates the trie per-account.
- Pattern: The execution engine returns a changeset; the trie layer receives only dirty accounts.

### Foundry Anvil (Rust) — Full iteration on demand
- `foundry/crates/anvil/src/eth/backend/mem/state.rs:20-55` — `state_root()` iterates over `AddressMap<DbAccount>` (all accounts in the DB), hashes each address with keccak256, RLP-encodes `(nonce, balance, storage_root, code_hash)`, and builds a trie from scratch.
- Pattern: Simple but O(n) over all accounts; acceptable for dev node.

### Ethereum Execution Specs (Python)
- `execution-specs/src/ethereum/forks/byzantium/state.py:298-318` — `state_root()` iterates over entire state trie.
- Account encoding: `(nonce, balance, storage_root, code_hash)` RLP tuple.
- Keys are `keccak256(address)` (secure trie).

## Implementation Notes

- The `AccountCache.cache` field is `std.AutoHashMap(Address, AccountState)` — its `.iterator()` returns entries with `.key_ptr.*` (Address) and `.value_ptr.*` (AccountState).
- The `JournaledState.account_cache` field is public, so StateManager can access it as `self.journaled_state.account_cache`.
- Per project style: no local type aliases, no stored allocators, use fully qualified paths.
- The iterator approach matches foundry's pattern (iterate all, build root) which is acceptable for a dev node.
