import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "txpool",
  summary: "TransactionPool insertion, gas replacement, pendingNonce, pendingCount, getReady, and removeMined",
  srcs: [
    "src/transaction_encoding.zig",
    "src/txpool.zig",
  ],
})

export const Package = suite.Package
