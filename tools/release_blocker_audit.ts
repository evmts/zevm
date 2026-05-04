#!/usr/bin/env bun

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = dirname(dirname(fileURLToPath(import.meta.url)));
process.chdir(rootDir);

const args = new Set(process.argv.slice(2));
const allowedArgs = new Set([
  "--allow-dirty",
  "--allow-open-qualification",
  "--allow-partial-external",
  "--include-launch-preflight",
  "--help",
]);

function usage(): void {
  process.stdout.write(`usage: tools/release_blocker_audit.ts [options]

Static release-blocker audit that does not execute ZEVM build artifacts unless
--include-launch-preflight is supplied.

Options:
  --allow-dirty                 do not fail on a dirty ZEVM worktree
  --allow-open-qualification    do not fail on qualification gap/blocked rows
  --allow-partial-external      accepted for older workflows; external scope is source-encoded
  --include-launch-preflight    also run the macOS executable launch preflight
  --help                        show this help
`);
}

for (const arg of args) {
  if (!allowedArgs.has(arg)) {
    process.stderr.write(`release-blocker-audit: unknown argument: ${arg}\n`);
    usage();
    process.exit(2);
  }
}

if (args.has("--help")) {
  usage();
  process.exit(0);
}

const allowDirty = args.has("--allow-dirty");
const allowOpenQualification = args.has("--allow-open-qualification");
const allowPartialExternal = args.has("--allow-partial-external");
const includeLaunchPreflight = args.has("--include-launch-preflight");
let failures = 0;
const decoder = new TextDecoder();

type RunResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

function run(command: string[], cwd = rootDir): RunResult {
  const proc = Bun.spawnSync(command, {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: proc.exitCode,
    stdout: decoder.decode(proc.stdout),
    stderr: decoder.decode(proc.stderr),
  };
}

function fail(message: string): void {
  failures += 1;
  process.stderr.write(`release-blocker-audit: FAIL: ${message}\n`);
}

function requireCommand(command: string): boolean {
  if (Bun.which(command)) return true;
  fail(`missing required command: ${command}`);
  return false;
}

function printLines(value: string, maxLines: number): void {
  const lines = value.trimEnd().split("\n").filter(Boolean);
  for (const line of lines.slice(0, maxLines)) process.stderr.write(`${line}\n`);
  if (lines.length > maxLines) process.stderr.write(`... ${lines.length - maxLines} more line(s)\n`);
}

async function checkDependencyManifest(): Promise<void> {
  const manifest = await Bun.file("build.zig.zon").text();
  const legacyPaths = ["../voltaire", "../guillotine-mini"];
  for (const legacyPath of legacyPaths) {
    if (manifest.includes(legacyPath)) {
      fail(`build.zig.zon still references legacy sibling dependency path: ${legacyPath}`);
    }
  }

  const requiredUrls = [
    "https://github.com/evmts/voltaire/archive/",
    "https://github.com/evmts/guillotine-mini/archive/",
  ];
  for (const requiredUrl of requiredUrls) {
    if (!manifest.includes(requiredUrl)) {
      fail(`build.zig.zon is missing immutable dependency URL pin: ${requiredUrl}`);
    }
  }
}

function checkCleanGit(name: string, path: string): void {
  const absolutePath = resolve(rootDir, path);
  const inside = run(["git", "-C", absolutePath, "rev-parse", "--is-inside-work-tree"]);
  if (inside.exitCode !== 0) {
    fail(`${name} is not a git worktree: ${absolutePath}`);
    return;
  }

  const revision = run(["git", "-C", absolutePath, "rev-parse", "HEAD"]).stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(revision)) {
    fail(`${name} revision is not a full git commit id: ${revision}`);
  }

  if (allowDirty) return;

  const tracked = run(["git", "-C", absolutePath, "diff-index", "--quiet", "HEAD", "--"]);
  if (tracked.exitCode !== 0) {
    fail(`${name} worktree has tracked changes: ${absolutePath}`);
  }

  const untracked = run(["git", "-C", absolutePath, "ls-files", "--others", "--exclude-standard"]);
  if (untracked.stdout.trim().length !== 0) {
    fail(`${name} worktree has untracked files: ${absolutePath}`);
    printLines(
      untracked.stdout
        .trimEnd()
        .split("\n")
        .slice(0, 20)
        .map((line) => `?? ${line}`)
        .join("\n"),
      20,
    );
  }
}

