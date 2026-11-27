#!/usr/bin/env node
/**
 * Generate docs/public/llms.txt, docs/public/llms-full.txt, and clean Markdown
 * mirrors under docs/public/raw/<slug>.md so https://zevm.sh/docs/llms.txt and
 * Smithers Cloud MCP (docs_list / docs_read) index every ZEVM doc page.
 *
 * Usage:
 *   node tools/generate_llms_txt.mjs --write
 *   node tools/generate_llms_txt.mjs --check
 */

import fs from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();
const docsRoot = path.join(repoRoot, "docs");
const publicDir = path.join(docsRoot, "public");
const rawDir = path.join(publicDir, "raw");
const siteOrigin = "https://zevm.sh";
const docsBase = "/docs";
const writeMode = process.argv.includes("--write");
const checkMode = process.argv.includes("--check") || !writeMode;

const SECTION_ORDER = [
  { key: "overview", label: "Overview" },
  { key: "quickstart", label: "Quickstart" },
  { key: "concepts", label: "Concepts" },
  { key: "reference/configuration", label: "Configuration Reference" },
  { key: "reference/library", label: "Library Reference" },
  { key: "reference/json-rpc", label: "JSON-RPC Reference" },
  { key: "reference", label: "Reference & Release Gates" },
  { key: "specs", label: "Canonical Specs" },
];

function walkDocs(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (
      entry.name === "node_modules" ||
      entry.name === "dist" ||
      entry.name === "public" ||
      entry.name === ".astro" ||
      entry.name === ".vercel" ||
      entry.name === "src"
    ) {
      continue;
    }
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkDocs(full, out);
    } else if (entry.isFile() && /\.(?:md|mdx)$/.test(entry.name)) {
      const rel = path.relative(docsRoot, full).split(path.sep).join("/");
      if (rel.startsWith("specs/internal/") || rel.startsWith("specs/qualification/")) continue;
      out.push({ rel, full });
    }
  }
  return out;
}

function parsePage(rel, raw) {
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---\n?/);
  let title = "";
  let description = "";
  let body = raw;
  if (fmMatch) {
    const fm = fmMatch[1];
    const t = fm.match(/^title:\s*(.+)$/m);
    const d = fm.match(/^description:\s*(.+)$/m);
    if (t) title = t[1].trim().replace(/^["']|["']$/g, "");
    if (d) description = d[1].trim().replace(/^["']|["']$/g, "");
    body = raw.slice(fmMatch[0].length).trimStart();
  }
  if (!title) {
    const h1 = body.match(/^#\s+(.+)$/m);
    title = h1 ? h1[1].trim() : rel.replace(/\.(?:md|mdx)$/, "");
  }
  if (!description) {
    const firstPara = body
      .replace(/^#.*$/gm, "")
      .replace(/```[\s\S]*?```/g, "")
      .split(/\n\s*\n/)
      .map((s) => s.replace(/\s+/g, " ").trim())
      .find((s) => s.length > 15 && !s.startsWith("|") && !s.startsWith("import "));
    description = (firstPara || `ZEVM documentation page ${title}`).slice(0, 220);
  }
  const slug = rel.replace(/\.(?:md|mdx)$/, "");
  const cleanMd = `# ${title}\n\n${body.trim()}\n`;
  return { rel, slug, title: title.slice(0, 180), description: description.slice(0, 260), cleanMd };
}

function sectionKeyFor(slug) {
  if (slug === "index") return "overview";
  for (const s of SECTION_ORDER) {
    if (s.key !== "overview" && slug.startsWith(`${s.key}/`)) return s.key;
  }
  return "overview";
}

const docFiles = walkDocs(docsRoot).sort((a, b) => a.rel.localeCompare(b.rel));
const pages = docFiles.map(({ rel, full }) => parsePage(rel, fs.readFileSync(full, "utf8")));

const grouped = new Map(SECTION_ORDER.map((s) => [s.key, []]));
for (const page of pages) {
  const key = sectionKeyFor(page.slug);
  grouped.get(key).push(page);
}

const llmsLines = [
  "# ZEVM",
  "",
  "> Embeddable Zig Ethereum execution and proof-backed light-client node powered by pinned Voltaire and Guillotine Mini, with C ABI, Node-API, browser WASM, Lean 4 formal spec, and Smithers Cloud coding factory.",
  "",
  `- Coding Factory: https://smithers.sh/evmts/zevm`,
  `- Public MCP Server: https://smithers.sh/evmts/zevm/mcp`,
  `- Lighthouse Backpressure Audit: ${siteOrigin}${docsBase}/audit/`,
  `- Full Markdown Bundle: ${siteOrigin}${docsBase}/llms-full.txt`,
  "",
];

for (const section of SECTION_ORDER) {
  const list = grouped.get(section.key) || [];
  if (list.length === 0) continue;
  llmsLines.push(`## ${section.label}`, "");
  for (const page of list) {
    const url = `${siteOrigin}${docsBase}/raw/${page.slug}.md`;
    llmsLines.push(`- [${page.title}](${url}): ${page.description}`);
  }
  llmsLines.push("");
}

const llmsTxt = llmsLines.join("\n").trimEnd() + "\n";
const llmsFullTxt =
  `# ZEVM Documentation (Full Bundle)\n\n` +
  pages
    .map((p) => `---\nSource: ${siteOrigin}${docsBase}/raw/${p.slug}.md\n---\n\n${p.cleanMd}`)
    .join("\n");

const llmsPath = path.join(publicDir, "llms.txt");
const llmsFullPath = path.join(publicDir, "llms-full.txt");

if (writeMode) {
  fs.mkdirSync(rawDir, { recursive: true });
  fs.writeFileSync(llmsPath, llmsTxt);
  fs.writeFileSync(llmsFullPath, llmsFullTxt);
  for (const page of pages) {
    const dest = path.join(rawDir, `${page.slug}.md`);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, page.cleanMd);
  }
  console.log(`llms-txt: wrote ${pages.length} markdown pages + docs/public/llms.txt`);
} else if (checkMode) {
  const errors = [];
  if (!fs.existsSync(llmsPath) || fs.readFileSync(llmsPath, "utf8") !== llmsTxt) {
    errors.push("docs/public/llms.txt is missing or out of date (run node tools/generate_llms_txt.mjs --write)");
  }
  if (!fs.existsSync(llmsFullPath) || fs.readFileSync(llmsFullPath, "utf8") !== llmsFullTxt) {
    errors.push("docs/public/llms-full.txt is missing or out of date");
  }
  for (const page of pages) {
    const dest = path.join(rawDir, `${page.slug}.md`);
    if (!fs.existsSync(dest) || fs.readFileSync(dest, "utf8") !== page.cleanMd) {
      errors.push(`docs/public/raw/${page.slug}.md is missing or out of date`);
      break;
    }
  }
  if (errors.length > 0) {
    for (const e of errors) console.error(`llms-txt: ${e}`);
    process.exit(1);
  }
  console.log(`llms-txt: ok (${pages.length} indexed pages)`);
}
