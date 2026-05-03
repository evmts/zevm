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
  --allow-dirty                 do not fail on dirty ZEVM/dependency worktrees
  --allow-open-qualification    do not fail on qualification gap/blocked rows
  --allow-partial-external      do not fail on partial external suite manifests
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

  const untracked = run(["git", "-C", absolutePath, "ls-files", "--others", "--exclude-standard", "--directory"]);
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

async function checkExternalSuites(): Promise<void> {
  try {
    const data = await Bun.file(".smithers/external-test-suites.json").json();
    const suites = Array.isArray(data.suites) ? data.suites : [];
    const partial = suites.filter((suite: { status?: string }) => suite.status !== "complete");
    process.stdout.write(`release-blocker-audit: external non-complete suites=${partial.length}\n`);
    if (!allowPartialExternal && partial.length !== 0) {
      fail("external suite manifest still has non-complete suites");
      for (const suite of partial) {
        process.stderr.write(`- ${suite.name}: ${suite.status}\n`);
      }
    }
  } catch (error) {
    fail(`external test suite manifest is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
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
  checkCleanGit("voltaire", "../voltaire");
  checkCleanGit("guillotine-mini", "../guillotine-mini");
}

await checkQualificationMap();
await checkExternalSuites();
checkMarkers();
checkLaunchPreflight();

if (failures !== 0) {
  process.stderr.write(`release-blocker-audit: ${failures} blocker(s) found\n`);
  process.exit(1);
}

process.stdout.write("release-blocker-audit: no static release blockers found\n");
