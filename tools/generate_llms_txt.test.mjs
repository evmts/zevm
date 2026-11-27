import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import test from "node:test";

test("generate_llms_txt --check passes and conforms to @smthrs/views Docs parser format", () => {
  const res = spawnSync("node", ["tools/generate_llms_txt.mjs", "--check"], { encoding: "utf8" });
  assert.equal(res.status, 0, res.stderr || res.stdout);
  assert.match(res.stdout, /llms-txt: ok/);

  const text = fs.readFileSync("docs/public/llms.txt", "utf8");
  assert.match(text, /^# ZEVM/m);
  assert.match(text, /^> /m);
  const linkRe = /^[-*+]\s+\[([^\]]+)\]\((https:\/\/zevm\.sh\/docs\/raw\/[^)\s]+\.md)\)(?:\s*:\s*(.*))?$/gm;
  const matches = [...text.matchAll(linkRe)];
  assert.ok(matches.length >= 25, `expected >= 25 indexed docs pages, got ${matches.length}`);
});
