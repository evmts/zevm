#!/usr/bin/env node
// Keeps the Starlight content tree (docs/src/content/docs) a mirror of the
// authored docs (docs/**/*.md{,x} outside docs/src and docs/_snippets).
//
//   node tools/docs_mirror.mjs           # fail when the mirror has drifted
//   node tools/docs_mirror.mjs --write   # rewrite the mirror from docs/
//
// Starlight requires a `title` in frontmatter. A source page without
// frontmatter keeps the mirror's existing frontmatter, or gets one built from
// its first `# ` heading.
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "docs");
const mirror = join(root, "src", "content", "docs");
const skipped = new Set(["src", "node_modules", "_snippets", "dist"]);

function pages(dir, base, skip) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    const rel = relative(base, path);
    if (skip && skipped.has(rel.split(sep)[0])) continue;
    if (entry.isDirectory()) out.push(...pages(path, base, skip));
    else if (/\.mdx?$/.test(entry.name)) out.push(rel);
  }
  return out.sort();
}

function frontmatter(text) {
  if (!text.startsWith("---\n")) return null;
  const end = text.indexOf("\n---\n", 4);
  return end === -1 ? null : text.slice(0, end + 5);
}

export function mirrorText(source, existing) {
  if (frontmatter(source)) return source;
  let head = existing === undefined ? null : frontmatter(existing);
  if (!head) {
    const heading = /^# (.+)$/m.exec(source);
    if (!heading) throw new Error("page has no frontmatter and no `# ` heading");
    head = `---\ntitle: ${JSON.stringify(heading[1].trim())}\n---\n`;
  }
  return `${head}\n${source}`;
}

function main() {
  const write = process.argv.includes("--write");
  const sources = pages(root, root, true);
  const problems = [];
  for (const rel of sources) {
    const target = join(mirror, rel);
    const existing = existsSync(target) ? readFileSync(target, "utf8") : undefined;
    let expected;
    try {
      expected = mirrorText(readFileSync(join(root, rel), "utf8"), existing);
    } catch (error) {
      problems.push(`docs/${rel}: ${error.message}`);
      continue;
    }
    if (existing === expected) continue;
    if (write) {
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, expected);
    }
    problems.push(`docs/src/content/docs/${rel}: ${existing === undefined ? "missing" : "differs from docs/" + rel}`);
  }
  const known = new Set(sources);
  for (const rel of existsSync(mirror) ? pages(mirror, mirror, false) : []) {
    if (known.has(rel)) continue;
    if (write) rmSync(join(mirror, rel));
    problems.push(`docs/src/content/docs/${rel}: no source page at docs/${rel}`);
  }
  if (problems.length === 0) {
    console.log(`docs-mirror: ok (${sources.length} pages)`);
    return;
  }
  for (const problem of problems) console.error(`docs-mirror: ${problem}`);
  if (write) {
    console.log(`docs-mirror: wrote ${problems.length} change(s)`);
    return;
  }
  console.error("docs-mirror: run `node tools/docs_mirror.mjs --write` after editing docs/");
  process.exit(1);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
