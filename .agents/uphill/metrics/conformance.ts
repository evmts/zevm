import { appendFileSync, existsSync, readFileSync } from "fs";
import { spawnSync } from "child_process";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

// 1. Native dependency pins (40-hex commit SHAs for voltaire & guillotine-mini)
try {
  const pins = JSON.parse(readFileSync("native-dependencies.json", "utf8")) as Record<
    string,
    { repository?: string; revision?: string }
  >;
  for (const dep of ["voltaire", "guillotine-mini"]) {
    const entry = pins[dep];
    const ok =
      entry &&
      typeof entry.repository === "string" &&
      entry.repository.startsWith("evmts/") &&
      typeof entry.revision === "string" &&
      /^[0-9a-f]{40}$/i.test(entry.revision);
    lines.push(
      ok
        ? `native-pins-valid ${dep} pass`
        : `native-pins-valid ${dep} fail note ${q(`invalid pin for ${dep} in native-dependencies.json`)}`,
    );
  }
} catch (err) {
  lines.push(`native-pins-valid native-dependencies.json fail note ${q(String(err))}`);
}

// 2. Release qualification assertion map coverage
try {
  const qmap = JSON.parse(readFileSync("docs/specs/qualification/assertion-map.json", "utf8")) as {
    records?: Array<{ surfaceId: string; coverageStatus: string }>;
  };
  const records = Array.isArray(qmap.records) ? qmap.records : [];
  let covered = 0;
  for (const rec of records) {
    if (rec.coverageStatus === "covered") covered++;
  }
  const pct = records.length > 0 ? Math.round((covered * 1000) / records.length) / 10 : 0;
  lines.push(`qualification-coverage ${pct} target 100 note ${q(`${covered}/${records.length} assertions covered`)}`);
} catch (err) {
  lines.push(`qualification-coverage 0 target 100 note ${q(String(err))}`);
}

// 3. Latest-fork GeneralStateTests floors (Cancun & Prague) from tools/latest_fork_state_baseline.json
try {
  const baseline = JSON.parse(readFileSync("tools/latest_fork_state_baseline.json", "utf8")) as {
    minimumPassed?: Record<string, Record<string, number>>;
  };
  const sum = (obj: Record<string, number> | undefined) =>
    Object.values(obj ?? {}).reduce((acc, n) => acc + (typeof n === "number" ? n : 0), 0);

  // Known total post-state cases at pinned ethereum/tests c67e485f (docs/reference/latest-fork-state-tests.md)
  const cancunPassed = sum(baseline.minimumPassed?.Cancun);
  const cancunTotal = 19732;
  const cancunPct = Math.round((cancunPassed * 1000) / cancunTotal) / 10;
  lines.push(
    `cancun-state-floor ${cancunPct} target 100 note ${q(`${cancunPassed}/${cancunTotal} Cancun GeneralStateTests floor`)}`,
  );

  const praguePassed = sum(baseline.minimumPassed?.Prague);
  const pragueTotal = 17992;
  const praguePct = Math.round((praguePassed * 1000) / pragueTotal) / 10;
  lines.push(
    `prague-state-floor ${praguePct} target 100 note ${q(`${praguePassed}/${pragueTotal} Prague GeneralStateTests floor`)}`,
  );
} catch (err) {
  lines.push(`cancun-state-floor 0 target 100 note ${q(String(err))}`);
  lines.push(`prague-state-floor 0 target 100 note ${q(String(err))}`);
}

// 4. Release version metadata parity across npm/zevm, 11 platforms, build.zig.zon, src/c_bindings.zig
if (existsSync("npm/zevm/scripts/verify-release.cjs")) {
  const res = spawnSync("node", ["npm/zevm/scripts/verify-release.cjs"], {
    encoding: "utf8",
  });
  lines.push(
    res.status === 0
      ? "release-version-parity npm/zevm pass"
      : `release-version-parity npm/zevm fail note ${q((res.stderr || res.stdout || "verify-release failed").trim().split("\n")[0] || "verify-release failed")}`,
  );
} else {
  lines.push('release-version-parity npm/zevm fail note "missing npm/zevm/scripts/verify-release.cjs"');
}

appendFileSync(out, lines.join("\n") + "\n");
