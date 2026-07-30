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

function readPackage(packageDir) {
  return JSON.parse(fs.readFileSync(path.resolve(packageDir, "package.json"), "utf8"));
}

if (!dryRun && process.env.GITHUB_ACTIONS !== "true") {
  throw new Error("publishing is only allowed from GitHub Actions; use publish:all:dry locally");
}

run(process.execPath, [path.resolve(scriptDir, "stage-artifacts.cjs")], repoRoot);

const packageDirs = [];
const mainPackage = readPackage(packageRoot);
for (const entry of fs.readdirSync(platformsRoot, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const packageDir = path.resolve(platformsRoot, entry.name);
  const packageJsonPath = path.resolve(packageDir, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    console.warn(`skip ${path.relative(repoRoot, packageDir)}; no package.json`);
    continue;
  }
  const nativeAddon = path.resolve(packageDir, "zevm.node");
  if (!fs.existsSync(nativeAddon)) {
    throw new Error(`missing staged native addon for ${readPackageName(packageDir)}`);
  }
  const platformPackage = readPackage(packageDir);
  if (platformPackage.version !== mainPackage.version) {
    throw new Error(
      `version mismatch: ${platformPackage.name}@${platformPackage.version} != ${mainPackage.name}@${mainPackage.version}`,
    );
  }
  packageDirs.push(packageDir);
}
packageDirs.push(packageRoot);

const prerelease = mainPackage.version.split("-", 2)[1];
const distTag = prerelease ? prerelease.split(".", 1)[0] : "latest";

for (const packageDir of packageDirs) {
  const args = [
    "publish",
    "--access",
    "public",
    "--provenance",
    "--tag",
    distTag,
  ];
  if (dryRun) args.push("--dry-run");
  console.log(`\n> npm ${args.join(" ")} (${path.relative(repoRoot, packageDir)})`);
  run("npm", args, packageDir);
}
