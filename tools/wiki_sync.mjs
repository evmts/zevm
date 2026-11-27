#!/usr/bin/env node
/**
 * Verify ZEVM's Obsidian-compatible wiki (.smithers/wiki/*.md) and mythical
 * history (.smithers/history/epics.json), and project them into the Smithers
 * Cloud `plugins/wiki` feed payload (`POST /api/repos/evmts/zevm/feeds`).
 *
 * Usage:
 *   node tools/wiki_sync.mjs --check
 *   node tools/wiki_sync.mjs --check --out .smithers/reports/wiki-feed.json
 *   SMITHERS_FEED_KEY=... node tools/wiki_sync.mjs --push
 */

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const idx = args.indexOf(name);
  return idx === -1 ? fallback : (args[idx + 1] ?? fallback);
};
const checkMode = args.includes("--check");
const pushMode = args.includes("--push");
const outPath = flag("--out", null);
const origin = flag("--origin", process.env.SMITHERS_ORIGIN || "https://smithers.sh");
const repoSlug = flag("--repo", "evmts/zevm");

const repoRoot = process.cwd();
const wikiDir = path.join(repoRoot, ".smithers/wiki");
const epicsPath = path.join(repoRoot, ".smithers/history/epics.json");
const projectPath = path.join(repoRoot, ".smithers/coding-project.json");

const errors = [];

if (!fs.existsSync(wikiDir)) {
  errors.push("missing .smithers/wiki directory");
}
if (!fs.existsSync(epicsPath)) {
  errors.push("missing .smithers/history/epics.json");
}

