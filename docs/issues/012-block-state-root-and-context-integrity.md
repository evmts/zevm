# Block State Root And Context Integrity

> **Archived / non-normative:** This issue is historical context only. Claims below are filing-time observations and may contradict current contract docs. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md); if anything differs, those normative docs win.
>
> **Resolved / superseded status:** This issue is closed as an active gap tracker and retained for archive history only. For current requirements and behavior, use [docs/specs/prd.md](../specs/prd.md), [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md), and [docs/specs/page-ownership.md](../specs/page-ownership.md).


## Historical Gap Snapshot At Filing Time

- `initGenesis` funds dev accounts in `db.state` and stores a genesis block without flushing accounts into the trie or setting `header.state_root`, so the stored genesis header is already inconsistent with funded state.
- `buildBlock` does not construct a header or compute/persist a block `stateRoot`; it only returns receipts, gas used, and block number.
- `Database.syncAccountToTrie` computes account trie entries from balance, nonce, and code hash only; it never propagates `storage_root`, so storage writes are invisible to derived account state.
- `Contracts` exists as a code-hash registry but is not integrated into syncing, execution, or normal code reads.
- `BlockHashes` is only written at genesis, and the mining path never feeds recent hashes into `guillotine-mini.BlockContext.block_hashes`.
- The helper mining path also hardcodes `base_fee`, `blob_base_fee`, and `prevrandao` to zero.

## Evidence

- `src/genesis.zig`
- `src/database/database.zig`
- `src/database/contracts.zig`
- `src/database/block_hashes.zig`
- `src/block_builder.zig`
- `src/mining_coordinator.zig`
- `../guillotine-mini/src/evm.zig`
- `../guillotine-mini/src/instructions/handlers_block.zig`

## Historical Resolution Criteria

- Every sealed block computes and persists a correct `stateRoot` from the post-state trie.
- Storage writes update the account trie through a real storage-root pipeline.
- Contract bytecode is stored and deduplicated consistently, and account `code_hash` resolves to retrievable code.
- Canonical block hashes are recorded and exposed to EVM `BLOCKHASH` exactly as expected.
- State-root, code-hash, and block-hash integrity remain correct across mining, snapshot/revert, and fork mode.
