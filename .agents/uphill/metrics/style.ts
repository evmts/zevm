import { Glob } from "bun";
import { appendFileSync, existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

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

function stripLine(line: string): string {
  return line.replace(/\/\/.*$/, "").replace(/"(?:\\.|[^"\\])*"/g, '""');
}

// 1. Canonical Zig formatting via `zig fmt --check src` (prefer CI-pinned Zig 0.15.2)
const pinnedZig = join(homedir(), ".zvm", "0.15.2", "zig");
const zigBin = process.env.ZIG_BIN || (existsSync(pinnedZig) ? pinnedZig : "zig");
const allSrcZig = [...new Glob("src/**/*.zig").scanSync(".")].sort();
const fmtProc = Bun.spawnSync([zigBin, "fmt", "--check", "src"], {
  stdout: "pipe",
  stderr: "pipe",
});
const unformatted = new Set(
  `${fmtProc.stdout.toString()}\n${fmtProc.stderr.toString()}`
    .split("\n")
    .map((s) => s.trim().replace(/^\.\//, ""))
    .filter((s) => s.endsWith(".zig")),
);
for (const file of allSrcZig) {
  lines.push(
    unformatted.has(file)
      ? `zig-fmt ${file} fail note "run zig fmt ${file}"`
      : `zig-fmt ${file} pass`,
  );
}

// 2. CLAUDE.md style (no private import aliases) + TigerStyle limits (fn<=70, line<=120, no TODO)
const prodZig = allSrcZig.filter(isProdZig);
for (const file of prodZig) {
  const raw = readFileSync(file, "utf8").split("\n");
  let maxFnLen = 0;
  let maxFnName = "";
  let longLineHit: string | null = null;
  let todoHit: string | null = null;
  let aliasHit: string | null = null;

  let fnStart = -1;
  let fnName = "";
  let braceDepth = 0;
  let seenOpen = false;
  let isTypeFn = false;
  let topDepth = 0;

  for (let i = 0; i < raw.length; i++) {
    const line = raw[i]!;
    if (/^test\s*(?:"[^"]*")?\s*\{/.test(line)) break;

    if (!longLineHit && line.length > 120) {
      longLineHit = `line ${i + 1}: ${line.length} chars (limit 120)`;
    }
    if (!todoHit && /\b(TODO|FIXME|XXX|HACK)\b/.test(line)) {
      todoHit = `line ${i + 1}: unresolved work marker`;
    }

    const code = stripLine(line);

    // CLAUDE.md: avoid private top-level imported-symbol aliases like `const Foo = bar.Foo;`
    if (
      !aliasHit &&
      topDepth === 0 &&
      /^const\s+[A-Z][A-Za-z0-9_]*\s*=\s*[a-z_][A-Za-z0-9_]*\.[A-Za-z0-9_.]+\s*;/.test(code)
    ) {
      aliasHit = `line ${i + 1}: private imported-symbol alias (${code.trim()})`;
    }

    if (fnStart === -1) {
      const m = code.match(
        /^\s*(?:pub\s+)?(?:inline\s+|export\s+|extern\s+(?:"[^"]*"\s+)?)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/,
      );
      if (m) {
        fnStart = i;
        fnName = m[1]!;
        braceDepth = 0;
        seenOpen = false;
        isTypeFn = /\)\s*type\s*\{/.test(code);
      }
    } else if (!seenOpen && /\)\s*type\s*\{/.test(code)) {
      isTypeFn = true;
    }

    for (const ch of code) {
      if (ch === "{") {
        topDepth++;
        if (fnStart !== -1) {
          braceDepth++;
          seenOpen = true;
        }
      } else if (ch === "}") {
        topDepth = Math.max(0, topDepth - 1);
        if (fnStart !== -1) braceDepth--;
      }
    }

    if (fnStart !== -1) {
      if (seenOpen && braceDepth <= 0) {
        if (!isTypeFn) {
          const len = i - fnStart + 1;
          if (len > maxFnLen) {
            maxFnLen = len;
            maxFnName = fnName;
          }
        }
        fnStart = -1;
      } else if (!seenOpen && code.includes(";")) {
        fnStart = -1;
      }
    }
  }

  lines.push(
    aliasHit
      ? `no-private-import-aliases ${file} fail note ${q(aliasHit)}`
      : `no-private-import-aliases ${file} pass`,
  );
  if (maxFnLen > 0) {
    lines.push(
      maxFnLen > 70
        ? `function-length ${file} ${maxFnLen} note ${q(`${maxFnName}() is ${maxFnLen} lines (TigerStyle limit 70)`)}`
        : `function-length ${file} ${maxFnLen}`,
    );
  }
  lines.push(
    longLineHit
      ? `line-length ${file} fail note ${q(longLineHit)}`
      : `line-length ${file} pass`,
  );
  lines.push(
    todoHit
      ? `no-todo-markers ${file} fail note ${q(todoHit)}`
      : `no-todo-markers ${file} pass`,
  );
}

appendFileSync(out, lines.join("\n") + "\n");
