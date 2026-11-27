import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

test("audit_report generates Lighthouse HTML, Factory feed JSON, and PR Markdown with trust badge", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zevm-audit-test-"));
  const fixturePath = path.join(tmpDir, "report.json");
  const outHtml = path.join(tmpDir, "audit-report.html");
  const outFeed = path.join(tmpDir, "factory-feed.json");
  const outMd = path.join(tmpDir, "audit-comment.md");

  fs.writeFileSync(
    fixturePath,
    JSON.stringify({
      version: 1,
      categories: [
        {
          name: "safety",
          title: "Safety & TigerStyle",
          description: "Crash freedom",
          score: 92,
          metrics: [
            {
              name: "zig-no-panic",
              title: "Zig no panic",
              description: "No @panic or unreachable",
              kind: "check",
              value: 1,
              score: 100,
              weight: 2,
              items: [{ name: "src/main.zig", value: true, note: null }],
            },
          ],
        },
        {
          name: "factory",
          title: "Smithers Factory & Trust",
          description: "Factory posture",
          score: 80,
          metrics: [
            {
              name: "wiki-integrity",
              title: "Wiki integrity",
              description: "Verify wikilinks",
              kind: "check",
              value: 0,
              score: 0,
              weight: 1.5,
              items: [{ name: ".smithers/wiki", value: false, note: "broken link" }],
            },
          ],
        },
      ],
      opportunities: [
        {
          gain: 8,
          category: "factory",
          metric: "wiki-integrity",
          title: "Wiki integrity",
          item: ".smithers/wiki",
          value: "fail",
          target: "pass",
        },
      ],
      changes: [],
    }),
  );

  const res = spawnSync(
    "node",
    [
      "tools/audit_report.mjs",
      "--input",
      fixturePath,
      "--out",
      outHtml,
      "--feed-out",
      outFeed,
      "--md-out",
      outMd,
      "--trust",
      "untrusted",
    ],
    { encoding: "utf8" },
  );
  assert.equal(res.status, 0, res.stderr || res.stdout);

  const html = fs.readFileSync(outHtml, "utf8");
  assert.match(html, /ZEVM Backpressure Audit Report/);
  assert.match(html, /Untrusted External Run/);
  assert.match(html, /gauge-svg/);
  assert.match(html, /Copy fix prompt/);
  assert.match(html, /Connect Agent \/ MCP/);
  assert.match(html, /id="mcpModal"/);
  assert.match(html, /id="downloadJsonBtn"/);
  assert.match(html, /id="downloadMdBtn"/);
  assert.match(html, /id="auditEmptyState"/);

  const feed = JSON.parse(fs.readFileSync(outFeed, "utf8"));
  assert.equal(feed.set.backpressure.visibility, "public");
  assert.equal(feed.set.backpressure.body.overall.score, 86);
  assert.equal(feed.set.backpressure.body.trust.gateAuthoritative, false);
  assert.equal(feed.set.grades.body.overallScore, 86);

  const md = fs.readFileSync(outMd, "utf8");
  assert.match(md, /86\/100/);
  assert.match(md, /Untrusted External Run/);

  fs.rmSync(tmpDir, { recursive: true, force: true });
});
