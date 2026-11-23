#!/usr/bin/env node
// Verifies that every bench/<suite>/PACKAGE.ts declares every transitive local Zig source
// dependency reachable from bench/<suite>/main.zig, and does NOT use a blanket src/** glob.
// This guarantees Smithers incremental caching and `affected` selection stay sound and minimal.

import fs from "node:fs";
import path from "node:path";

const root = process.cwd();

function parseRootExports() {
  const rootSrc = fs.readFileSync(path.join(root, "src/root.zig"), "utf8");
  const exports = new Map();
  const re = /pub const (\w+)\s*=\s*@import\("([^"]+\.zig)"\)/g;
  for (const m of rootSrc.matchAll(re)) {
    exports.set(m[1], path.posix.normalize(path.posix.join("src", m[2])));
  }
  // Handle `pub const log = log_mod;` where `const log_mod = @import("log.zig");`
  const aliasImports = new Map();
  for (const m of rootSrc.matchAll(/const (\w+)\s*=\s*@import\("([^"]+\.zig)"\)/g)) {
    aliasImports.set(m[1], path.posix.normalize(path.posix.join("src", m[2])));
  }
  for (const m of rootSrc.matchAll(/pub const (\w+)\s*=\s*(\w+)\s*;/g)) {
    if (aliasImports.has(m[2])) {
      exports.set(m[1], aliasImports.get(m[2]));
    }
  }
  return exports;
}

function collectTransitiveZigImports(entryFiles) {
  const visited = new Set();
  const queue = [...entryFiles];
  while (queue.length > 0) {
    const rel = queue.shift();
    if (visited.has(rel)) continue;
    const abs = path.join(root, rel);
    if (!fs.existsSync(abs)) continue;
    visited.add(rel);
    const text = fs.readFileSync(abs, "utf8");
    const dir = path.posix.dirname(rel);
    for (const m of text.matchAll(/@import\("([^"]+\.zig)"\)/g)) {
      const target = path.posix.normalize(path.posix.join(dir, m[1]));
      if (target.startsWith("src/") && !target.endsWith("_test.zig") && !visited.has(target)) {
        queue.push(target);
      }
    }
  }
  return [...visited].filter((p) => p.startsWith("src/")).sort();
}

function parseDeclaredFiles(packageTsPath, pkgRelDir) {
  const text = fs.readFileSync(packageTsPath, "utf8");
  const files = new Set();
  for (const m of text.matchAll(/S\.file\("([^"]+)"\)/g)) {
    const raw = m[1];
    const resolved = raw.startsWith("//")
      ? raw.slice(2)
      : path.posix.normalize(path.posix.join(pkgRelDir, raw));
    files.add(resolved);
  }
  const srcsBlock = text.match(/srcs\s*:\s*\[([\s\S]*?)\]/);
  if (srcsBlock) {
    for (const m of srcsBlock[1].matchAll(/"([^"]+)"/g)) {
      const raw = m[1];
      files.add(raw.startsWith("//") ? raw.slice(2) : raw);
    }
  }
  const globs = [];
  for (const m of text.matchAll(/S\.glob\("([^"]+)"\)/g)) {
    globs.push(m[1]);
  }
  return { files, globs };
}

function matchesSimpleGlob(filePath, pattern) {
  const normalized = pattern.startsWith("//") ? pattern.slice(2) : pattern;
  if (normalized.endsWith("/**")) {
    const prefix = normalized.slice(0, -3);
    return filePath === prefix || filePath.startsWith(`${prefix}/`);
  }
  if (normalized.endsWith("/*.zig")) {
    const prefix = normalized.slice(0, -6);
    return path.posix.dirname(filePath) === prefix && filePath.endsWith(".zig");
  }
  return filePath === normalized;
}

const rootExports = parseRootExports();
const benchDir = path.join(root, "bench");
const suites = fs
  .readdirSync(benchDir, { withFileTypes: true })
  .filter((d) => d.isDirectory() && fs.existsSync(path.join(benchDir, d.name, "main.zig")))
  .map((d) => d.name)
  .sort();

let failures = 0;

for (const suite of suites) {
  const mainPath = path.join(benchDir, suite, "main.zig");
  const pkgPath = path.join(benchDir, suite, "PACKAGE.ts");
  if (!fs.existsSync(pkgPath)) {
    console.error(`FAIL [${suite}]: missing bench/${suite}/PACKAGE.ts`);
    failures += 1;
    continue;
  }

  const mainSrc = fs.readFileSync(mainPath, "utf8");
  const seeds = new Set();
  for (const m of mainSrc.matchAll(/\bzevm\.(\w+)\b/g)) {
    const exported = rootExports.get(m[1]);
    if (exported) seeds.add(exported);
  }
  if (mainSrc.includes("zevm_node_create") || mainSrc.includes("zevm_abi_version")) {
    seeds.add("src/c_bindings.zig");
  }

  const required = collectTransitiveZigImports([...seeds]);
  const { files, globs } = parseDeclaredFiles(pkgPath, `bench/${suite}`);

  if (globs.some((g) => g === "//src/**" || g === "src/**")) {
    console.error(`FAIL [${suite}]: PACKAGE.ts must not use blanket src/** glob (breaks incremental caching)`);
    failures += 1;
  }

  const missing = required.filter(
    (req) => !files.has(req) && !globs.some((g) => matchesSimpleGlob(req, g))
  );
  if (missing.length > 0) {
    console.error(`FAIL [${suite}]: bench/${suite}/PACKAGE.ts is missing transitive src inputs:`);
    for (const m of missing) {
      console.error(`    S.file("//${m}"),`);
    }
    failures += 1;
  }
}

if (failures > 0) {
  process.exit(1);
}
console.log(`bench-deps-check: all ${suites.length} benchmark PACKAGE.ts declarations cover their exact transitive Zig inputs.`);
