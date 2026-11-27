#!/usr/bin/env node
/**
 * Generate a Lighthouse-style Backpressure Audit Report (HTML, Smithers Factory
 * feed JSON, and PR comment Markdown) from Uphill metrics (.uphill/report.json)
 * and ZEVM repository provenance.
 *
 * Usage:
 *   node tools/audit_report.mjs [--run] [--input .uphill/report.json]
 *     [--out .uphill/audit-report.html]
 *     [--publish-docs docs/public/audit/index.html]
 *     [--feed-out .uphill/factory-feed.json]
 *     [--md-out .uphill/audit-comment.md]
 *     [--trust auto|controlled-sandbox|maintainer|untrusted]
 */

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
function flag(name, fallback = null) {
  const idx = args.indexOf(name);
  if (idx === -1) return fallback;
  return args[idx + 1] ?? fallback;
}
const hasFlag = (name) => args.includes(name);

const repoRoot = process.cwd();
const inputPath = path.resolve(repoRoot, flag("--input", ".uphill/report.json"));
const outHtmlPath = path.resolve(repoRoot, flag("--out", ".uphill/audit-report.html"));
const publishDocsPath = flag("--publish-docs", null)
  ? path.resolve(repoRoot, flag("--publish-docs"))
  : null;
const feedOutPath = path.resolve(repoRoot, flag("--feed-out", ".uphill/factory-feed.json"));
const mdOutPath = path.resolve(repoRoot, flag("--md-out", ".uphill/audit-comment.md"));
const trustArg = flag("--trust", "auto");

if (hasFlag("--run") || !fs.existsSync(inputPath)) {
  const uphillBin = findUphillBin();
  if (!uphillBin) {
    console.error("audit_report: uphill binary not found on PATH or at ~/.uphill/bin/uphill");
    process.exit(1);
  }
  const res = spawnSync(uphillBin, ["--compact"], {
    cwd: repoRoot,
    stdio: "inherit",
    env: {
      ...process.env,
      PATH: prependZig015(process.env.PATH ?? ""),
    },
  });
  if (res.status !== 0) {
    process.exit(res.status ?? 1);
  }
}

function findUphillBin() {
  const candidates = [
    process.env.UPHILL_BIN,
    path.join(process.env.HOME ?? "", ".uphill", "bin", "uphill"),
    "uphill",
  ].filter(Boolean);
  for (const bin of candidates) {
    if (bin === "uphill") {
      const probe = spawnSync("which", ["uphill"], { encoding: "utf8" });
      if (probe.status === 0 && probe.stdout.trim()) return probe.stdout.trim();
    } else if (fs.existsSync(bin)) {
      return bin;
    }
  }
  return null;
}

function prependZig015(currentPath) {
  const zvmZigDir = path.join(process.env.HOME ?? "", ".zvm", "0.15.2");
  if (fs.existsSync(path.join(zvmZigDir, "zig"))) {
    return `${zvmZigDir}:${currentPath}`;
  }
  return currentPath;
}

