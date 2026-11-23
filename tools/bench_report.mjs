#!/usr/bin/env node
// Aggregates zevm benchmark suite JSON outputs, compares against bench/baseline.json,
// prints a clear summary table, and optionally updates the baseline or enforces regression limits.

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
let baselinePath = "bench/baseline.json";
let outJsonPath = null;
let outMdPath = null;
let updateBaseline = false;
let failRegressionPct = null;
let suiteFilter = null;
const inputFiles = [];

for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === "--baseline") {
    baselinePath = args[++i];
  } else if (arg === "--out-json") {
    outJsonPath = args[++i];
  } else if (arg === "--out-md") {
    outMdPath = args[++i];
  } else if (arg === "--update-baseline") {
    updateBaseline = true;
  } else if (arg === "--fail-regression-pct") {
    failRegressionPct = Number(args[++i]);
  } else if (arg === "--suite") {
    suiteFilter = args[++i];
  } else if (arg === "--input") {
    inputFiles.push(args[++i]);
  } else {
    inputFiles.push(arg);
  }
}

function discoverResultFiles() {
  if (inputFiles.length > 0) return inputFiles;
  const benchDir = "bench";
  const entries = fs.readdirSync(benchDir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (suiteFilter && entry.name !== suiteFilter) continue;
    const candidate = path.join(benchDir, entry.name, ".results", "latest.json");
    if (fs.existsSync(candidate)) files.push(candidate);
  }
  return files.sort();
}

function formatDuration(ns) {
  if (ns >= 1e9) return `${(ns / 1e9).toFixed(3)} s`;
  if (ns >= 1e6) return `${(ns / 1e6).toFixed(3)} ms`;
  if (ns >= 1e3) return `${(ns / 1e3).toFixed(2)} us`;
  return `${ns.toFixed(1)} ns`;
}

function formatOps(ops) {
  if (ops >= 1e6) return `${(ops / 1e6).toFixed(2)}M/s`;
  if (ops >= 1e3) return `${(ops / 1e3).toFixed(2)}K/s`;
  return `${ops.toFixed(1)}/s`;
}

function formatDelta(currentNs, baseNs) {
  if (baseNs == null || baseNs <= 0) return "new";
  const pct = ((currentNs - baseNs) / baseNs) * 100;
  const ratio = baseNs / currentNs;
  if (Math.abs(pct) < 1.5) return "~0.0%";
  if (pct < 0) {
    return ratio >= 1.5
      ? `${pct.toFixed(1)}% (${ratio.toFixed(2)}x faster)`
      : `${pct.toFixed(1)}% faster`;
  }
  const slowRatio = currentNs / baseNs;
  return slowRatio >= 1.5
    ? `+${pct.toFixed(1)}% (${slowRatio.toFixed(2)}x slower)`
    : `+${pct.toFixed(1)}% slower`;
}

const files = discoverResultFiles();
if (files.length === 0) {
  console.error("error: no benchmark result files found under bench/*/.results/latest.json");
  process.exit(1);
}

let baselineMap = new Map();
if (fs.existsSync(baselinePath)) {
  try {
    const raw = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
    for (const suite of raw.suites ?? []) {
      for (const b of suite.benchmarks ?? []) {
        baselineMap.set(`${suite.suite}:${b.name}`, b);
      }
    }
  } catch (err) {
    console.error(`warning: failed to parse baseline ${baselinePath}: ${err.message}`);
  }
}

const suites = [];
const rows = [];
const regressions = [];