function parseFrontmatter(markdown) {
  const m = markdown.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) return { title: null, tags: [] };
  const body = m[1];
  const titleMatch = body.match(/^title:\s*(.+)$/m);
  const tagsMatch = body.match(/^tags:\s*\[([^\]]*)\]/m);
  const title = titleMatch ? titleMatch[1].trim().replace(/^["']|["']$/g, "") : null;
  const tags = tagsMatch
    ? tagsMatch[1]
        .split(",")
        .map((t) => t.trim().replace(/^["']|["']$/g, ""))
        .filter(Boolean)
    : [];
  return { title, tags };
}

const files = fs.existsSync(wikiDir)
  ? fs
      .readdirSync(wikiDir)
      .filter((f) => f.endsWith(".md"))
      .sort()
  : [];

const stemSet = new Set(files.map((f) => f.replace(/\.md$/, "")));
const notes = [];

for (const file of files) {
  const fullPath = path.join(wikiDir, file);
  const markdown = fs.readFileSync(fullPath, "utf8");
  const stat = fs.statSync(fullPath);
  const fm = parseFrontmatter(markdown);

  if (!fm.title) {
    errors.push(`${file}: missing YAML frontmatter title`);
  }
  if (fm.tags.length === 0) {
    errors.push(`${file}: missing YAML frontmatter tags`);
  }

  // Strip fenced code blocks before validating wikilinks and repo-path citations.
  const prose = markdown.replace(/```[\s\S]*?```/g, "");

  for (const match of prose.matchAll(/\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]/g)) {
    const target = match[1].trim().replace(/\.md$/, "");
    if (!stemSet.has(target)) {
      errors.push(`${file}: broken wikilink [[${match[1]}]]`);
    }
  }

  // Validate inline code citations that look like repository file paths.
  const ROOT_KNOWN = new Set([
    "PACKAGE.ts",
    "build.zig",
    "build.zig.zon",
    "AGENTS.md",
    "CLAUDE.md",
    "CHANGELOG.md",
    "README.md",
    "native-dependencies.json",
  ]);
  for (const match of prose.matchAll(/`([A-Za-z0-9_./-]+\.(?:zig|ts|js|mjs|cjs|json|yaml|yml|md|mdx|h|c|lean|zon|sh))`/g)) {
    const candidate = match[1];
    if (
      candidate.startsWith("http") ||
      candidate.startsWith("..") ||
      candidate.includes("*") ||
      (!candidate.includes("/") && !ROOT_KNOWN.has(candidate))
    ) {
      continue;
    }
    const resolved = path.join(repoRoot, candidate);
    if (!fs.existsSync(resolved)) {
      errors.push(`${file}: cited path does not exist: ${candidate}`);
    }
  }

  notes.push({
    path: file,
    title: fm.title || file.replace(/\.md$/, ""),
    tags: fm.tags,
    markdown,
  });
}

if (!stemSet.has("Overview")) {
  errors.push("wiki must include Overview.md");
}
if (!stemSet.has("Mythical-History")) {
  errors.push("wiki must include Mythical-History.md");
}

let epicsDoc = null;
if (fs.existsSync(epicsPath)) {
  try {
    epicsDoc = JSON.parse(fs.readFileSync(epicsPath, "utf8"));
    if (!Array.isArray(epicsDoc.epics) || epicsDoc.epics.length === 0) {
      errors.push(".smithers/history/epics.json: epics must be a non-empty array");
    } else {
      for (const epic of epicsDoc.epics) {
        if (epic.wikiPage && !fs.existsSync(path.join(wikiDir, epic.wikiPage))) {
          errors.push(`epics.json (${epic.id}): missing wikiPage ${epic.wikiPage}`);
        }
        for (const p of epic.paths ?? []) {
          if (!fs.existsSync(path.join(repoRoot, p))) {
            errors.push(`epics.json (${epic.id}): missing path ${p}`);
          }
        }
      }
    }
  } catch (err) {
    errors.push(`.smithers/history/epics.json: invalid JSON (${err.message})`);
  }
}

if (fs.existsSync(projectPath)) {
  try {
    const project = JSON.parse(fs.readFileSync(projectPath, "utf8"));
    for (const page of project.pages ?? []) {
      if (!fs.existsSync(path.join(wikiDir, page.path))) {
        errors.push(`coding-project.json: missing page ${page.path}`);
      }
      for (const src of page.sources ?? []) {
        if (!fs.existsSync(path.join(repoRoot, src))) {
          errors.push(`coding-project.json (${page.path}): missing source ${src}`);
        }
      }
    }
  } catch (err) {
    errors.push(`.smithers/coding-project.json: invalid JSON (${err.message})`);
  }
}

if (errors.length > 0) {
  for (const err of errors) console.error(`wiki-sync: ${err}`);
  process.exit(1);
}

const feedPayload = {
  set: {
    wiki: {
      visibility: "public",
      body: { notes },
    },
    ...(epicsDoc
      ? {
          mythical_history: {
            visibility: "public",
            body: epicsDoc,
          },
        }
      : {}),
  },
};

if (outPath) {
  const resolvedOut = path.resolve(repoRoot, outPath);
  fs.mkdirSync(path.dirname(resolvedOut), { recursive: true });
  fs.writeFileSync(resolvedOut, JSON.stringify(feedPayload, null, 2) + "\n");
}

if (pushMode) {
  const feedKey = process.env.SMITHERS_FEED_KEY;
  if (!feedKey) {
    console.error("wiki-sync: SMITHERS_FEED_KEY is required for --push");
    process.exit(1);
  }
  const url = `${origin.replace(/\/$/, "")}/api/repos/${repoSlug}/feeds`;
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${feedKey}`,
    },
    body: JSON.stringify(feedPayload),
  });
  if (!resp.ok) {
    const text = await resp.text();
    console.error(`wiki-sync: push failed (${resp.status}): ${text.slice(0, 300)}`);
    process.exit(1);
  }
  console.log(`wiki-sync: pushed ${notes.length} notes and ${epicsDoc?.epics?.length ?? 0} epics to ${url}`);
} else {
  console.log(
    `wiki-sync: ok (${notes.length} notes, ${epicsDoc?.epics?.length ?? 0} epics${outPath ? `, wrote ${outPath}` : ""})`,
  );
}
