// Map focus IDs to hint directories for the reviewer
// Already implemented: consensus light client, tx processing, block building, state management, host adapter
export const focusDirs: Record<string, string[]> = {
  // --- Implementation focuses ---
  "cat-1-rpc-server": [
    "src/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/",
    "../bench/guillotine-mini/client/rpc/",
    "edr/crates/edr_provider/src/requests/",
  ],
  "cat-2-eth-read": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/",
    "../voltaire/packages/voltaire-zig/src/state-manager/",
    "edr/crates/edr_provider/src/requests/eth/",
    "../tevm-monorepo/packages/actions/src/eth/",
  ],
  "cat-3-eth-call": [
    "src/tx_processor.zig",
    "src/host_adapter.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/call/",
    "edr/crates/edr_provider/src/requests/eth/call.rs",
    "../tevm-monorepo/packages/actions/src/Call/",
  ],
  "cat-4-eth-send": [
    "src/tx_processor.zig",
    "src/block_builder.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/send_raw_transaction/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/send_transaction/",
    "edr/crates/edr_provider/src/requests/eth/send_transaction.rs",
    "../tevm-monorepo/packages/actions/src/eth/ethSendTransactionHandler.js",
  ],
  "cat-5-block-queries": [
    "src/database/",
    "src/block_builder.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_block_by_number/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_transaction_receipt/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_logs/",
    "../voltaire/packages/voltaire-zig/src/blockchain/",
    "edr/crates/edr_provider/src/requests/eth/",
  ],
  "cat-6-mining": [
    "src/block_builder.zig",
    "src/tx_processor.zig",
    "edr/crates/edr_provider/src/requests/eth/mine.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilMineHandler.js",
  ],
  "cat-7-snapshots": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig",
    "../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig",
    "edr/crates/edr_provider/src/requests/eth/evm_snapshot.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilSnapshotHandler.js",
  ],
  "cat-8-state-manip": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig",
    "edr/crates/edr_provider/src/requests/hardhat/",
    "../tevm-monorepo/packages/actions/src/anvil/anvilSetBalanceHandler.js",
    "../tevm-monorepo/packages/actions/src/SetAccount/",
  ],
  "cat-9-impersonation": [
    "src/tx_processor.zig",
    "edr/crates/edr_provider/src/requests/hardhat/impersonate_account.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilImpersonateAccountHandler.js",
  ],
  "cat-10-forking": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/state-manager/ForkBackend.zig",
    "../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig",
    "../voltaire/packages/voltaire-zig/src/blockchain/ForkBlockCache.zig",
    "edr/crates/edr_provider/src/",
    "../tevm-monorepo/packages/actions/src/",
  ],
  "cat-11-tracing": [
    "src/tx_processor.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/debug/",
    "../voltaire/packages/voltaire-zig/src/evm/evm.zig",
    "../bench/guillotine-mini/client/rpc/",
    "edr/crates/edr_provider/src/requests/debug.rs",
    "../tevm-monorepo/packages/actions/src/debug/",
  ],
  "cat-12-filters": [
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/new_filter/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_filter_changes/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_logs/",
    "edr/crates/edr_provider/src/requests/eth/",
    "../tevm-monorepo/packages/actions/src/eth/ethNewFilterHandler.js",
  ],
  "cat-13-time": [
    "src/block_builder.zig",
    "edr/crates/edr_provider/src/requests/eth/evm_increase_time.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilIncreaseTimeHandler.js",
    "../tevm-monorepo/packages/actions/src/anvil/anvilSetNextBlockTimestampHandler.js",
  ],

  // --- Test suite focuses ---
  "test-rlp": [
    "ethereum-tests/RLPTests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
    "execution-specs/src/ethereum/rlp.py",
  ],
  "test-trie": [
    "ethereum-tests/TrieTests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
    "src/database/accounts.zig",
    "execution-specs/src/ethereum/frontier/trie.py",
  ],
  "test-transaction": [
    "ethereum-tests/TransactionTests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
    "src/tx_processor.zig",
    "execution-specs/src/ethereum/frontier/transactions.py",
  ],
  "test-blockchain": [
    "ethereum-tests/BlockchainTests/",
    "src/block_builder.zig",
    "src/tx_processor.zig",
    "src/database/",
    "execution-specs/src/ethereum/frontier/fork.py",
  ],
  "test-difficulty": [
    "ethereum-tests/DifficultyTests/",
    "execution-specs/src/ethereum/frontier/fork.py",
    "yellowpaper/",
  ],
  "test-abi": [
    "ethereum-tests/ABITests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
  ],
  "test-eof": [
    "ethereum-tests/EOFTests/",
    "EIPs/EIPS/eip-3670.md",
    "../bench/guillotine-mini/src/",
  ],
  "test-state-frontier": [
    "execution-spec-tests/tests/frontier/",
    "execution-spec-tests/tests/homestead/",
    "execution-spec-tests/tests/byzantium/",
    "execution-spec-tests/tests/constantinople/",
    "execution-spec-tests/tests/istanbul/",
    "execution-specs/src/ethereum/",
  ],
  "test-state-berlin": [
    "execution-spec-tests/tests/berlin/",
    "execution-spec-tests/tests/shanghai/",
    "execution-specs/src/ethereum/",
  ],
  "test-state-cancun": [
    "execution-spec-tests/tests/cancun/",
    "execution-spec-tests/tests/prague/",
    "execution-specs/src/ethereum/",
  ],
  "test-hive-rpc": [
    "hive/simulators/ethereum/",
    "execution-apis/",
    "src/",
  ],
};