for (const file of files) {
  const data = JSON.parse(fs.readFileSync(file, "utf8"));
  if (data.schemaVersion !== "zevm-bench.v1") {
    console.error(`error: unexpected schemaVersion in ${file}: ${data.schemaVersion}`);
    process.exit(1);
  }
  if (!Array.isArray(data.benchmarks) || data.benchmarks.length === 0) {
    console.error(`error: empty benchmarks array in ${file}`);
    process.exit(1);
  }
  suites.push(data);
  for (const b of data.benchmarks) {
    const key = `${data.suite}:${b.name}`;
    const prev = baselineMap.get(key);
    const deltaPct = prev && prev.p50_ns > 0 ? ((b.p50_ns - prev.p50_ns) / prev.p50_ns) * 100 : null;
    const deltaStr = formatDelta(b.p50_ns, prev?.p50_ns ?? null);
    if (failRegressionPct !== null && deltaPct !== null && deltaPct > failRegressionPct) {
      regressions.push({ suite: data.suite, name: b.name, prevNs: prev.p50_ns, curNs: b.p50_ns, deltaPct });
    }
    rows.push({
      suite: data.suite,
      name: b.name,
      p50_ns: b.p50_ns,
      p95_ns: b.p95_ns,
      ops_per_sec: b.ops_per_sec,
      baseline_p50_ns: prev?.p50_ns ?? null,
      delta_pct: deltaPct,
      delta: deltaStr,
    });
  }
}

const report = {
  schemaVersion: "zevm-bench-report.v1",
  suiteCount: suites.length,
  benchmarkCount: rows.length,
  zigVersion: suites[0]?.zigVersion ?? "unknown",
  optimize: suites[0]?.optimize ?? "unknown",
  arch: suites[0]?.arch ?? "unknown",
  os: suites[0]?.os ?? "unknown",
  suites,
};

// Print crisp terminal table
console.log("");
console.log(
  `ZEVM Benchmarks (${report.suiteCount} suite${report.suiteCount === 1 ? "" : "s"}, ${report.benchmarkCount} benchmarks, ${report.optimize}, zig ${report.zigVersion}, ${report.arch}-${report.os})`
);
console.log("=".repeat(118));
console.log(
  `${"Suite".padEnd(18)} ${"Benchmark".padEnd(40)} ${"p50".padStart(12)} ${"p95".padStart(12)} ${"ops/s".padStart(11)} ${"vs baseline".padStart(20)}`
);
console.log("-".repeat(118));
for (const r of rows) {
  console.log(
    `${r.suite.padEnd(18)} ${r.name.padEnd(40)} ${formatDuration(r.p50_ns).padStart(12)} ${formatDuration(r.p95_ns).padStart(12)} ${formatOps(r.ops_per_sec).padStart(11)} ${r.delta.padStart(20)}`
  );
}
console.log("=".repeat(118));

if (outJsonPath) {
  fs.mkdirSync(path.dirname(outJsonPath), { recursive: true });
  fs.writeFileSync(outJsonPath, `${JSON.stringify(report, null, 2)}\n`);
}

if (outMdPath) {
  fs.mkdirSync(path.dirname(outMdPath), { recursive: true });
  const md = [
    `# ZEVM Performance Benchmarks`,
    ``,
    `- **Suites:** ${report.suiteCount} | **Benchmarks:** ${report.benchmarkCount} | **Optimize:** \`${report.optimize}\` | **Zig:** \`${report.zigVersion}\` | **Host:** \`${report.arch}-${report.os}\``,
    ``,
    `| Suite | Benchmark | p50 | p95 | ops/s | vs baseline |`,
    `| --- | --- | ---: | ---: | ---: | ---: |`,
    ...rows.map(
      (r) =>
        `| \`${r.suite}\` | \`${r.name}\` | ${formatDuration(r.p50_ns)} | ${formatDuration(r.p95_ns)} | ${formatOps(r.ops_per_sec)} | ${r.delta} |`
    ),
    ``,
  ].join("\n");
  fs.writeFileSync(outMdPath, md);
}

if (updateBaseline) {
  fs.mkdirSync(path.dirname(baselinePath), { recursive: true });
  fs.writeFileSync(baselinePath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`Updated baseline: ${baselinePath}`);
}

if (regressions.length > 0) {
  console.error(`\nDetected ${regressions.length} regression(s) exceeding +${failRegressionPct}%:`);
  for (const reg of regressions) {
    console.error(
      `  - ${reg.suite}/${reg.name}: ${formatDuration(reg.prevNs)} -> ${formatDuration(reg.curNs)} (+${reg.deltaPct.toFixed(1)}%)`
    );
  }
  process.exit(1);
}
