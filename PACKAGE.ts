import { Smithers as S } from "@smthrs/targets"
import { Package as benchPkg } from "./bench/PACKAGE.ts"

const zig = S.Host.bin("zig")
const cargo = S.Host.bin("cargo")
const node = S.Host.bin("node")
const bun = S.Host.bin("bun")

const build = S.Shell.Build({
  summary: "Build the ZEVM CLI binary",
  bin: zig,
  args: ["build"],
  outDirs: ["zig-out/bin"],
  data: [
    S.file("build.zig"),
    S.file("build.zig.zon"),
    S.file("native-dependencies.json"),
    S.glob("src/**/*.zig"),
  ],
  tools: [cargo],
  sandbox: "none",
  timeout: "15m",
})

const test = S.Shell.Test({
  summary: "Run fast Zig unit, startup-smoke, and test-graph checks",
  bin: zig,
  args: ["build", "verify-fast"],
  data: [
    S.file("build.zig"),
    S.file("build.zig.zon"),
    S.file("native-dependencies.json"),
    S.glob("src/**/*.zig"),
    S.glob("tools/*.zig"),
    S.file("tools/macos_launch_policy_preflight.js"),
  ],
  tools: [cargo, bun],
  env: {
    ZEVM_LAUNCH_POLICY_TIMEOUT: "15",
  },
  sandbox: "none",
  timeout: "20m",
})

const cSmoke = S.Shell.Test({
  summary: "Compile and run the C ABI static-library smoke test",
  bin: zig,
  args: ["build", "c-smoke"],
  data: [
    S.file("build.zig"),
    S.file("build.zig.zon"),
    S.file("native-dependencies.json"),
    S.file("include/zevm.h"),
    S.file("tools/c_smoke.c"),
    S.file("tools/macos_launch_policy_preflight.js"),
    S.glob("src/**/*.zig"),
  ],
  tools: [cargo, bun],
  env: {
    ZEVM_LAUNCH_POLICY_TIMEOUT: "15",
  },
  sandbox: "none",
  timeout: "15m",
})

const npmSmoke = S.Shell.Test({
  summary: "Build and run the Node-API addon smoke tests",
  bin: zig,
  args: ["build", "npm-smoke"],
  data: [
    S.file("build.zig"),
    S.file("build.zig.zon"),
    S.file("native-dependencies.json"),
    S.file("include/zevm.h"),
    S.glob("npm/zevm/**"),
    S.glob("src/**/*.zig"),
  ],
  tools: [cargo, node],
  sandbox: "none",
  timeout: "15m",
})

const qualificationCheck = S.Shell.Test({
  summary: "Validate the release qualification assertion map",
  bin: zig,
  args: ["build", "qualification-check"],
  data: [
    S.file("build.zig"),
    S.file("tools/qualification_check.zig"),
    S.file("tools/macos_launch_policy_preflight.js"),
    S.glob("docs/specs/qualification/**"),
  ],
  tools: [bun],
  env: {
    ZEVM_LAUNCH_POLICY_TIMEOUT: "15",
  },
  sandbox: "none",
  timeout: "5m",
})

const bench = S.Alias(benchPkg.report)
const benchBaseline = S.Alias(benchPkg["update-baseline"])

export const Package = S.Package({
  targets: {
    build,
    test,
    "c-smoke": cSmoke,
    "npm-smoke": npmSmoke,
    "qualification-check": qualificationCheck,
    bench,
    "bench-update-baseline": benchBaseline,
  },
})
