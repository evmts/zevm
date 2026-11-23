import { Smithers as S } from "@smthrs/targets"

// Smithers build & incremental benchmark graph for ZEVM.
// Every bench/<suite>/PACKAGE.ts declares only the exact Zig sources that
// suite transitively imports. `scripts/smthrs build //bench/...` and
// `scripts/smthrs affected build //bench/...` only re-run suites whose inputs
// changed, replaying cached JSON results from `.flows` for everything else.
export const Workspace = S.Workspace("zevm", {
  repository: "git+https://github.com/evmts/zevm.git",
  cache: S.Cache({
    directory: ".flows",
    hostDirectories: [".zig-cache", "zig-out"],
  }),
  host: S.Host({
    bins: ["zig", "cargo", "node", "bun", "sh"],
  }),
})
