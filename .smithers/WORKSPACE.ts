import { Smithers as S } from "@smthrs/targets"

// Smithers incremental build graph for ZEVM.
//
// - Root PACKAGE.ts: build, unit/startup/test-graph checks, C ABI and N-API
//   smokes, release artifact builds, qualification, formatting, JS checks.
// - bench/<suite>/PACKAGE.ts: per-subsystem benchmark suites keyed on the exact
//   transitive Zig sources each suite imports.
// - .smithers/PACKAGE.ts + FACTORY.ts: factory projection write/check.
//
// `smthrs ci '//...'` replays unchanged targets from the local cache and, when
// SMITHERS_CACHE_READ_TOKEN / SMITHERS_CACHE_WRITE_TOKEN are set, from the
// Smithers remote cache.
export const Workspace = S.Workspace("evmts-zevm", {
  repository: "evmts/zevm",
  cache: S.Cache({
    directory: ".smithers/cache",
    hostDirectories: [".zig-cache", "zig-out"],
    remote: S.RemoteCache.make({
      endpoint: "https://build.smithers.sh",
      read: S.Secret("SMITHERS_CACHE_READ_TOKEN"),
      write: S.Secret("SMITHERS_CACHE_WRITE_TOKEN"),
    }),
  }),
  host: S.Host({
    bins: ["zig", "cargo", "rustc", "cc", "node", "bun", "sh"],
  }),
  discovery: {
    prune: [
      "lib",
      ".zig-cache",
      "zig-out",
      "zig-cache",
      "node_modules",
      ".flows",
      ".smithers/cache",
      ".smithers/reports",
    ],
  },
})
