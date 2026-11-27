import { Glob } from "bun";
import { appendFileSync, existsSync, readFileSync } from "fs";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

function isProdZig(path: string): boolean {
  return (
    !path.endsWith("_test.zig") &&
    !path.endsWith("_tests.zig") &&
    !path.startsWith("src/fuzz/")
  );
}

// 1. Lean 4 proofs in spec/lean/
const leanFiles = [...new Glob("spec/lean/**/*.lean").scanSync(".")].sort();
let totalTheorems = 0;

for (const file of leanFiles) {
  const fileLines = readFileSync(file, "utf8").split("\n");
  let sorryHit: string | null = null;
  for (let i = 0; i < fileLines.length; i++) {
    const code = fileLines[i]!.replace(/--.*$/, "");
    if (/^\s*(?:theorem|lemma)\s+/.test(code)) totalTheorems++;
    if (!sorryHit && /\bsorry\b/.test(code)) {
      sorryHit = `line ${i + 1}: unproved sorry in Lean proof`;
    } else if (!sorryHit && /^\s*axiom\s+/.test(code)) {
      sorryHit = `line ${i + 1}: unproved axiom in Lean proof`;
    }
  }
  lines.push(
    sorryHit
      ? `lean-no-sorry ${file} fail note ${q(sorryHit)}`
      : `lean-no-sorry ${file} pass`,
  );
}
lines.push(`lean-theorems ${totalTheorems}`);

// 2. Native `std.testing.fuzz` targets across src/fuzz/ and *_fuzz_test.zig
const allSrcZig = [...new Glob("src/**/*.zig").scanSync(".")].sort();
let fuzzTargets = 0;
for (const file of allSrcZig) {
  if (!file.startsWith("src/fuzz/") && !file.endsWith("_fuzz_test.zig")) continue;
  const txt = readFileSync(file, "utf8");
  fuzzTargets += (txt.match(/std\.testing\.fuzz\s*\(/g) || []).length;
}
lines.push(`fuzz-targets ${fuzzTargets}`);

// 3. Module test coverage (inline `test` blocks or sibling `*_test.zig`)
const prodZig = allSrcZig.filter(isProdZig);
let tested = 0;
for (const file of prodZig) {
  const txt = readFileSync(file, "utf8");
  const hasInline = /^\s*test\s*(?:"[^"]*")?\s*\{/m.test(txt);
  const hasSibling = existsSync(file.replace(/\.zig$/, "_test.zig"));
  if (hasInline || hasSibling) tested++;
}
const pct = prodZig.length > 0 ? Math.round((tested * 1000) / prodZig.length) / 10 : 0;
lines.push(`module-test-coverage ${pct}`);

appendFileSync(out, lines.join("\n") + "\n");
