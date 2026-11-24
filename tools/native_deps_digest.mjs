#!/usr/bin/env node
// Writes a content digest of the sibling native dependencies that build.zig.zon
// resolves by path (../voltaire and ../guillotine-mini).
//
// Smithers cache keys only cover files inside this workspace, so every Zig
// target declares the digest file as an input: editing a sibling checkout, or
// checking out a different pin, changes the digest and invalidates dependent
// results. scripts/smthrs and CI regenerate it before every smthrs run. The
// digest is VCS-agnostic (git, colocated jj, and plain jj workspaces).
//
// Usage: node tools/native_deps_digest.mjs [out-file]   (default .native-deps.digest)
import { createHash } from "node:crypto"
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { dirname, join, relative } from "node:path"

const root = join(dirname(new URL(import.meta.url).pathname), "..")
const out = process.argv[2] ?? ".native-deps.digest"

const dependencies = ["voltaire", "guillotine-mini"]
const skipDirs = new Set([
  ".git", ".jj", ".zig-cache", "zig-cache", "zig-out", "target", "node_modules",
  ".smithers", ".flows", "dist", "docs", "skills",
])
// Sources that can change compiled output or the Rust/C archives build.zig links.
const keepFile = (name) =>
  /\.(zig|zon|c|h|rs|s|S|toml|lock)$/.test(name) || name === "Makefile" || name === "CMakeLists.txt"

const walk = (dir, files) => {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const path = join(dir, entry.name)
    let isDir = entry.isDirectory()
    let isFile = entry.isFile()
    if (entry.isSymbolicLink()) {
      try {
        const s = statSync(path)
        isDir = s.isDirectory()
        isFile = s.isFile()
      } catch {
        continue
      }
    }
    if (isDir) {
      if (!skipDirs.has(entry.name)) walk(path, files)
    } else if (isFile && keepFile(entry.name)) {
      files.push(path)
    }
  }
}

const lines = []
for (const name of dependencies) {
  const base = join(root, "..", name)
  const files = []
  walk(base, files)
  if (files.length === 0) {
    console.error(`native-deps-digest: ../${name} is missing; run tools/checkout-native.sh`)
    process.exit(1)
  }
  files.sort()
  const hash = createHash("sha256")
  for (const file of files) {
    hash.update(relative(base, file))
    hash.update("\0")
    hash.update(readFileSync(file))
    hash.update("\0")
  }
  lines.push(`${name} files=${files.length} sha256=${hash.digest("hex")}`)
}

const target = join(root, out)
const text = `${lines.join("\n")}\n`
let previous
try {
  previous = readFileSync(target, "utf8")
} catch {}
// Leave an unchanged digest untouched so the file's bytes stay the only key input.
if (previous !== text) {
  mkdirSync(dirname(target), { recursive: true })
  writeFileSync(target, text)
}
