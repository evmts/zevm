#!/usr/bin/env node
/**
 * Projects `.smithers/HOME.mjs` into `.smithers/home.json` and validates
 * Smithers Cloud 3-audience homepage invariants:
 * - Required audiences: `maintainer`, `contributor`, `everyone`
 * - `contributors: "role"` (distinct contributor vs signed-out viewer surfaces)
 * - `docs` points to `https://.../llms.txt`
 * - Zero `markdown` blocks (so Smithers Cloud renders immediately pre-clone)
 * - Clean copy discipline (no em dashes or semicolons in UI text)
 *
 * Usage:
 *   node tools/home_projection.mjs --write
 *   node tools/home_projection.mjs --check
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const sourcePath = path.join(repoRoot, ".smithers/HOME.mjs");
const outputPath = path.join(repoRoot, ".smithers/home.json");

const mode = process.argv.includes("--write") ? "write" : "check";

const mod = await import(pathToFileURL(sourcePath).href);
const home = mod.home;
if (!home || typeof home !== "object") {
  console.error("home-projection: .smithers/HOME.mjs must export `home`");
  process.exit(1);
}

const errors = [];
if (typeof home.docs !== "string" || !/^https:\/\/.+\/llms\.txt$/.test(home.docs)) {
  errors.push(`home.docs must be an https://.../llms.txt URL (got ${JSON.stringify(home.docs)})`);
}
if (home.contributors !== "role" && home.contributors !== "anyone") {
  errors.push(`home.contributors must be "role" or "anyone" (got ${JSON.stringify(home.contributors)})`);
}
if (!Array.isArray(home.sections) || home.sections.length === 0) {
  errors.push("home.sections must be a non-empty array");
} else {
  const audiences = new Set(home.sections.map((s) => s.audience));
  for (const req of ["maintainer", "contributor", "everyone"]) {
    if (!audiences.has(req)) errors.push(`missing required audience section: ${req}`);
  }
  const allowedBlocks = new Set([
    "action",
    "issues",
    "stack",
    "runs",
    "flows",
    "links",
    "code",
    "cards",
    "hero",
    "stats",
    "releases",
  ]);
  for (const sec of home.sections) {
    if (!Array.isArray(sec.blocks) || sec.blocks.length === 0) {
      errors.push(`section ${sec.audience} has no blocks`);
      continue;
    }
    for (const block of sec.blocks) {
      if (block.type === "markdown") {
        errors.push(`section ${sec.audience} contains forbidden markdown block (blocks pre-clone paint)`);
      }
      if (!allowedBlocks.has(block.type)) {
        errors.push(`section ${sec.audience} has unknown block type: ${block.type}`);
      }
      // Check prose fields (excluding code snippets) for em dashes or semicolons.
      const proseFields = [
        block.title,
        block.tagline,
        block.text,
        block.announcement?.label,
        ...(block.cards ?? []).flatMap((c) => [c.label, c.title, c.text]),
        ...(block.releases ?? []).map((r) => r.summary),
      ].filter((v) => typeof v === "string");
      for (const text of proseFields) {
        if (text.includes("—") || text.includes(";")) {
          errors.push(`copy style violation (em dash or semicolon) in ${sec.audience}/${block.type}: ${text.slice(0, 80)}`);
        }
      }
    }
  }
}

if (errors.length > 0) {
  for (const err of errors) console.error(`home-projection: ${err}`);
  process.exit(1);
}

const serialized = JSON.stringify(home, null, 2) + "\n";
if (mode === "write") {
  fs.writeFileSync(outputPath, serialized);
  console.log(`home-projection: wrote .smithers/home.json (${home.sections.length} sections)`);
  process.exit(0);
}

if (!fs.existsSync(outputPath)) {
  console.error("home-projection: .smithers/home.json does not exist (run --write)");
  process.exit(1);
}
const existing = fs.readFileSync(outputPath, "utf8");
if (existing !== serialized) {
  console.error("home-projection: .smithers/home.json is out of sync with .smithers/HOME.mjs (run node tools/home_projection.mjs --write)");
  process.exit(1);
}
console.log(`home-projection: ok (${home.sections.length} audiences, docs=${home.docs})`);
