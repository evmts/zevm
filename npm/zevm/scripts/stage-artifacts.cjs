"use strict";

const fs = require("node:fs");
const path = require("node:path");

const scriptDir = __dirname;
const packageRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(packageRoot, "../..");
const platformsRoot = path.resolve(packageRoot, "../platforms");
const zigOutNpm = path.resolve(repoRoot, "zig-out/npm");
const includeLocalNative = process.argv.includes("--include-local-native");

const platformPackages = new Map([
  ["darwin-arm64", "@evmts/zevm-darwin-arm64"],
  ["darwin-x64", "@evmts/zevm-darwin-x64"],
  ["freebsd-arm64", "@evmts/zevm-freebsd-arm64"],
  ["freebsd-x64", "@evmts/zevm-freebsd-x64"],
  ["linux-arm64-gnu", "@evmts/zevm-linux-arm64-gnu"],
  ["linux-arm64-musl", "@evmts/zevm-linux-arm64-musl"],
  ["linux-x64-gnu", "@evmts/zevm-linux-x64-gnu"],
  ["linux-x64-musl", "@evmts/zevm-linux-x64-musl"],
  ["win32-arm64-msvc", "@evmts/zevm-win32-arm64-msvc"],
  ["win32-ia32-msvc", "@evmts/zevm-win32-ia32-msvc"],
  ["win32-x64-msvc", "@evmts/zevm-win32-x64-msvc"],
]);

function copyIfPresent(source, destination) {
  if (!fs.existsSync(source)) {
    return false;
  }
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
  return true;
}

const localNativeDestination = path.resolve(packageRoot, "native/zevm.node");
if (includeLocalNative) {
  const localNativeSource = path.resolve(zigOutNpm, "native/zevm.node");
  if (copyIfPresent(localNativeSource, localNativeDestination)) {
    console.log(`staged ${path.relative(repoRoot, localNativeDestination)}`);
  } else {
    console.warn(`missing ${path.relative(repoRoot, localNativeSource)}; run zig build npm-native`);
  }
} else {
  fs.rmSync(localNativeDestination, { force: true });
}

for (const [platformName, packageName] of platformPackages) {
  const source = path.resolve(zigOutNpm, "prebuilds", platformName, "zevm.node");
  const destination = path.resolve(platformsRoot, platformName, "zevm.node");
  if (copyIfPresent(source, destination)) {
    console.log(`staged ${path.relative(repoRoot, destination)} for ${packageName}`);
  } else {
    console.warn(`skipping ${packageName}; missing ${path.relative(repoRoot, source)}`);
  }
}
