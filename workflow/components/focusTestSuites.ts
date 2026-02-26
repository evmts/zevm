// Already implemented: consensus light client, tx processing, block building, state management, host adapter
export const focusTestSuites: Record<string, {
  suites: string[];
  setupHints: string[];
  testDirs: string[];
}> = {
  // --- Implementation focuses ---
  "cat-1-rpc-server": {
    suites: ["JSON-RPC server tests", "Request parsing tests", "Batch request tests"],
    setupHints: [
      "voltaire already has complete JSON-RPC type system (65 methods with Params/Results) at ../voltaire/packages/voltaire-zig/src/jsonrpc/",
      "guillotine-mini already has RPC dispatch, envelope parsing, response serialization at ../bench/guillotine-mini/client/rpc/",
      "DO NOT rewrite JSON-RPC parsing — import and use voltaire's jsonrpc module and guillotine-mini's rpc module",
      "If voltaire/guillotine-mini are missing something, add it THERE (we own both repos), not in zevm",
      "zevm needs: HTTP listener (std.http.Server), wiring voltaire types to guillotine-mini dispatch, method handler registry",
      "Reference: edr/crates/edr_provider/src/requests/methods.rs for method routing patterns",
      "Spec: execution-apis/ has the official JSON-RPC 2.0 and Engine API specifications",
    ],
    testDirs: ["src/"],
  },
  "cat-2-eth-read": {
    suites: ["eth_chainId tests", "eth_getBalance tests", "eth_getCode tests", "eth_getStorageAt tests"],
    setupHints: [
      "voltaire jsonrpc module already defines all Params/Result types for these methods",
      "voltaire StateManager already exposes getBalance/getNonce/getCode/getStorage",
      "guillotine-mini client/rpc/eth.zig already implements eth_chainId handler — study and extend pattern",
      "Handlers should read from zevm's database module which wraps voltaire StateManager",
      "Reference: edr/crates/edr_provider/src/requests/eth/ for edge cases and error handling",
    ],
    testDirs: ["src/"],
  },
  "cat-3-eth-call": {
    suites: ["eth_call tests", "eth_estimateGas tests", "State override tests"],
    setupHints: [
      "zevm already has tx_processor.zig that executes transactions through guillotine-mini EVM",
      "eth_call = run tx_processor without persisting state changes (use checkpoint/revert)",
      "eth_estimateGas = binary search on gas limit using eth_call",
      "State overrides: temporarily modify balances/code/nonce/storage before execution",
      "voltaire jsonrpc eth_call.zig already defines the Params type including state overrides",
      "Reference: edr/crates/edr_provider/src/requests/eth/call.rs, ../tevm-monorepo/packages/actions/src/Call/",
    ],
    testDirs: ["src/"],
  },
  "cat-4-eth-send": {
    suites: ["eth_sendTransaction tests", "eth_sendRawTransaction tests", "Mempool tests"],
    setupHints: [
      "zevm tx_processor.zig already validates and executes transactions",
      "Need mempool: pending transaction queue with nonce ordering and gas price priority",
      "eth_sendRawTransaction: decode RLP-encoded signed tx, validate signature, add to mempool",
      "eth_sendTransaction: sign with local account key, then same as sendRaw",
      "In automine mode: immediately mine a block containing the tx",
      "Reference: edr send_transaction.rs, tevm ethSendTransactionHandler.js",
    ],
    testDirs: ["src/"],
  },
  "cat-5-block-queries": {
    suites: ["eth_getBlockByNumber tests", "eth_getTransactionReceipt tests", "eth_getLogs tests"],
    setupHints: [
      "voltaire blockchain module already provides block storage and retrieval",
      "Need to store mined blocks and their receipts/logs in a queryable structure",
      "eth_getLogs: filter by address, topics, block range — index logs during block building",
      "voltaire jsonrpc types define all response formats — use them directly",
      "Reference: edr for block query edge cases, tevm for log filtering logic",
    ],
    testDirs: ["src/", "src/database/"],
  },
  "cat-6-mining": {
    suites: ["Automine tests", "Manual mining tests", "Interval mining tests"],
    setupHints: [
      "zevm block_builder.zig already builds blocks from a list of transactions",
      "Automine: mine a block after every eth_sendTransaction (default mode for dev nodes)",
      "Manual: evm_mine mines one block, hardhat_mine mines N blocks with configurable interval",
      "Interval: timer-based mining every N milliseconds",
      "Reference: edr mine.rs, tevm anvilMineHandler.js",
    ],
    testDirs: ["src/"],
  },
  "cat-7-snapshots": {
    suites: ["Snapshot/revert tests", "Multi-level snapshot tests"],
    setupHints: [
      "voltaire StateManager already supports checkpoint/revert — this is the foundation",
      "evm_snapshot: save full state (accounts + blocks + pending txs) and return snapshot ID",
      "evm_revert: restore to snapshot, removing all blocks/txs/state changes since",
      "Must also revert block number, timestamp, and any mined blocks",
      "Reference: edr evm_snapshot.rs, tevm anvilSnapshotHandler.js",
    ],
    testDirs: ["src/"],
  },
  "cat-8-state-manip": {
    suites: ["hardhat_setBalance tests", "hardhat_setCode tests", "hardhat_setStorageAt tests"],
    setupHints: [
      "voltaire StateManager already exposes setBalance/setCode/setNonce/setStorage — just wire to RPC",
      "These are thin RPC handlers that parse params and call StateManager methods",
      "hardhat_setCoinbase: update block context for future blocks",
      "hardhat_setNextBlockBaseFeePerGas: modify EIP-1559 base fee for next block",
      "Reference: edr hardhat/ handlers, tevm anvil handlers",
    ],
    testDirs: ["src/"],
  },
  "cat-9-impersonation": {
    suites: ["Impersonation tests", "Impersonated transaction tests"],
    setupHints: [
      "Maintain a set of impersonated addresses",
      "When sending a tx from an impersonated address, skip signature validation",
      "hardhat_impersonateAccount: add address to impersonated set",
      "hardhat_stopImpersonatingAccount: remove from set",
      "Reference: edr impersonate_account.rs, tevm anvilImpersonateAccountHandler.js",
    ],
    testDirs: ["src/"],
  },
  "cat-10-forking": {
    suites: ["Fork mode tests", "Remote state fetch tests", "Local override on fork tests"],
    setupHints: [
      "voltaire ForkBackend already implements RPC client with caching",
      "voltaire JournaledState already supports dual-cache (local + fork) orchestration",
      "voltaire Blockchain module already has ForkBlockCache for remote block fetching",
      "DO NOT reimplement fork logic — configure voltaire's existing fork support",
      "zevm needs: CLI flag --fork-url, pass Transport config to ForkBackend, wire into StateManager",
      "Reference: edr fork support, tevm fork proxy",
    ],
    testDirs: ["src/", "src/database/"],
  },
  "cat-11-tracing": {
    suites: ["debug_traceCall tests", "debug_traceTransaction tests"],
    setupHints: [
      "voltaire debug jsonrpc types exist (debug_getRawBlock, debug_getRawHeader, etc.)",
      "guillotine-mini EVM may support step-level tracing — check ../bench/guillotine-mini/src/ for tracer hooks",
      "Implement struct log tracer (geth format): pc, op, gas, gasCost, depth, stack, memory, storage",
      "Support tracer options: disableStorage, disableMemory, disableStack",
      "Reference: edr debug.rs for tracer implementation, tevm debug/ handlers",
    ],
    testDirs: ["src/"],
  },
  "cat-12-filters": {
    suites: ["Log filter tests", "Block filter tests", "Pending tx filter tests"],
    setupHints: [
      "voltaire jsonrpc defines filter-related Params/Result types",
      "Filter manager: maintain filter registry with unique IDs, track poll cursors",
      "eth_newFilter: register log filter with address/topics/block range criteria",
      "eth_getFilterChanges: return new matches since last poll, advance cursor",
      "eth_subscribe (WebSocket): real-time push instead of polling",
      "Reference: edr filter handlers, tevm ethNewFilterHandler.js",
    ],
    testDirs: ["src/"],
  },
  "cat-13-time": {
    suites: ["evm_increaseTime tests", "evm_setNextBlockTimestamp tests"],
    setupHints: [
      "Maintain a time offset that's added to real time for block timestamps",
      "evm_increaseTime: add N seconds to offset, return new timestamp",
      "evm_setNextBlockTimestamp: set exact timestamp for next block only",
      "hardhat_setPrevRandao: set PREVRANDAO value for next block's block context",
      "Reference: edr evm_increase_time.rs, tevm anvilIncreaseTimeHandler.js",
    ],
    testDirs: ["src/"],
  },

  // --- Test suite focuses ---
  "test-rlp": {
    suites: ["RLP encoding tests", "RLP decoding tests", "RLP edge case tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/RLPTests/ (JSON format)",
      "voltaire already has RLP implementation at ../voltaire/packages/voltaire-zig/src/primitives/",
      "Write a test harness that loads JSON fixtures and runs them against voltaire's RLP",
      "If tests fail, fix the RLP implementation in voltaire (upstream), not zevm",
      "Reference: execution-specs/src/ethereum/rlp.py for the Python reference implementation",
    ],
    testDirs: ["ethereum-tests/RLPTests/", "src/"],
  },
  "test-trie": {
    suites: ["Trie insertion tests", "Trie proof tests", "Trie any-order tests", "Secure trie tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/TrieTests/ (5 fixture files, 25+ vectors)",
      "zevm has Merkle Patricia Trie in src/database/accounts.zig",
      "voltaire may have trie primitives — check ../voltaire/packages/voltaire-zig/src/primitives/",
      "Test fixtures include: trietest.json, trieanyorder.json, hex_encoded_securetrie_test.json",
      "Reference: execution-specs/src/ethereum/frontier/trie.py for trie spec",
    ],
    testDirs: ["ethereum-tests/TrieTests/", "src/database/"],
  },
  "test-transaction": {
    suites: ["Transaction validity tests", "Transaction encoding tests", "Signature recovery tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/TransactionTests/ (JSON format)",
      "voltaire has transaction types in primitives, zevm has tx_processor.zig",
      "Tests cover: valid/invalid tx detection, RLP encoding, signature recovery, sender extraction",
      "Write a test runner that loads JSON fixtures and validates against our tx processing",
      "Reference: execution-specs/src/ethereum/frontier/transactions.py",
    ],
    testDirs: ["ethereum-tests/TransactionTests/", "src/"],
  },
  "test-blockchain": {
    suites: ["Block execution tests", "Block validation tests", "Chain reorg tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/BlockchainTests/ (full block execution traces)",
      "These are comprehensive: they test block building, tx execution, state transitions, and receipts",
      "zevm has block_builder.zig + tx_processor.zig + database/ — all need to work together",
      "Start with simple cases (single tx blocks) before tackling multi-tx and edge cases",
      "Reference: execution-specs/src/ethereum/frontier/fork.py for block processing spec",
    ],
    testDirs: ["ethereum-tests/BlockchainTests/", "src/"],
  },
  "test-difficulty": {
    suites: ["Frontier difficulty tests", "Homestead difficulty tests", "Byzantium+ difficulty tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/DifficultyTests/ organized by hardfork",
      "Difficulty algorithm changes across hardforks — implement each variant",
      "Post-merge (PoS) these are irrelevant, but needed for pre-merge compatibility",
      "Reference: yellowpaper/ for formal difficulty spec, execution-specs/ for Python impl",
    ],
    testDirs: ["ethereum-tests/DifficultyTests/"],
  },
  "test-abi": {
    suites: ["ABI encoding tests", "ABI decoding tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/ABITests/ (JSON format)",
      "voltaire has ABI encoding/decoding at ../voltaire/packages/voltaire-zig/src/primitives/",
      "Run tests against voltaire's implementation — fix upstream if failures found",
    ],
    testDirs: ["ethereum-tests/ABITests/"],
  },
  "test-eof": {
    suites: ["EOF validation tests", "EOF container tests"],
    setupHints: [
      "Test vectors are in ethereum-tests/EOFTests/ (EVM Object Format, EIP-3670)",
      "EOF validation happens at deploy time — check guillotine-mini EVM for EOF support",
      "Reference: EIPs/EIPS/eip-3670.md for the spec",
    ],
    testDirs: ["ethereum-tests/EOFTests/"],
  },
  "test-state-frontier": {
    suites: ["Frontier state tests", "Homestead state tests", "Byzantium state tests", "Constantinople state tests", "Istanbul state tests"],
    setupHints: [
      "Execution spec tests are in execution-spec-tests/tests/{frontier,homestead,byzantium,constantinople,istanbul}/",
      "These test EVM execution + state transitions for early hardforks",
      "Need a test runner that: loads test fixture, sets up initial state, executes tx, compares final state root",
      "voltaire EVM + guillotine-mini handle execution, zevm provides state management integration",
      "Reference: execution-specs/src/ethereum/ for Python reference per hardfork",
    ],
    testDirs: ["execution-spec-tests/tests/", "src/"],
  },
  "test-state-berlin": {
    suites: ["Berlin state tests", "Shanghai state tests"],
    setupHints: [
      "Execution spec tests are in execution-spec-tests/tests/{berlin,shanghai}/",
      "Berlin adds: EIP-2929 (gas cost changes), EIP-2930 (access lists)",
      "Shanghai adds: EIP-4895 (withdrawals), EIP-3651 (warm COINBASE), EIP-3855 (PUSH0)",
      "Reference: execution-specs/src/ethereum/ for Python reference per hardfork",
    ],
    testDirs: ["execution-spec-tests/tests/", "src/"],
  },
  "test-state-cancun": {
    suites: ["Cancun state tests", "Prague state tests"],
    setupHints: [
      "Execution spec tests are in execution-spec-tests/tests/{cancun,prague}/",
      "Cancun adds: EIP-4844 (blobs), EIP-1153 (transient storage), EIP-4788 (beacon root), EIP-5656 (MCOPY), EIP-6780 (SELFDESTRUCT changes)",
      "Prague adds: EIP-7702 (set EOA code), EIP-2537 (BLS precompile), EOF",
      "Reference: execution-specs/src/ethereum/ for Python reference per hardfork",
    ],
    testDirs: ["execution-spec-tests/tests/", "src/"],
  },
  "test-hive-rpc": {
    suites: ["Hive RPC conformance tests"],
    setupHints: [
      "Hive tests are in hive/simulators/ethereum/ — these are integration tests",
      "They test JSON-RPC conformance by running requests against a real node",
      "zevm must be running as an HTTP server (cat-1-rpc-server) for these to work",
      "This focus depends on most implementation focuses being complete first",
      "Reference: execution-apis/ for the official JSON-RPC specification",
    ],
    testDirs: ["hive/simulators/ethereum/", "src/"],
  },
};
