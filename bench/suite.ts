import { Smithers as S } from "@smthrs/targets"
import type * as Input from "@smthrs/targets/Input"

const zig = S.Host.bin("zig")
const cargo = S.Host.bin("cargo")
const node = S.Host.bin("node")
const bun = S.Host.bin("bun")

/** Shared root build/harness inputs every benchmark suite depends on. */
const sharedBenchInputs: ReadonlyArray<Input.Declared> = [
  S.file("//build.zig"),
  S.file("//build.zig.zon"),
  S.file("//native-dependencies.json"),
  S.file("//src/root.zig"),
  S.file("//bench/harness.zig"),
  S.file("//tools/macos_launch_policy_preflight.js"),
]

export interface BenchSuiteOptions {
  readonly name: string
  readonly summary: string
  readonly srcs: ReadonlyArray<string>
  readonly extraData?: ReadonlyArray<Input.Declared>
  readonly timeout?: string
}

/**
 * Declares an incremental benchmark package for one ZEVM subsystem:
 * - `bench` (`S.Shell.Build`): compiles in ReleaseFast, runs the suite, and
 *   caches `.results/latest.json` keyed on the suite's exact transitive Zig inputs.
 * - `test` (`S.Shell.Test`): validates the benchmark result schema and prints
 *   the suite's metrics + delta vs `bench/baseline.json`, making benchmarks
 *   behave just like incremental unit/integration tests under `smthrs test` and
 *   `smthrs affected test`.
 */
export const benchSuite = (options: BenchSuiteOptions) => {
  const resultRel = `bench/${options.name}/.results/latest.json`
  const bench = S.Shell.Build({
    summary: `Run ReleaseFast benchmarks for ${options.name}: ${options.summary}`,
    bin: zig,
    args: [
      "build",
      `bench-${options.name}`,
      "-Doptimize=ReleaseFast",
      "--",
      "--json-out",
      resultRel,
    ],
    outFiles: [".results/latest.json"],
    data: [
      ...sharedBenchInputs,
      S.file("main.zig"),
      ...options.srcs.map((src) => S.file(`//${src}`)),
      ...(options.extraData ?? []),
    ],
    tools: [cargo, bun],
    env: {
      ZEVM_LAUNCH_POLICY_TIMEOUT: "15",
    },
    sandbox: "none",
    timeout: options.timeout ?? "10m",
  })

  const test = S.Shell.Test({
    summary: `Report & verify ${options.name} benchmark results against baseline`,
    bin: node,
    args: [
      "tools/bench_report.mjs",
      "--suite",
      options.name,
      "--input",
      resultRel,
      "--baseline",
      "bench/baseline.json",
    ],
    data: [
      bench,
      S.file("//tools/bench_report.mjs"),
      S.file("//bench/baseline.json"),
    ],
    sandbox: "none",
    timeout: "1m",
  })

  return {
    bench,
    test,
    Package: S.Package({
      targets: {
        bench,
        test,
      },
    }),
  }
}
