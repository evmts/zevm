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

run(process.execPath, [path.resolve(scriptDir, "stage-artifacts.cjs")], repoRoot);

const packageDirs = [];
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
    throw new Error(`Cannot publish: ${readPackageName(packageDir)} has no zevm.node staged`);
  }
}
packageDirs.push(packageRoot);

for (const packageDir of packageDirs) {
  const args = ["publish", "--access", "public"];
  if (dryRun) args.push("--dry-run");
  console.log(`\n> npm ${args.join(" ")} (${path.relative(repoRoot, packageDir)})`);
  run("npm", args, packageDir);
}
