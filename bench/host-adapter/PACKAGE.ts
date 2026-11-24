import { benchSuite } from "../suite.ts"

const suite = benchSuite({
  name: "host-adapter",
  summary: "EVM HostInterface vtable dispatch, balance/code/storage reads and writes",
  srcs: [
    "src/console_log.zig",
    "src/host_adapter.zig",
  ],
})

export const Package = suite.Package
