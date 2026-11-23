import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "indexes",
  summary: "ReceiptIndex tx/block lookups and LogIndex blockHash, topic/address, and sparse-range queries",
  srcs: [
    "src/log_index.zig",
    "src/receipt_index.zig",
  ],
})

export const Package = suite.Package
