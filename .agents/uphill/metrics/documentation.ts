import { Glob } from "bun";
import { appendFileSync, existsSync, readFileSync } from "fs";
import { dirname, resolve } from "path";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

// 1. Astro/Starlight docs mirror parity via `node tools/docs_mirror.mjs`
const mirrorProc = Bun.spawnSync(["node", "tools/docs_mirror.mjs"], {
  stdout: "pipe",
  stderr: "pipe",
});
if (mirrorProc.exitCode === 0) {
  lines.push("docs-mirror docs/src/content/docs pass");
} else {
  const msg =
    `${mirrorProc.stderr.toString()}\n${mirrorProc.stdout.toString()}`
      .trim()
      .split("\n")[0] || "run node tools/docs_mirror.mjs --write";
  lines.push(`docs-mirror docs/src/content/docs fail note ${q(msg)}`);
}

// 2. Broken local links in primary root *.md and docs/**/*.{md,mdx} (excluding generated mirror)
const primaryDocs = [
  ...new Glob("*.md").scanSync("."),
  ...new Glob("docs/**/*.md").scanSync("."),
  ...new Glob("docs/**/*.mdx").scanSync("."),
]
  .filter((f) => !f.startsWith("docs/src/content/docs/") && !f.startsWith("docs/public/") && !f.includes("node_modules/"))
  .sort();

for (const file of primaryDocs) {
  const stripped = readFileSync(file, "utf8").replace(/```[\s\S]*?```/g, "");
  let broken: string | null = null;
  for (const m of stripped.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
    const target = m[1]!.trim().split(/\s+/)[0]!;
    if (
      !target ||
      target.startsWith("http://") ||
      target.startsWith("https://") ||
      target.startsWith("mailto:") ||
      target.startsWith("#") ||
      target.startsWith("data:")
    ) {
      continue;
    }
    const clean = target
      .split("#")[0]!
      .split("?")[0]!
      .replace(/:\d+(?:-\d+)?$/, "")
      .replace(/\/$/, "");
    if (!clean) continue;
    const candidates = clean.startsWith("/")
      ? [resolve(".", clean.slice(1)), resolve("docs", clean.slice(1))]
      : [resolve(dirname(file), clean)];
    const ok = candidates.some(
      (c) =>
        existsSync(c) ||
        existsSync(`${c}.md`) ||
        existsSync(`${c}.mdx`) ||
        existsSync(`${c}/index.md`) ||
        existsSync(`${c}/index.mdx`),
    );
    if (!ok) {
      broken = `broken link: ${target}`;
      break;
    }
  }
  const item = /\s/.test(file) ? q(file) : file;
  lines.push(
    broken
      ? `broken-links ${item} fail note ${q(broken)}`
      : `broken-links ${item} pass`,
  );
}

appendFileSync(out, lines.join("\n") + "\n");
