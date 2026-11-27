import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

test("wiki_sync validates .smithers/wiki and emits Smithers Cloud plugins/wiki feed payload", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zevm-wiki-test-"));
  const outPath = path.join(tmpDir, "wiki-feed.json");

  const res = spawnSync("node", ["tools/wiki_sync.mjs", "--check", "--out", outPath], {
    encoding: "utf8",
  });
  assert.equal(res.status, 0, res.stderr || res.stdout);
  assert.match(res.stdout, /wiki-sync: ok/);

  const payload = JSON.parse(fs.readFileSync(outPath, "utf8"));
  assert.equal(payload.set.wiki.visibility, "public");
  assert.ok(Array.isArray(payload.set.wiki.body.notes));
  assert.ok(payload.set.wiki.body.notes.length >= 10);
  assert.ok(payload.set.wiki.body.notes.some((n) => n.path === "Overview.md"));
  assert.ok(payload.set.wiki.body.notes.some((n) => n.path === "Mythical-History.md"));
  assert.equal(payload.set.mythical_history.visibility, "public");
  assert.ok(payload.set.mythical_history.body.epics.length >= 8);

  fs.rmSync(tmpDir, { recursive: true, force: true });
});
