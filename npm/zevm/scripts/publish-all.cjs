"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const dryRun = process.argv.includes("--dry-run");
const scriptDir = __dirname;
const packageRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(packageRoot, "../..");
const platformsRoot = path.resolve(packageRoot, "../platforms");

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    cwd,
    stdio: "inherit",
    shell: process.platform === "win32",
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function readPackageName(packageDir) {
  const packageJson = JSON.parse(fs.readFileSync(path.resolve(packageDir, "package.json"), "utf8"));
  return packageJson.name;
}

run(process.execPath, [path.resolve(scriptDir, "verify-release.cjs")], repoRoot);
run(process.execPath, [path.resolve(scriptDir, "stage-artifacts.cjs")], repoRoot);

const { version } = JSON.parse(fs.readFileSync(path.resolve(packageRoot, "package.json"), "utf8"));
// A prerelease such as 0.2.0-beta.1 must not move the `latest` dist-tag.
const prerelease = version.split("-", 2)[1];
const distTag = prerelease ? prerelease.split(".", 1)[0] : "latest";
// npm provenance needs a CI OIDC token; attest whenever the publish runs in GitHub Actions.
const provenance = process.env.GITHUB_ACTIONS === "true";

const packageDirs = [];
const missing = [];
for (const entry of fs.readdirSync(platformsRoot, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const packageDir = path.resolve(platformsRoot, entry.name);
  const packageJsonPath = path.resolve(packageDir, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    console.warn(`skip ${path.relative(repoRoot, packageDir)}; no package.json`);
    continue;
  }
  const nativeAddon = path.resolve(packageDir, "zevm.node");
  if (fs.existsSync(nativeAddon)) {
    packageDirs.push(packageDir);
  } else {
    missing.push(readPackageName(packageDir));
  }
}
if (missing.length > 0) {
  throw new Error(
    `Cannot publish: no zevm.node staged for ${missing.join(", ")}. ` +
      "Build each target with `zig build npm-platform-artifacts -Doptimize=ReleaseSafe -Dtarget=<triple>` " +
      "into zig-out/npm/prebuilds/<platform>/zevm.node first.",
  );
}
packageDirs.push(packageRoot);

for (const packageDir of packageDirs) {
  const args = ["publish", "--access", "public", "--tag", distTag];
  if (provenance) args.push("--provenance");
  if (dryRun) args.push("--dry-run");
  console.log(`\n> npm ${args.join(" ")} (${path.relative(repoRoot, packageDir)})`);
  run("npm", args, packageDir);
}
