import { appendFileSync, existsSync, readFileSync } from "fs";
import { spawnSync } from "child_process";

const out = process.env.UPHILL_METRICS;
if (!out) {
  console.error("UPHILL_METRICS is not set");
  process.exit(1);
}

const lines: string[] = [];
const q = (s: string) => JSON.stringify(s);

// 1. Factory manifest & personalized 3-audience home projection
try {
  const factory = JSON.parse(readFileSync(".smithers/factory.json", "utf8")) as {
    apiVersion?: number;
    contributes?: { triggers?: unknown[] };
    policy?: { approvals?: { approve?: string; merge?: string } };
    github?: { maintainers?: string[]; protectedPaths?: string[]; issues?: string };
    issueViews?: unknown[];
    issueTransitions?: unknown[];
  };
  const hasTriggers =
    factory.apiVersion === 1 && Array.isArray(factory.contributes?.triggers) && factory.contributes.triggers.length > 0;
  lines.push(
    hasTriggers
      ? "factory-triggers .smithers/factory.json pass"
      : 'factory-triggers .smithers/factory.json fail note "factory.json must declare apiVersion: 1 and contributes.triggers"',
  );

  const personOnly =
    factory.policy?.approvals?.approve === "person" && factory.policy?.approvals?.merge === "person";
  lines.push(
    personOnly
      ? "factory-person-only .smithers/factory.json pass"
      : 'factory-person-only .smithers/factory.json fail note "policy.approvals must lock approve and merge to person"',
  );

  const protectedPaths = new Set(factory.github?.protectedPaths ?? []);
  const requiredProtected = [
    "build.zig.zon",
    "native-dependencies.json",
    "include/zevm.h",
    "src/tx_processor.zig",
    "src/consensus_verifier.zig",
    ".smithers",
    ".github/workflows",
  ];
  const missingProtected = requiredProtected.filter((p) => !protectedPaths.has(p));
  lines.push(
    missingProtected.length === 0
      ? "factory-protected-paths .smithers/factory.json pass"
      : `factory-protected-paths .smithers/factory.json fail note ${q(`missing protectedPaths: ${missingProtected.join(", ")}`)}`,
  );
} catch (err) {
  lines.push(`factory-triggers .smithers/factory.json fail note ${q(String(err))}`);
  lines.push(`factory-person-only .smithers/factory.json fail note ${q(String(err))}`);
  lines.push(`factory-protected-paths .smithers/factory.json fail note ${q(String(err))}`);
}

try {
  const home = JSON.parse(readFileSync(".smithers/home.json", "utf8")) as {
    docs?: string;
    sections?: Array<{ audience?: string; blocks?: Array<{ type?: string }> }>;
  };
  const audiences = new Set((home.sections ?? []).map((s) => s.audience ?? "everyone"));
  const hasAllAudiences =
    audiences.has("maintainer") && audiences.has("contributor") && audiences.has("everyone");
  const hasMarkdown = (home.sections ?? []).some((s) =>
    (s.blocks ?? []).some((b) => b.type === "markdown"),
  );
  lines.push(
    hasAllAudiences && !hasMarkdown
      ? "factory-personalized-home .smithers/home.json pass"
      : `factory-personalized-home .smithers/home.json fail note ${q(
          !hasAllAudiences
            ? "home.json must declare maintainer, contributor, and everyone sections"
            : "avoid markdown blocks in home.json so pre-clone preview renders immediately",
        )}`,
  );

  const hasDocsIndex = typeof home.docs === "string" && home.docs.startsWith("https://") && home.docs.endsWith("llms.txt");
  lines.push(
    hasDocsIndex
      ? "factory-docs-index .smithers/home.json pass"
      : 'factory-docs-index .smithers/home.json fail note "home.json must declare https://.../llms.txt in docs"',
  );
} catch (err) {
  lines.push(`factory-personalized-home .smithers/home.json fail note ${q(String(err))}`);
  lines.push(`factory-docs-index .smithers/home.json fail note ${q(String(err))}`);
}

// 2. Shared Smithers Cloud object store & untrusted cache isolation
try {
  const ws = readFileSync(".smithers/WORKSPACE.ts", "utf8");
  const ci = readFileSync(".github/workflows/ci.yml", "utf8");
  const hasSplitTokens =
    ws.includes("https://build.smithers.sh") &&
    ws.includes("SMITHERS_CACHE_READ_TOKEN") &&
    ws.includes("SMITHERS_CACHE_WRITE_TOKEN");
  const guardsWriteOnMain =
    ci.includes("SMITHERS_CACHE_WRITE_TOKEN") &&
    (ci.includes("refs/heads/main") || ci.includes("environment: cache-publish"));
  lines.push(
    hasSplitTokens && guardsWriteOnMain
      ? "cache-trust-isolation .smithers/WORKSPACE.ts pass"
      : 'cache-trust-isolation .smithers/WORKSPACE.ts fail note "require split read/write cache tokens and main-only write guard"',
  );
} catch (err) {
  lines.push(`cache-trust-isolation .smithers/WORKSPACE.ts fail note ${q(String(err))}`);
}

// 3. Obsidian wiki & mythical history integrity
if (existsSync("tools/wiki_sync.mjs")) {
  const res = spawnSync("node", ["tools/wiki_sync.mjs", "--check"], { encoding: "utf8" });
  lines.push(
    res.status === 0
      ? "wiki-integrity .smithers/wiki pass"
      : `wiki-integrity .smithers/wiki fail note ${q((res.stderr || res.stdout || "wiki_sync --check failed").trim().split("\n")[0] || "wiki check failed")}`,
  );
} else {
  lines.push('wiki-integrity .smithers/wiki fail note "missing tools/wiki_sync.mjs"');
}

// 4. llms.txt index check
if (existsSync("tools/generate_llms_txt.mjs")) {
  const res = spawnSync("node", ["tools/generate_llms_txt.mjs", "--check"], { encoding: "utf8" });
  lines.push(
    res.status === 0
      ? "llms-txt-index docs/public/llms.txt pass"
      : `llms-txt-index docs/public/llms.txt fail note ${q((res.stderr || res.stdout || "llms.txt check failed").trim().split("\n")[0] || "llms.txt check failed")}`,
  );
} else {
  lines.push('llms-txt-index docs/public/llms.txt fail note "missing tools/generate_llms_txt.mjs"');
}

// 5. Merge policy & one-time sandbox auth helper
const mergeAndAuthOk = existsSync(".smithers/merge.json") && existsSync("tools/sandbox_auth.mjs");
lines.push(
  mergeAndAuthOk
    ? "sandbox-auth-and-merge .smithers/merge.json pass"
    : 'sandbox-auth-and-merge .smithers/merge.json fail note "require .smithers/merge.json and tools/sandbox_auth.mjs"',
);

appendFileSync(out, lines.join("\n") + "\n");
