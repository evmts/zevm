import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "consensus-light",
  summary: "Beacon API JSON parsing, consensus header hashing/signing roots, participating keys, and checkpoint I/O",
  srcs: [
    "src/beacon_api.zig",
    "src/checkpoint.zig",
    "src/consensus_verifier.zig",
  ],
})

export const Package = suite.Package
