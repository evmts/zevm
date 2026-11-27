import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

test("home_projection --check validates 3-audience home.json synced with HOME.mjs", () => {
  const out = execFileSync(process.execPath, [path.join(repoRoot, "tools/home_projection.mjs"), "--check"], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  assert.match(out, /home-projection: ok \(3 audiences/);

  const home = JSON.parse(fs.readFileSync(path.join(repoRoot, ".smithers/home.json"), "utf8"));
  assert.equal(home.contributors, "role");
  assert.equal(home.docs, "https://zevm.sh/docs/llms.txt");
  const audiences = home.sections.map((s) => s.audience);
  assert.deepEqual(audiences, ["maintainer", "contributor", "everyone"]);
  for (const s of home.sections) {
    assert.ok(!s.blocks.some((b) => b.type === "markdown"));
  }
});
