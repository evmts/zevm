"use strict";
const { execFileSync } = require("node:child_process");
const path = require("node:path");

function run(script, ...args) {
  execFileSync(process.execPath, [path.join(__dirname, script), ...args], { stdio: "inherit" });
}

run("verify-release.cjs");
run("stage-artifacts.cjs");
run("release-tarballs.cjs", "pack");
if (!process.argv.includes("--dry-run")) run("release-tarballs.cjs", "publish");