function safeReadJson(filePath, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

function detectVcsInfo() {
  if (process.env.GITHUB_SHA) {
    return {
      sha: process.env.GITHUB_SHA,
      shortSha: process.env.GITHUB_SHA.slice(0, 8),
      ref: process.env.GITHUB_REF_NAME || process.env.GITHUB_REF || "main",
      author: process.env.GITHUB_ACTOR || "ci",
      summary: process.env.GITHUB_EVENT_NAME || "ci",
    };
  }
  try {
    const out = execFileSync(
      "jj",
      [
        "--no-pager",
        "log",
        "-r",
        "@-",
        "--no-graph",
        "-T",
        'commit_id ++ "\\n" ++ commit_id.short(8) ++ "\\n" ++ author.name() ++ "\\n" ++ description.first_line()',
      ],
      { cwd: repoRoot, encoding: "utf8" },
    ).trim();
    const [sha = "unknown", shortSha = "unknown", author = "local", summary = ""] = out.split("\n");
    return { sha, shortSha, ref: "main", author, summary };
  } catch {
    return { sha: "unknown", shortSha: "unknown", ref: "local", author: "local", summary: "" };
  }
}

function resolveTrust(mode) {
  if (mode === "controlled-sandbox") {
    return {
      level: "controlled-sandbox",
      label: "Controlled Sandbox",
      summary: "Executed inside a Smithers Cloud controlled sandbox on exact target SHA. Cache write allowed on main only. Gate authoritative.",
      cachePolicy: "read+write (main only)",
      gateAuthoritative: true,
    };
  }
  if (mode === "maintainer") {
    return {
      level: "maintainer",
      label: "Maintainer Verified",
      summary: "Executed on maintainer host with pinned native dependencies. Advisory locally, authoritative once verified on main CI.",
      cachePolicy: "read-only (local)",
      gateAuthoritative: true,
    };
  }
  if (mode === "untrusted") {
    return {
      level: "untrusted",
      label: "Untrusted External Run",
      summary: "Contributor execution is encouraged and visible here, but results are advisory only. Trunk cache writes and gate bypasses are blocked.",
      cachePolicy: "read-only (PR namespace isolated)",
      gateAuthoritative: false,
    };
  }
  // auto
  const isPR =
    process.env.GITHUB_EVENT_NAME === "pull_request" ||
    process.env.SMITHERS_TRUST === "untrusted";
  if (isPR) return resolveTrust("untrusted");
  if (process.env.GITHUB_ACTIONS === "true" || process.env.SMITHERS_SANDBOX === "1") {
    return resolveTrust("controlled-sandbox");
  }
  return resolveTrust("maintainer");
}

function band(score) {
  if (score >= 90) return "pass";
  if (score >= 50) return "average";
  return "fail";
}

function grade(score) {
  if (score >= 95) return "A+";
  if (score >= 90) return "A";
  if (score >= 85) return "A-";
  if (score >= 80) return "B+";
  if (score >= 70) return "B";
  if (score >= 60) return "C";
  if (score >= 50) return "D";
  return "F";
}

function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatMetricValue(metric) {
  if (metric.kind === "check") {
    const items = Array.isArray(metric.items) ? metric.items : [];
    const passed = items.filter((i) => i.value === true).length;
    if (items.length > 0) return `${passed}/${items.length} pass`;
    return metric.value === 1 || metric.value === true ? "pass" : "fail";
  }
  const v = metric.value;
  if (v === null || v === undefined) return "n/a";
  if (metric.unit === "B") {
    if (v >= 1024 * 1024) return `${(v / (1024 * 1024)).toFixed(1)} MB`;
    if (v >= 1024) return `${(v / 1024).toFixed(1)} kB`;
    return `${v} B`;
  }
  const rounded = typeof v === "number" ? (Number.isInteger(v) ? String(v) : v.toFixed(1)) : String(v);
  return metric.unit ? `${rounded} ${metric.unit}` : rounded;
}

function formatTarget(metric) {
  if (metric.target === null || metric.target === undefined) {
    return metric.kind === "check" ? "100% pass" : "baseline";
  }
  const t = metric.target;
  if (metric.unit === "B") {
    if (t >= 1024 * 1024) return `${(t / (1024 * 1024)).toFixed(1)} MB`;
    if (t >= 1024) return `${(t / 1024).toFixed(1)} kB`;
    return `${t} B`;
  }
  return metric.unit ? `${t} ${metric.unit}` : String(t);
}

const report = safeReadJson(inputPath);
if (!report || !Array.isArray(report.categories)) {
  console.error(`audit_report: invalid or missing Uphill report at ${inputPath}`);
  process.exit(1);
}

const nativePins = safeReadJson(path.join(repoRoot, "native-dependencies.json"), {});
const stateBaseline = safeReadJson(path.join(repoRoot, "tools/latest_fork_state_baseline.json"), {});
const qualMap = safeReadJson(path.join(repoRoot, "docs/specs/qualification/assertion-map.json"), {});
const factoryJson = safeReadJson(path.join(repoRoot, ".smithers/factory.json"), {});
const homeJson = safeReadJson(path.join(repoRoot, ".smithers/home.json"), {});
const vcs = detectVcsInfo();
const trust = resolveTrust(trustArg);
const generatedAt = new Date().toISOString();

const categories = report.categories.map((cat) => {
  const metrics = Array.isArray(cat.metrics) ? cat.metrics : [];
  let failingItems = 0;
  let passingItems = 0;
  for (const m of metrics) {
    if (Array.isArray(m.items) && m.items.length > 0) {
      for (const item of m.items) {
        const ok = m.kind === "check"
          ? item.value === true
          : m.target == null
            ? true
            : m.better === "higher"
              ? item.value >= m.target
              : item.value <= m.target;
        if (ok) passingItems++;
        else failingItems++;
      }
    } else if (m.score >= 90) {
      passingItems++;
    } else {
      failingItems++;
    }
  }
  return {
    ...cat,
    band: band(cat.score),
    grade: grade(cat.score),
    passingItems,
    failingItems,
  };
});

const overallScore = categories.length > 0
  ? Math.round(categories.reduce((acc, c) => acc + c.score, 0) / categories.length)
  : 0;
const overallBand = band(overallScore);
const overallGrade = grade(overallScore);

const opportunities = (Array.isArray(report.opportunities) ? report.opportunities : []).slice(0, 15);
const changes = Array.isArray(report.changes) ? report.changes : [];

const sumValues = (obj) =>
  Object.values(obj ?? {}).reduce((a, b) => a + (typeof b === "number" ? b : 0), 0);
const cancunPassed = sumValues(stateBaseline?.minimumPassed?.Cancun);
const praguePassed = sumValues(stateBaseline?.minimumPassed?.Prague);
const cancunTotal = 19732;
const pragueTotal = 17992;
const qualRecords = Array.isArray(qualMap?.records) ? qualMap.records : [];
const qualCovered = qualRecords.filter((r) => r.coverageStatus === "covered").length;

const feedPayload = {
  set: {
    backpressure: {
      visibility: "public",
      body: {
        schemaVersion: "zevm-backpressure-audit.v1",
        generatedAt,
        repository: "evmts/zevm",
        revision: vcs.sha,
        shortSha: vcs.shortSha,
        ref: vcs.ref,
        trust,
        overall: { score: overallScore, grade: overallGrade, band: overallBand },
        categories: categories.map((c) => ({
          name: c.name,
          title: c.title,
          score: c.score,
          grade: c.grade,
          band: c.band,
          passingItems: c.passingItems,
          failingItems: c.failingItems,
        })),
        opportunities: opportunities.slice(0, 10),
        changes,
        conformance: {
          cancun: { passed: cancunPassed, total: cancunTotal },
          prague: { passed: praguePassed, total: pragueTotal },
          qualification: { covered: qualCovered, total: qualRecords.length },
          pins: {
            voltaire: nativePins?.voltaire?.revision ?? null,
            guillotineMini: nativePins?.["guillotine-mini"]?.revision ?? null,
          },
        },
      },
    },
    grades: {
      visibility: "public",
      body: {
        generatedAt,
        revision: vcs.shortSha,
        overallScore,
        overallGrade,
        trustLevel: trust.level,
        categories: Object.fromEntries(categories.map((c) => [c.name, { score: c.score, grade: c.grade }])),
      },
    },
  },
};

function renderGaugeSvg(score, size = 96, stroke = 7) {
  const radius = (size - stroke) / 2;
  const circ = 2 * Math.PI * radius;
  const clamped = Math.max(0, Math.min(100, Number(score) || 0));
  const offset = circ * (1 - clamped / 100);
  const b = band(clamped);
  return `<svg class="gauge-svg gauge-${b}" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">
    <circle class="gauge-track" cx="${size / 2}" cy="${size / 2}" r="${radius}" stroke-width="${stroke}" />
    <circle class="gauge-arc" cx="${size / 2}" cy="${size / 2}" r="${radius}" stroke-width="${stroke}"
      stroke-dasharray="${circ.toFixed(2)}" stroke-dashoffset="${offset.toFixed(2)}"
      transform="rotate(-90 ${size / 2} ${size / 2})" />
    <text class="gauge-value" x="50%" y="52%" dominant-baseline="middle" text-anchor="middle">${clamped}</text>
  </svg>`;
}

function buildFixPrompt(opp) {
  const cat = opp.category ?? "";
  const metric = opp.metric ?? opp.title ?? "";
  const item = opp.item ? ` on ${opp.item}` : "";
  return [
    `Fix Uphill backpressure opportunity in evmts/zevm:`,
    `- Category: ${cat}`,
    `- Metric: ${metric}${item}`,
    `- Current: ${opp.value ?? "fail"} -> Target: ${opp.target ?? "pass"} (+${opp.gain ?? 0} pts)`,
    `- Verify with: uphill ${cat} --compact && node tools/audit_report.mjs`,
    `- Keep all work inside Smithers Cloud / jj workflow and never modify protected paths without maintainer approval.`,
  ].join("\n");
}

function renderMetricBlock(cat, metric) {
  const mBand = band(metric.score ?? 0);
  const items = Array.isArray(metric.items) ? metric.items : [];
  const failing = items.filter((it) => {
    if (metric.kind === "check") return it.value !== true;
    if (metric.target == null) return false;
    return metric.better === "higher" ? it.value < metric.target : it.value > metric.target;
  });
  const passing = items.filter((it) => !failing.includes(it));
  const statusAttr = failing.length > 0 || (items.length === 0 && (metric.score ?? 0) < 90) ? "fail" : "pass";

  const rowsHtml = [...failing.slice(0, 40), ...passing.slice(0, 15)]
    .map((it) => {
      const ok = !failing.includes(it);
      const valText =
        metric.kind === "check"
          ? ok ? "pass" : "fail"
          : metric.unit === "B" && typeof it.value === "number"
            ? `${(it.value / 1024).toFixed(1)} kB`
            : String(it.value);
      return `<tr class="item-row ${ok ? "item-pass" : "item-fail"}">
        <td><span class="dot dot-${ok ? "pass" : "fail"}"></span><code>${esc(it.name)}</code></td>
        <td class="mono">${esc(valText)}</td>
        <td class="muted">${esc(it.note ?? "")}</td>
      </tr>`;
    })
    .join("");

  const overflowCount = Math.max(0, failing.length - 40) + Math.max(0, passing.length - 15);
  const promptText = buildFixPrompt({
    category: cat.name,
    metric: metric.name,
    item: failing[0]?.name,
    value: formatMetricValue(metric),
    target: formatTarget(metric),
    gain: Math.max(1, Math.round((100 - (metric.score ?? 0)) / 10)),
  });

  return `<details class="audit-item" data-status="${statusAttr}" data-search="${esc(`${cat.name} ${metric.name} ${metric.title} ${metric.description ?? ""}`.toLowerCase())}" ${statusAttr === "fail" ? "open" : ""}>
    <summary class="audit-summary" aria-expanded="${statusAttr === "fail" ? "true" : "false"}">
      <span class="pill pill-${mBand}">${metric.score ?? 0}</span>
      <span class="audit-title">${esc(metric.title || metric.name)}</span>
      <span class="audit-meta mono">${esc(formatMetricValue(metric))} <span class="muted">target ${esc(formatTarget(metric))}</span></span>
    </summary>
    <div class="audit-body">
      <p class="audit-desc">${esc(metric.description ?? "")}</p>
      <div class="audit-actions">
        <button class="copy-btn" type="button" data-copy="${esc(promptText)}">Copy agent fix prompt</button>
        <span class="mono muted">weight ${esc(metric.weight ?? 1)} · ${esc(metric.kind)}</span>
      </div>
      ${items.length > 0 ? `<div class="table-wrap"><table class="items-table">
        <thead><tr><th>Item</th><th>Observed</th><th>Diagnostic</th></tr></thead>
        <tbody>${rowsHtml}</tbody>
      </table></div>${overflowCount > 0 ? `<p class="muted small">Showing top entries (${overflowCount} more omitted for brevity).</p>` : ""}` : ""}
    </div>
  </details>`;
}

const html = `<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>ZEVM Backpressure Audit Report · ${esc(vcs.shortSha)}</title>
<style>
  :root {
    --bg: #0b0e14;
    --surface: #121722;
    --surface-2: #181f2e;
    --border: #253047;
    --text: #e6edf7;
    --muted: #8b9bb4;
    --pass: #0cce6b;
    --pass-bg: rgba(12, 206, 107, 0.14);
    --avg: #ffa400;
    --avg-bg: rgba(255, 164, 0, 0.15);
    --fail: #ff4e42;
    --fail-bg: rgba(255, 78, 66, 0.15);
    --accent: #3a756b;
    --accent-bright: #52b7a5;
    --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, sans-serif;
  }
  [data-theme="light"] {
    --bg: #f6f8fb;
    --surface: #ffffff;
    --surface-2: #f0f3f8;
    --border: #d8e0ec;
    --text: #111827;
    --muted: #55637a;
    --pass: #008802;
    --pass-bg: rgba(0, 136, 2, 0.1);
    --avg: #c46b00;
    --avg-bg: rgba(196, 107, 0, 0.12);
    --fail: #d92d20;
    --fail-bg: rgba(217, 45, 32, 0.1);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: var(--sans);
    line-height: 1.5;
  }
  .wrap { max-width: 1180px; margin: 0 auto; padding: 24px 20px 64px; }
  .topbar {
    display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between;
    padding: 14px 18px; background: var(--surface); border: 1px solid var(--border); border-radius: 14px;
    margin-bottom: 20px;
  }
  .brand { display: flex; align-items: center; gap: 12px; }
  .brand-mark {
    width: 34px; height: 34px; border-radius: 9px; background: linear-gradient(135deg, #3a756b, #52b7a5);
    display: grid; place-items: center; font-weight: 800; color: #071311; font-family: var(--mono);
  }
  .brand h1 { margin: 0; font-size: 16px; font-weight: 700; letter-spacing: -0.01em; }
  .brand .sub { font-size: 12px; color: var(--muted); font-family: var(--mono); }
  .topbar-right { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
  .trust-badge {
    display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; border-radius: 999px;
    font-size: 12px; font-weight: 600; border: 1px solid var(--border);
  }
  .trust-controlled-sandbox, .trust-maintainer { background: var(--pass-bg); color: var(--pass); border-color: rgba(12,206,107,0.35); }
  .trust-untrusted { background: var(--avg-bg); color: var(--avg); border-color: rgba(255,164,0,0.4); }
  .btn {
    background: var(--surface-2); color: var(--text); border: 1px solid var(--border);
    padding: 6px 12px; border-radius: 8px; font-size: 12px; font-weight: 600; cursor: pointer;
    text-decoration: none;
  }
  .btn:hover { border-color: var(--accent-bright); }
  .trust-banner {
    background: var(--surface); border: 1px solid var(--border); border-left: 4px solid var(--pass);
    border-radius: 12px; padding: 14px 18px; margin-bottom: 22px; display: flex; flex-wrap: wrap;
    justify-content: space-between; gap: 12px; align-items: center;
  }
  .trust-banner.untrusted { border-left-color: var(--avg); }
  .trust-banner p { margin: 2px 0 0; font-size: 13px; color: var(--muted); }
  .mono { font-family: var(--mono); }
  .muted { color: var(--muted); }
  .small { font-size: 12px; }

  .hero-grid {
    display: grid; grid-template-columns: 240px 1fr; gap: 18px; margin-bottom: 24px;
  }
  @media (max-width: 820px) { .hero-grid { grid-template-columns: 1fr; } }
  .card {
    background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 20px;
  }
  .overall-card {
    display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center;
  }
  .overall-grade {
    margin-top: 8px; font-size: 13px; font-weight: 700; padding: 2px 10px; border-radius: 999px;
  }
  .gauges-grid {
    display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 10px; align-items: start;
  }
  @media (max-width: 1080px) {
    .gauges-grid { grid-template-columns: repeat(auto-fit, minmax(126px, 1fr)); }
  }
  .gauge-tile {
    display: flex; flex-direction: column; align-items: center; text-align: center;
    text-decoration: none; color: inherit; padding: 10px 4px; border-radius: 12px;
    border: 1px solid transparent; transition: border-color 0.15s, background 0.15s;
  }
  .gauge-tile:hover { background: var(--surface-2); border-color: var(--border); }
  .gauge-label { margin-top: 8px; font-size: 12px; font-weight: 600; line-height: 1.25; }
  .gauge-sub { font-size: 11px; color: var(--muted); margin-top: 3px; font-family: var(--mono); white-space: nowrap; }
  .gauge-track { fill: none; stroke: var(--surface-2); }
  .gauge-arc { fill: none; stroke-linecap: round; transition: stroke-dashoffset 0.6s ease; }
  .gauge-pass .gauge-arc { stroke: var(--pass); }
  .gauge-average .gauge-arc { stroke: var(--avg); }
  .gauge-fail .gauge-arc { stroke: var(--fail); }
  .gauge-value { font-family: var(--mono); font-weight: 700; font-size: 24px; fill: var(--text); }
  .gauge-pass .gauge-value { fill: var(--pass); }
  .gauge-average .gauge-value { fill: var(--avg); }
  .gauge-fail .gauge-value { fill: var(--fail); }
  .legend {
    display: flex; gap: 18px; justify-content: center; margin-top: 14px; font-size: 12px; color: var(--muted);
    font-family: var(--mono);
  }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; }
  .dot-pass { background: var(--pass); }
  .dot-average { background: var(--avg); }
  .dot-fail { background: var(--fail); }

  .spotlight-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; margin-bottom: 24px;
  }
  .stat-card h3 { margin: 0 0 6px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
  .stat-big { font-size: 24px; font-weight: 700; font-family: var(--mono); }
  .bar { height: 7px; background: var(--surface-2); border-radius: 999px; overflow: hidden; margin-top: 10px; }
  .bar > span { display: block; height: 100%; background: var(--pass); border-radius: 999px; }

  .section-head {
    display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px;
    margin: 26px 0 12px;
  }
  .section-head h2 { margin: 0; font-size: 18px; }
  .controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
  .search-input {
    background: var(--surface); color: var(--text); border: 1px solid var(--border);
    border-radius: 8px; padding: 7px 12px; font-size: 13px; min-width: 240px;
  }
  .filter-btn {
    background: var(--surface); color: var(--muted); border: 1px solid var(--border);
    padding: 6px 12px; border-radius: 999px; font-size: 12px; font-weight: 600; cursor: pointer;
  }
  .filter-btn.active { background: var(--accent); color: #fff; border-color: var(--accent-bright); }

  .opp-list { display: grid; gap: 10px; }
  .opp-row {
    background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 12px 16px;
    display: grid; grid-template-columns: 72px 1fr auto; gap: 12px; align-items: center;
  }
  @media (max-width: 680px) { .opp-row { grid-template-columns: 1fr; } }
  .gain-pill {
    font-family: var(--mono); font-size: 12px; font-weight: 700; text-align: center;
    padding: 4px 8px; border-radius: 8px; background: var(--pass-bg); color: var(--pass);
  }
  .pill {
    display: inline-block; min-width: 38px; text-align: center; padding: 2px 8px; border-radius: 999px;
    font-family: var(--mono); font-size: 12px; font-weight: 700;
  }
  .pill-pass { background: var(--pass-bg); color: var(--pass); }
  .pill-average { background: var(--avg-bg); color: var(--avg); }
  .pill-fail { background: var(--fail-bg); color: var(--fail); }

  .cat-section { margin-top: 22px; }
  .cat-section.hidden { display: none; }
  .empty-state {
    background: var(--surface); border: 1px dashed var(--border); border-radius: 12px;
    padding: 28px 18px; text-align: center; color: var(--muted); font-size: 14px; margin-top: 14px;
  }
  .empty-state.hidden { display: none; }
  .pin-badges { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
  .pin-badge {
    font-family: var(--mono); font-size: 11px; padding: 2px 8px; border-radius: 999px;
    background: var(--pass-bg); color: var(--pass); border: 1px solid rgba(12, 206, 107, 0.28);
  }
  .cat-header {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    margin-bottom: 10px;
  }
  .audit-item {
    background: var(--surface); border: 1px solid var(--border); border-radius: 12px;
    margin-bottom: 10px; overflow: hidden;
  }
  .audit-item.hidden { display: none; }
  .audit-summary {
    display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 12px 16px;
    cursor: pointer; list-style: none;
  }
  .audit-summary::-webkit-details-marker { display: none; }
  .audit-title { font-weight: 600; font-size: 14px; }
  .audit-meta { margin-left: auto; font-size: 12px; }
  .audit-body { padding: 0 16px 14px; border-top: 1px solid var(--border); }
  .audit-desc { font-size: 13px; color: var(--muted); margin: 10px 0; }
  .audit-actions { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 10px; }
  .copy-btn {
    background: var(--surface-2); color: var(--accent-bright); border: 1px solid var(--border);
    padding: 5px 10px; border-radius: 7px; font-size: 12px; font-weight: 600; cursor: pointer;
  }
  .copy-btn:hover { border-color: var(--accent-bright); }
  .table-wrap { overflow-x: auto; }
  .items-table { width: 100%; border-collapse: collapse; font-size: 12px; }
  .items-table th, .items-table td {
    text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--border); vertical-align: top;
  }
  .items-table th { color: var(--muted); font-weight: 600; }
  .item-row code { font-family: var(--mono); margin-left: 6px; }
  .footer-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; margin-top: 28px;
  }
  .chip-list { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .chip {
    font-family: var(--mono); font-size: 11px; padding: 3px 8px; border-radius: 6px;
    background: var(--surface-2); border: 1px solid var(--border);
  }
</style>
</head>
<body>
<div class="wrap">
  <header class="topbar">
    <div class="brand">
      <div class="brand-mark">Z</div>
      <div>
        <h1>ZEVM Backpressure Audit Report</h1>
        <div class="sub">evmts/zevm · ${esc(vcs.ref)} @ ${esc(vcs.shortSha)} · ${esc(generatedAt.slice(0, 19).replace("T", " "))} UTC</div>
      </div>
    </div>
    <div class="topbar-right">
      <span class="trust-badge trust-${esc(trust.level)}">${esc(trust.label)}</span>
      <a class="btn" href="https://smithers.sh/evmts/zevm">Smithers Factory</a>
      <a class="btn" href="https://zevm.sh/docs">Docs</a>
      <button class="btn" id="themeToggle" type="button">Light / Dark</button>
    </div>
  </header>

  <section class="trust-banner ${trust.level === "untrusted" ? "untrusted" : ""}">
    <div>
      <strong>Execution Provenance: ${esc(trust.label)}</strong>
      <p>${esc(trust.summary)}</p>
    </div>
    <div class="mono small">
      <div>Cache: <strong>${esc(trust.cachePolicy)}</strong></div>
      <div>Gate authority: <strong>${trust.gateAuthoritative ? "authoritative" : "advisory only"}</strong></div>
    </div>
  </section>

  <section class="hero-grid">
    <div class="card overall-card">
      ${renderGaugeSvg(overallScore, 128, 9)}
      <div class="overall-grade pill-${overallBand}">Overall ${esc(overallGrade)}</div>
      <div class="muted small" style="margin-top:6px">Mean across ${categories.length} audit categories</div>
    </div>
    <div class="card">
      <div class="gauges-grid">
        ${categories
          .map(
            (c) => `<a class="gauge-tile" href="#cat-${esc(c.name)}">
              ${renderGaugeSvg(c.score, 76, 6)}
              <div class="gauge-label">${esc(c.title)}</div>
              <div class="gauge-sub">${c.passingItems} pass · ${c.failingItems} open</div>
            </a>`,
          )
          .join("")}
      </div>
      <div class="legend">
        <span><i class="dot dot-fail"></i>0–49 Critical</span>
        <span><i class="dot dot-average"></i>50–89 Needs Work</span>
        <span><i class="dot dot-pass"></i>90–100 Healthy</span>
      </div>
    </div>
  </section>

  <section class="spotlight-grid">
    <div class="card stat-card">
      <h3>Cancun GeneralStateTests Floor</h3>
      <div class="stat-big">${((cancunPassed / cancunTotal) * 100).toFixed(1)}%</div>
      <div class="muted small mono">${cancunPassed.toLocaleString()} / ${cancunTotal.toLocaleString()} post states</div>
      <div class="bar"><span style="width:${((cancunPassed / cancunTotal) * 100).toFixed(1)}%"></span></div>
    </div>
    <div class="card stat-card">
      <h3>Prague GeneralStateTests Floor</h3>
      <div class="stat-big">${((praguePassed / pragueTotal) * 100).toFixed(1)}%</div>
      <div class="muted small mono">${praguePassed.toLocaleString()} / ${pragueTotal.toLocaleString()} post states</div>
      <div class="bar"><span style="width:${((praguePassed / pragueTotal) * 100).toFixed(1)}%"></span></div>
    </div>
    <div class="card stat-card">
      <h3>Qualification Map Coverage</h3>
      <div class="stat-big">${qualRecords.length > 0 ? ((qualCovered / qualRecords.length) * 100).toFixed(0) : 0}%</div>
      <div class="muted small mono">${qualCovered} / ${qualRecords.length} contract assertions covered</div>
      <div class="bar"><span style="width:${qualRecords.length > 0 ? ((qualCovered / qualRecords.length) * 100).toFixed(1) : 0}%"></span></div>
    </div>
    <div class="card stat-card">
      <h3>Pinned Native Siblings</h3>
      <div class="stat-big">Zig 0.15.2</div>
      <div class="muted small mono">Canonical deterministic pins in native-dependencies.json</div>
      <div class="pin-badges">
        <span class="pin-badge">voltaire ${esc((nativePins?.voltaire?.revision ?? "n/a").slice(0, 8))}</span>
        <span class="pin-badge">guillotine-mini ${esc((nativePins?.["guillotine-mini"]?.revision ?? "n/a").slice(0, 8))}</span>
      </div>
    </div>
  </section>

  ${opportunities.length > 0 ? `<section>
    <div class="section-head">
      <h2>Top Score Opportunities</h2>
      <span class="muted small">Ranked by largest projected Lighthouse point gain</span>
    </div>
    <div class="opp-list">
      ${opportunities
        .map((opp) => {
          const itemLabel = opp.item ? ` · ${opp.item}` : opp.count ? ` · ${opp.count} items` : "";
          const prompt = buildFixPrompt(opp);
          return `<div class="opp-row">
            <div class="gain-pill">+${esc(opp.gain ?? 0)} pts</div>
            <div>
              <div><strong>${esc(opp.title || opp.metric)}</strong> <span class="muted small mono">${esc(opp.category)}${esc(itemLabel)}</span></div>
              <div class="muted small mono">${esc(opp.value ?? "fail")} → target ${esc(opp.target ?? "pass")}</div>
            </div>
            <button class="copy-btn" type="button" data-copy="${esc(prompt)}">Copy fix prompt</button>
          </div>`;
        })
        .join("")}
    </div>
  </section>` : ""}

  <section>
    <div class="section-head">
      <h2>Detailed Audits</h2>
      <div class="controls">
        <input id="auditSearch" class="search-input" type="search" placeholder="Filter metrics or files..." />
        <button class="filter-btn active" data-filter="all" type="button">All</button>
        <button class="filter-btn" data-filter="fail" type="button">Open / Missed</button>
        <button class="filter-btn" data-filter="pass" type="button">Passing</button>
      </div>
    </div>
    ${categories
      .map(
        (cat) => `<div class="cat-section" id="cat-${esc(cat.name)}">
          <div class="cat-header">
            <div>
              <h3 style="margin:0">${esc(cat.title)}</h3>
              <div class="muted small">${esc(cat.description ?? "")}</div>
            </div>
            <span class="pill pill-${cat.band}">${cat.score} · ${esc(cat.grade)}</span>
          </div>
          ${(cat.metrics ?? []).map((m) => renderMetricBlock(cat, m)).join("")}
        </div>`,
      )
      .join("")}
    <div id="auditEmptyState" class="empty-state hidden">No audits match your current filter or search query.</div>
  </section>

  <section class="footer-grid">
    <div class="card">
      <h3 style="margin-top:0">Smithers Cloud Trust Boundary</h3>
      <p class="small muted">Approvals and merges are locked to authenticated humans. Non-maintainers are encouraged to run local and PR checks, while trunk cache writes stay isolated to main CI.</p>
      <div class="mono small">MCP: https://smithers.sh/evmts/zevm/mcp</div>
      <div class="mono small">Cache: https://build.smithers.sh (split read/write)</div>
      <div class="mono small">Docs index: ${esc(homeJson?.docs ?? "https://zevm.sh/docs/llms.txt")}</div>
    </div>
    <div class="card">
      <h3 style="margin-top:0">Protected Paths</h3>
      <div class="chip-list">
        ${(factoryJson?.github?.protectedPaths ?? []).map((p) => `<span class="chip">${esc(p)}</span>`).join("")}
      </div>
    </div>
  </section>
</div>
<script>
  const root = document.documentElement;
  document.getElementById("themeToggle")?.addEventListener("click", () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
  });
  let currentFilter = "all";
  const searchInput = document.getElementById("auditSearch");
  const items = [...document.querySelectorAll(".audit-item")];
  const sections = [...document.querySelectorAll(".cat-section")];
  const emptyState = document.getElementById("auditEmptyState");
  function applyFilter() {
    const q = (searchInput?.value || "").trim().toLowerCase();
    let visibleCount = 0;
    for (const el of items) {
      const statusOk = currentFilter === "all" || el.dataset.status === currentFilter;
      const textOk = !q || (el.dataset.search || "").includes(q) || el.textContent.toLowerCase().includes(q);
      const visible = statusOk && textOk;
      el.classList.toggle("hidden", !visible);
      if (visible) visibleCount++;
    }
    for (const sec of sections) {
      const anyVisible = sec.querySelector(".audit-item:not(.hidden)") !== null;
      sec.classList.toggle("hidden", !anyVisible);
    }
    emptyState?.classList.toggle("hidden", visibleCount > 0);
  }
  for (const el of items) {
    el.addEventListener("toggle", () => {
      const summary = el.querySelector(".audit-summary");
      if (summary) summary.setAttribute("aria-expanded", el.open ? "true" : "false");
    });
  }
  searchInput?.addEventListener("input", applyFilter);
  for (const btn of document.querySelectorAll(".filter-btn")) {
    btn.addEventListener("click", () => {
      for (const b of document.querySelectorAll(".filter-btn")) b.classList.remove("active");
      btn.classList.add("active");
      currentFilter = btn.dataset.filter || "all";
      applyFilter();
    });
  }
  for (const btn of document.querySelectorAll(".copy-btn")) {
    btn.addEventListener("click", async () => {
      const text = btn.dataset.copy || "";
      try {
        await navigator.clipboard.writeText(text);
        const orig = btn.textContent;
        btn.textContent = "Copied";
        setTimeout(() => { btn.textContent = orig; }, 1400);
      } catch {
        btn.textContent = "Copy failed";
      }
    });
  }
</script>
</body>
</html>
`;

const mdLines = [
  `## ZEVM Backpressure Audit Report (${overallScore}/100 · ${overallGrade})`,
  "",
  `- **Revision:** \`${vcs.shortSha}\` (\`${vcs.ref}\`)`,
  `- **Execution Trust:** \`${trust.label}\` (${trust.cachePolicy}, gate ${trust.gateAuthoritative ? "authoritative" : "advisory only"})`,
  `- **Factory:** https://smithers.sh/evmts/zevm · **MCP:** https://smithers.sh/evmts/zevm/mcp`,
  "",
  "| Category | Score | Grade | Status |",
  "| --- | ---: | :---: | --- |",
  ...categories.map(
    (c) => `| ${c.title} | ${c.score} | ${c.grade} | ${c.passingItems} pass / ${c.failingItems} open |`,
  ),
  "",
];
if (opportunities.length > 0) {
  mdLines.push("### Top Opportunities", "");
  mdLines.push("| Gain | Category | Metric | Current | Target |");
  mdLines.push("| ---: | --- | --- | --- | --- |");
  for (const opp of opportunities.slice(0, 8)) {
    mdLines.push(
      `| +${opp.gain ?? 0} | ${opp.category} | ${opp.title || opp.metric}${opp.item ? ` (\`${opp.item}\`)` : ""} | ${opp.value ?? "fail"} | ${opp.target ?? "pass"} |`,
    );
  }
  mdLines.push("");
}

function writeOut(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
}

writeOut(outHtmlPath, html);
writeOut(feedOutPath, JSON.stringify(feedPayload, null, 2) + "\n");
writeOut(mdOutPath, mdLines.join("\n"));
if (publishDocsPath) {
  writeOut(publishDocsPath, html);
}

console.log(
  `audit-report: overall=${overallScore} (${overallGrade}) trust=${trust.level} categories=${categories.length} -> ${path.relative(repoRoot, outHtmlPath)}`,
);
