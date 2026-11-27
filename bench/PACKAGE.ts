import { Smithers as S } from "@smthrs/targets"
import { Package as blobKzg } from "./blob-kzg/PACKAGE.ts"
import { Package as blockBuilder } from "./block-builder/PACKAGE.ts"
import { Package as cFfi } from "./c-ffi/PACKAGE.ts"
import { Package as chainGenesis } from "./chain-genesis/PACKAGE.ts"
import { Package as configCliLog } from "./config-cli-log/PACKAGE.ts"
import { Package as consensusLight } from "./consensus-light/PACKAGE.ts"
import { Package as database } from "./database/PACKAGE.ts"
import { Package as hostAdapter } from "./host-adapter/PACKAGE.ts"
import { Package as indexes } from "./indexes/PACKAGE.ts"
import { Package as miningNode } from "./mining-node/PACKAGE.ts"
import { Package as mptProof } from "./mpt-proof/PACKAGE.ts"
import { Package as rpc } from "./rpc/PACKAGE.ts"
import { Package as txEncoding } from "./tx-encoding/PACKAGE.ts"
import { Package as txProcessor } from "./tx-processor/PACKAGE.ts"
import { Package as txpool } from "./txpool/PACKAGE.ts"

const node = S.Host.bin("node")

const suites = [
  database,
  hostAdapter,
  txEncoding,
  blobKzg,
  txProcessor,
  txpool,
  blockBuilder,
  indexes,
  mptProof,
  consensusLight,
  chainGenesis,
  miningNode,
  rpc,
  configCliLog,
  cFfi,
] as const
const allSuites = suites.map((suite) => suite.bench)
const zigSources = S.Filegroup({
  srcs: [S.glob("*.zig"), ...suites.map((suite) => suite["zig-sources"])],
})

/**
 * Aggregates every suite's cached or freshly run JSON result, compares against
 * `bench/baseline.json`, prints the full table, and writes report.json/report.md.
 * Because every suite is a separate cached dependency, changing one module only
 * re-runs the affected suites while unchanged suites replay from `.smithers/cache`.
 */
const report = S.Shell.Build({
  summary: "Aggregate all ZEVM benchmark suites and compare against bench/baseline.json",
  bin: node,
  args: [
    "tools/bench_report.mjs",
    "--baseline",
    "bench/baseline.json",
    "--out-json",
    "bench/.results/report.json",
    "--out-md",
    "bench/.results/report.md",
  ],
  outFiles: [".results/report.json", ".results/report.md"],
  data: [
    ...allSuites,
    S.file("//tools/bench_report.mjs"),
    S.file("baseline.json"),
  ],
  sandbox: "none",
  timeout: "2m",
})

/**
 * Soundness guard: verifies every bench/<suite>/PACKAGE.ts declares every
 * transitive local Zig file reachable from bench/<suite>/main.zig.
 */
const depsCheck = S.Shell.Test({
  summary: "Verify every benchmark PACKAGE.ts covers its exact transitive Zig source inputs",
  bin: node,
  args: ["tools/bench_deps_check.mjs"],
  data: [
    S.file("//tools/bench_deps_check.mjs"),
    S.file("//src/root.zig"),
    S.glob("//src/**/*.zig"),
    zigSources,
    ...suites.map((suite) => suite.declaration),
  ],
  sandbox: "none",
  timeout: "1m",
})

/** Manual target to refresh bench/baseline.json from all current suite results. */
const updateBaseline = S.Shell.Run({
  summary: "Update committed bench/baseline.json from current benchmark suite results",
  bin: node,
  args: [
    "tools/bench_report.mjs",
    "--baseline",
    "bench/baseline.json",
    "--update-baseline",
  ],
  data: [
    ...allSuites,
    S.file("//tools/bench_report.mjs"),
  ],
  sandbox: "none",
  manual: true,
  timeout: "2m",
})

export const Package = S.Package({
  targets: {
    "zig-sources": zigSources,
    report,
    "deps-check": depsCheck,
    "update-baseline": updateBaseline,
  },
})
