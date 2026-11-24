import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "chain-genesis",
  summary: "Genesis block creation, premine state root, RLP block decoding, and 20-block chain import",
  srcs: [
    "src/blob_fee.zig",
    "src/block_builder.zig",
    "src/chain_import.zig",
    "src/console_log.zig",
    "src/database/accounts.zig",
    "src/database/contracts.zig",
    "src/database/database.zig",
    "src/database/root.zig",
    "src/evm_overrides.zig",
    "src/genesis.zig",
    "src/hardfork_schedule.zig",
    "src/host_adapter.zig",
    "src/mining_coordinator.zig",
    "src/precompile_compat.zig",
    "src/rpc/dev_runtime.zig",
    "src/system_contracts.zig",
    "src/transaction_encoding.zig",
    "src/tx_processor.zig",
  ],
})

export const Package = suite.Package
