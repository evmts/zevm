import { Smithers as S } from "@smthrs/targets"
import { Package as benchPkg } from "./bench/PACKAGE.ts"

const zig = S.Host.bin("zig")
const cargo = S.Host.bin("cargo")
const rustc = S.Host.bin("rustc")
const cc = S.Host.bin("cc")
const node = S.Host.bin("node")
const bun = S.Host.bin("bun")
const sh = S.Host.bin("sh")

// Everything `zig build` reads. Docs, README, CI, and the factory never
// invalidate Zig results. build.zig.zon resolves ../voltaire and
// ../guillotine-mini by path, outside the workspace, so their source digest
// (.native-deps.digest, written by tools/native_deps_digest.mjs from
// scripts/smthrs and CI before planning) stands in for them in every key.
const zigSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//.native-deps.digest"),
    S.file("//build.zig"),
    S.file("//build.zig.zon"),
    S.file("//native-dependencies.json"),
    S.glob("//src/**"),
    S.glob("//tools/**"),
    S.glob("//include/**"),
    S.glob("//bench/**/*.zig"),
    S.glob("//npm/zevm/native/**"),
    S.glob("//npm/platforms/**"),
  ],
})

// Execution-apis fixtures (git submodule) read by verify-fast unit tests.
const executionApis = S.Filegroup({
  cwd: "//",
  srcs: [
    S.glob("//lib/execution-apis/src/**"),
    S.glob("//lib/execution-apis/tests/**"),
  ],
})

const zigCommon = {
  bin: zig,
  tools: [cargo, rustc, cc, bun],
  env: { ZEVM_LAUNCH_POLICY_TIMEOUT: "15" },
  sandbox: "none" as const,
}

const dependencyPreflight = S.Shell.Test({
  summary: "Validate build.zig.zon dependency pins and the Zig toolchain version",
  ...zigCommon,
  args: ["build", "dependency-preflight", "--", "--zig-version", "0.15.2"],
  data: [zigSources],
  timeout: "10m",
})

const build = S.Shell.Build({
  summary: "Build the ZEVM CLI binary",
  ...zigCommon,
  args: ["build", "-p", "zig-out/smithers/build"],
  data: [zigSources],
  outDirs: ["zig-out/smithers/build"],
  timeout: "30m",
})

const test = S.Shell.Test({
  summary: "Run fast Zig unit, startup-smoke, and test-graph checks (zig build verify-fast)",
  ...zigCommon,
  args: ["build", "verify-fast"],
  data: [zigSources, executionApis],
  timeout: "45m",
})

const cSmoke = S.Shell.Test({
  summary: "Compile and run the C ABI static-library smoke test",
  ...zigCommon,
  args: ["build", "c-smoke"],
  data: [zigSources],
  timeout: "20m",
})

const npmSmoke = S.Shell.Test({
  summary: "Build and run the Node-API addon smoke tests",
  ...zigCommon,
  tools: [cargo, rustc, cc, node],
  args: ["build", "npm-smoke"],
  data: [zigSources, S.glob("npm/zevm/**", { exclude: ["npm/zevm/node_modules/**"] })],
  timeout: "20m",
})

const releaseBinaries = S.Shell.Build({
  summary: "Build the host target's ReleaseSafe ZEVM CLI release artifact",
  ...zigCommon,
  args: ["build", "release-binaries", "-Doptimize=ReleaseSafe", "-p", "zig-out/smithers/release"],
  data: [zigSources],
  outDirs: ["zig-out/smithers/release"],
  timeout: "45m",
})

const npmPlatformArtifacts = S.Shell.Build({
  summary: "Build the host target's ReleaseSafe Node-API prebuild",
  ...zigCommon,
  args: ["build", "npm-platform-artifacts", "-Doptimize=ReleaseSafe", "-p", "zig-out/smithers/npm"],
  data: [zigSources],
  outDirs: ["zig-out/smithers/npm"],
  timeout: "45m",
})

const qualificationCheck = S.Shell.Test({
  summary: "Validate the release qualification assertion map",
  ...zigCommon,
  args: ["build", "qualification-check"],
  data: [zigSources, S.glob("docs/specs/qualification/**")],
  timeout: "10m",
})

const fmt = S.Shell.Test({
  summary: "Check Zig formatting (zig fmt --check)",
  bin: zig,
  args: ["fmt", "--check", "build.zig", "build.zig.zon", "src", "tools", "bench"],
  data: [
    S.file("build.zig"),
    S.file("build.zig.zon"),
    S.glob("src/**/*.zig"),
    S.glob("tools/**/*.zig"),
    S.glob("bench/**/*.zig"),
  ],
  sandbox: "none",
  timeout: "5m",
})

const jsCheck = S.Shell.Test({
  summary: "Syntax-check the npm package and repository JS tools",
  bin: sh,
  tools: [node],
  args: [
    "-eu",
    "-c",
    "for f in npm/zevm/src/index.js npm/zevm/scripts/*.cjs tools/*.mjs tools/*.js; do node --check \"$f\"; done",
  ],
  data: [
    S.glob("npm/zevm/src/**"),
    S.glob("npm/zevm/scripts/**"),
    S.glob("tools/*.mjs"),
    S.glob("tools/*.js"),
  ],
  sandbox: "none",
  timeout: "2m",
})

const docsMirror = S.Shell.Test({
  summary: "Check that docs/src/content/docs mirrors the authored docs (node tools/docs_mirror.mjs)",
  bin: node,
  args: ["tools/docs_mirror.mjs"],
  data: [
    S.file("tools/docs_mirror.mjs"),
    S.glob("docs/**/*.md", { exclude: ["docs/node_modules/**"] }),
    S.glob("docs/**/*.mdx", { exclude: ["docs/node_modules/**"] }),
  ],
  sandbox: "none",
  timeout: "2m",
})

export const Package = S.Package({
  targets: {
    "zig-sources": zigSources,
    "execution-apis": executionApis,
    "dependency-preflight": dependencyPreflight,
    build,
    test,
    "c-smoke": cSmoke,
    "npm-smoke": npmSmoke,
    "release-binaries": releaseBinaries,
    "npm-platform-artifacts": npmPlatformArtifacts,
    "qualification-check": qualificationCheck,
    fmt,
    "js-check": jsCheck,
    "docs-mirror": docsMirror,
    bench: S.Alias(benchPkg.report),
    "bench-update-baseline": S.Alias(benchPkg["update-baseline"]),
  },
})
