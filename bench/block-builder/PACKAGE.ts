import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "block-builder",
  summary: "Block construction, transactions/receipts/state roots, and logs bloom aggregation",
  srcs: [
    "src/blob_fee.zig",
    "src/block_builder.zig",
    "src/console_log.zig",
    "src/evm_overrides.zig",
    "src/hardfork_schedule.zig",
    "src/host_adapter.zig",
    "src/precompile_compat.zig",
    "src/rpc/dev_runtime.zig",
    "src/system_contracts.zig",
    "src/transaction_encoding.zig",
    "src/tx_processor.zig",
  ],
})

export const Package = suite.Package
