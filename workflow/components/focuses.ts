// Already implemented (no longer need workflow focus):
//   consensus-light-client — BLS verification, SSZ Merkle proofs, beacon API, sync engine, checkpoint persistence
//   tx-processing — transaction execution with gas/nonce/balance validation via guillotine-mini EVM
//   block-building — sequential tx processing with gas limit enforcement and receipt generation
//   state-management — StateManager with journaling, Merkle Patricia Trie, contract dedup, block hashes
//   host-adapter — voltaire StateManager <-> guillotine-mini HostInterface bridge

// === IMPLEMENTATION FOCUSES ===
// Each focus is a feature area to build. Discovery agents should check voltaire + guillotine-mini
// before implementing anything in zevm.

export const focuses = [
  // --- Implementation focuses ---
  { id: "cat-1-rpc-server", name: "HTTP JSON-RPC Server (request parsing, method dispatch, batch support — reuse voltaire jsonrpc types + guillotine-mini rpc module)" },
  { id: "cat-2-eth-read", name: "Read-only eth_* Methods (eth_chainId, eth_blockNumber, eth_getBalance, eth_getCode, eth_getStorageAt, eth_getTransactionCount, eth_gasPrice, eth_coinbase, eth_accounts)" },
  { id: "cat-3-eth-call", name: "eth_call + eth_estimateGas (execute calls against state without persisting, state overrides)" },
  { id: "cat-4-eth-send", name: "eth_sendTransaction + eth_sendRawTransaction + Transaction Pool (mempool, tx validation, nonce management)" },
  { id: "cat-5-block-queries", name: "Block Query Methods (eth_getBlockByNumber/Hash, eth_getTransactionByHash, eth_getTransactionReceipt, eth_getBlockReceipts, eth_getLogs)" },
  { id: "cat-6-mining", name: "Mining Modes (automine, evm_mine, hardhat_mine, interval mining, evm_setAutomine, evm_setIntervalMining)" },
  { id: "cat-7-snapshots", name: "Snapshot & Revert (evm_snapshot, evm_revert — full blockchain state rollback)" },
  { id: "cat-8-state-manip", name: "State Manipulation (hardhat_setBalance, hardhat_setCode, hardhat_setNonce, hardhat_setStorageAt, hardhat_setCoinbase, hardhat_setNextBlockBaseFeePerGas, evm_setBlockGasLimit)" },
  { id: "cat-9-impersonation", name: "Account Impersonation (hardhat_impersonateAccount, hardhat_stopImpersonatingAccount — send txs without private key)" },
  { id: "cat-10-forking", name: "Fork Mode (proxy reads to remote RPC, local state overrides, reuse voltaire ForkBackend + StateManager fork support)" },
  { id: "cat-11-tracing", name: "Debug & Tracing (debug_traceCall, debug_traceTransaction — reuse voltaire debug jsonrpc types, integrate with guillotine-mini EVM tracing)" },
  { id: "cat-12-filters", name: "Filters & Subscriptions (eth_newFilter, eth_newBlockFilter, eth_newPendingTransactionFilter, eth_getFilterChanges, eth_getLogs, eth_subscribe/eth_unsubscribe)" },
  { id: "cat-13-time", name: "Time Manipulation (evm_increaseTime, evm_setNextBlockTimestamp, hardhat_setPrevRandao)" },

  // --- Test suite focuses ---
  // Each test suite is its own focus so agents can work on getting tests passing independently.
  { id: "test-rlp", name: "RLP Tests — pass ethereum-tests/RLPTests/ JSON vectors (encoding/decoding)" },
  { id: "test-trie", name: "Trie Tests — pass ethereum-tests/TrieTests/ JSON vectors (Merkle Patricia Trie correctness)" },
  { id: "test-transaction", name: "Transaction Tests — pass ethereum-tests/TransactionTests/ JSON vectors (tx validity, encoding, signature recovery)" },
  { id: "test-blockchain", name: "Blockchain Tests — pass ethereum-tests/BlockchainTests/ JSON vectors (full block execution traces)" },
  { id: "test-difficulty", name: "Difficulty Tests — pass ethereum-tests/DifficultyTests/ JSON vectors (mining difficulty algorithms)" },
  { id: "test-abi", name: "ABI Tests — pass ethereum-tests/ABITests/ JSON vectors (contract ABI encoding/decoding)" },
  { id: "test-eof", name: "EOF Tests — pass ethereum-tests/EOFTests/ JSON vectors (EVM Object Format validation)" },
  { id: "test-state-frontier", name: "State Tests (Frontier→Istanbul) — pass execution-spec-tests for early hardforks" },
  { id: "test-state-berlin", name: "State Tests (Berlin→Shanghai) — pass execution-spec-tests for mid hardforks" },
  { id: "test-state-cancun", name: "State Tests (Cancun→Prague) — pass execution-spec-tests for latest hardforks" },
  { id: "test-hive-rpc", name: "Hive RPC Tests — pass hive/simulators/ethereum/ JSON-RPC conformance tests against our node" },
] as const;

export type FocusId = (typeof focuses)[number]["id"];