function countStatus(records: Array<{ coverageStatus?: string }>, status: string): number {
  return records.filter((record) => record.coverageStatus === status).length;
}

async function checkQualificationMap(): Promise<void> {
  try {
    const data = await Bun.file("docs/specs/qualification/assertion-map.json").json();
    const records = Array.isArray(data.records) ? data.records : [];
    const covered = countStatus(records, "covered");
    const gap = countStatus(records, "gap");
    const blocked = countStatus(records, "blocked");
    process.stdout.write(`release-blocker-audit: qualification covered=${covered} gap=${gap} blocked=${blocked}\n`);
    if (!allowOpenQualification && gap + blocked !== 0) {
      fail("qualification map has open gap/blocked rows");
    }
  } catch (error) {
    fail(`qualification map is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

async function checkExternalSuiteEvidence(): Promise<void> {
  const externalVerify = await Bun.file("tools/external_verify.zig").text();
  const requiredExternalScopes = [
    "execution_spec_state_fixture_paths",
    "execution_spec_blockchain_fixture_paths",
    "legacy_state_fixture_dirs",
    "hive_rpc_fixture_paths",
  ];
  for (const scope of requiredExternalScopes) {
    if (!externalVerify.includes(scope)) {
      fail(`tools/external_verify.zig is missing external verification scope: ${scope}`);
    }
  }

  const hiveSmoke = await Bun.file("tools/hive_rpc_compat_smoke.ts").text();
  const requiredHiveEvidence = [
    "defaultPattern",
    "ZEVM_HIVE_RPC_COMPAT_PATTERN",
    "ethereum/rpc-compat",
  ];
  for (const evidence of requiredHiveEvidence) {
    if (!hiveSmoke.includes(evidence)) {
      fail(`tools/hive_rpc_compat_smoke.ts is missing Hive smoke evidence: ${evidence}`);
    }
  }

  process.stdout.write("release-blocker-audit: external suite scope is source-encoded in tools/external_verify.zig and tools/hive_rpc_compat_smoke.ts\n");
}

function checkMarkers(): void {
  if (!Bun.which("rg")) {
    process.stderr.write("release-blocker-audit: rg not found; skipping marker scan\n");
    return;
  }

  const markerPattern = "\\b(todo|fixme|xxx|stub|mock|placeholder)\\b|@panic|panic\\(";
  const result = run([
    "rg",
    "-n",
    "-i",
    "-g",
    "!tools/release_blocker_audit.ts",
    "-g",
    "!tools/macos_launch_policy_preflight.ts",
    "-g",
    "!**/package-lock.json",
    markerPattern,
    "src",
    "tools",
    "build.zig",
    "include",
    "README.md",
    "docs",
    ".github",
  ]);

  if (result.exitCode === 0) {
    fail("forbidden release marker terms found in shipped files");
    printLines(result.stdout, 40);
  } else if (result.exitCode > 1) {
    fail(`marker scan failed: ${result.stderr.trim()}`);
  }
}

function checkLaunchPreflight(): void {
  if (!includeLaunchPreflight) return;
  const result = run(["bun", "tools/macos_launch_policy_preflight.ts"]);
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  if (result.exitCode !== 0) fail("local executable launch preflight failed");
}

if (requireCommand("git")) {
  checkCleanGit("zevm", ".");
}

await checkQualificationMap();
await checkDependencyManifest();
await checkExternalSuiteEvidence();
checkMarkers();
checkLaunchPreflight();

if (failures !== 0) {
  process.stderr.write(`release-blocker-audit: ${failures} blocker(s) found\n`);
  process.exit(1);
}

process.stdout.write("release-blocker-audit: no static release blockers found\n");
