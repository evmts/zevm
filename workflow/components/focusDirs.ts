// Map focus IDs to hint directories for the reviewer
// Already implemented: consensus light client, tx processing, block building, state management, host adapter
export const focusDirs: Record<string, string[]> = {
  // --- Implementation focuses ---
  "cat-1-rpc-server": [
    "src/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/",
    "../bench/guillotine-mini/client/rpc/",
    "lib/edr/crates/edr_provider/src/requests/",
  ],
  "cat-2-eth-read": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/",
    "../voltaire/packages/voltaire-zig/src/state-manager/",
    "lib/edr/crates/edr_provider/src/requests/eth/",
    "../tevm-monorepo/packages/actions/src/eth/",
  ],
  "cat-3-eth-call": [
    "src/tx_processor.zig",
    "src/host_adapter.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/call/",
    "lib/edr/crates/edr_provider/src/requests/eth/call.rs",
    "../tevm-monorepo/packages/actions/src/Call/",
  ],
  "cat-4-eth-send": [
    "src/tx_processor.zig",
    "src/block_builder.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/send_raw_transaction/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/send_transaction/",
    "lib/edr/crates/edr_provider/src/requests/eth/send_transaction.rs",
    "../tevm-monorepo/packages/actions/src/eth/ethSendTransactionHandler.js",
  ],
  "cat-5-block-queries": [
    "src/database/",
    "src/block_builder.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_block_by_number/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_transaction_receipt/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_logs/",
    "../voltaire/packages/voltaire-zig/src/blockchain/",
    "lib/edr/crates/edr_provider/src/requests/eth/",
  ],
  "cat-6-mining": [
    "src/block_builder.zig",
    "src/tx_processor.zig",
    "lib/edr/crates/edr_provider/src/requests/eth/mine.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilMineHandler.js",
  ],
  "cat-7-snapshots": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig",
    "../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig",
    "lib/edr/crates/edr_provider/src/requests/eth/evm_snapshot.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilSnapshotHandler.js",
  ],
  "cat-8-state-manip": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig",
    "lib/edr/crates/edr_provider/src/requests/hardhat/",
    "../tevm-monorepo/packages/actions/src/anvil/anvilSetBalanceHandler.js",
    "../tevm-monorepo/packages/actions/src/SetAccount/",
  ],
  "cat-9-impersonation": [
    "src/tx_processor.zig",
    "lib/edr/crates/edr_provider/src/requests/hardhat/impersonate_account.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilImpersonateAccountHandler.js",
  ],
  "cat-10-forking": [
    "src/database/",
    "../voltaire/packages/voltaire-zig/src/state-manager/ForkBackend.zig",
    "../voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig",
    "../voltaire/packages/voltaire-zig/src/blockchain/ForkBlockCache.zig",
    "lib/edr/crates/edr_provider/src/",
    "../tevm-monorepo/packages/actions/src/",
  ],
  "cat-11-tracing": [
    "src/tx_processor.zig",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/debug/",
    "../voltaire/packages/voltaire-zig/src/evm/evm.zig",
    "../bench/guillotine-mini/client/rpc/",
    "lib/edr/crates/edr_provider/src/requests/debug.rs",
    "../tevm-monorepo/packages/actions/src/debug/",
  ],
  "cat-12-filters": [
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/new_filter/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_filter_changes/",
    "../voltaire/packages/voltaire-zig/src/jsonrpc/eth/get_logs/",
    "lib/edr/crates/edr_provider/src/requests/eth/",
    "../tevm-monorepo/packages/actions/src/eth/ethNewFilterHandler.js",
  ],
  "cat-13-time": [
    "src/block_builder.zig",
    "lib/edr/crates/edr_provider/src/requests/eth/evm_increase_time.rs",
    "../tevm-monorepo/packages/actions/src/anvil/anvilIncreaseTimeHandler.js",
    "../tevm-monorepo/packages/actions/src/anvil/anvilSetNextBlockTimestampHandler.js",
  ],

  // --- Test suite focuses ---
  "test-rlp": [
    "lib/ethereum-tests/RLPTests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
    "lib/execution-specs/src/ethereum/rlp.py",
  ],
  "test-trie": [
    "lib/ethereum-tests/TrieTests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
    "src/database/accounts.zig",
    "lib/execution-specs/src/ethereum/frontier/trie.py",
  ],
  "test-transaction": [
    "lib/ethereum-tests/TransactionTests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
    "src/tx_processor.zig",
    "lib/execution-specs/src/ethereum/frontier/transactions.py",
  ],
  "test-blockchain": [
    "lib/ethereum-tests/BlockchainTests/",
    "src/block_builder.zig",
    "src/tx_processor.zig",
    "src/database/",
    "lib/execution-specs/src/ethereum/frontier/fork.py",
  ],
  "test-difficulty": [
    "lib/ethereum-tests/DifficultyTests/",
    "lib/execution-specs/src/ethereum/frontier/fork.py",
    "lib/yellowpaper/",
  ],
  "test-abi": [
    "lib/ethereum-tests/ABITests/",
    "../voltaire/packages/voltaire-zig/src/primitives/",
  ],
  "test-eof": [
    "lib/ethereum-tests/EOFTests/",
    "lib/EIPs/EIPS/eip-3670.md",
    "../bench/guillotine-mini/src/",
  ],
  "test-state-frontier": [
    "lib/execution-spec-tests/tests/frontier/",
    "lib/execution-spec-tests/tests/homestead/",
    "lib/execution-spec-tests/tests/byzantium/",
    "lib/execution-spec-tests/tests/constantinople/",
    "lib/execution-spec-tests/tests/istanbul/",
    "lib/execution-specs/src/ethereum/",
  ],
  "test-state-berlin": [
    "lib/execution-spec-tests/tests/berlin/",
    "lib/execution-spec-tests/tests/shanghai/",
    "lib/execution-specs/src/ethereum/",
  ],
  "test-state-cancun": [
    "lib/execution-spec-tests/tests/cancun/",
    "lib/execution-spec-tests/tests/prague/",
    "lib/execution-specs/src/ethereum/",
  ],
  "test-hive-rpc": [
    "lib/hive/simulators/ethereum/",
    "lib/execution-apis/",
    "src/",
  ],
};
