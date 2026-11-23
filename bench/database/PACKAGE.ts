import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "database",
  summary: "StateManager balance/storage/checkpoint/revert, Contracts store, and Accounts trie sync",
  srcs: [
    "src/database/accounts.zig",
    "src/database/contracts.zig",
    "src/database/database.zig",
    "src/database/root.zig",
  ],
})

export const Package = suite.Package
