import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "blob-kzg",
  summary: "Blob fee math, EIP-7892 schedule lookup, hardfork resolution, and KZG v0/v1 proof verification",
  srcs: [
    "src/blob_fee.zig",
    "src/blob_kzg.zig",
    "src/hardfork_schedule.zig",
    "src/transaction_encoding.zig",
  ],
})

export const Package = suite.Package
