import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "tx-encoding",
  summary: "Legacy and EIP-1559 RLP encoding/decoding, tx hashing, signing, and secp256k1 sender recovery",
  srcs: [
    "src/transaction_encoding.zig",
  ],
})

export const Package = suite.Package
