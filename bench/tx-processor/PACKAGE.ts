import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "tx-processor",
  summary: "EVM transaction execution (ETH transfer, storage+log contract, keccak loop, CREATE, SHA256 precompile)",
  srcs: [
    "src/blob_fee.zig",
    "src/console_log.zig",
    "src/evm_backend.zig",
    "src/evm_overrides.zig",
    "src/hardfork_schedule.zig",
    "src/host_adapter.zig",
    "src/precompile_compat.zig",
    "src/transaction_encoding.zig",
    "src/tx_processor.zig",
  ],
})

export const Package = suite.Package
