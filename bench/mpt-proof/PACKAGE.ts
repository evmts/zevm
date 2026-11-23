import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "mpt-proof",
  summary: "Merkle Patricia Trie secureProof generation (64 & 512 keys) and secure trie root computation",
  srcs: [
    "src/mpt_proof.zig",
  ],
})

export const Package = suite.Package
