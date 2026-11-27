import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("sandbox_auth emits one-time attach handoff with person-only protections", () => {
  const res = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "attach", "--intent", "K7QF-2MXD", "--json"],
    { encoding: "utf8" },
  );
  assert.equal(res.status, 0, res.stderr);
  const data = JSON.parse(res.stdout);
  assert.equal(data.oneTimeUse, true);
  assert.equal(data.intent, "K7QF-2MXD");
  assert.equal(data.mcpUrl, "https://smithers.sh/evmts/zevm/mcp");
  assert.equal(data.attachCommand, "smthrs attach --intent K7QF-2MXD --origin https://smithers.sh");
  assert.ok(data.personOnlyBlocked.includes("pr/merge"));
});

test("sandbox_auth rejects malformed intent codes", () => {
  const res = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "attach", "--intent", "bad-intent"],
    { encoding: "utf8" },
  );
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /invalid intent format/);
});

test("sandbox_auth emits streamable-http MCP config and untrusted cache isolation profile", () => {
  const mcpRes = spawnSync("node", ["tools/sandbox_auth.mjs", "--mode", "mcp-config"], {
    encoding: "utf8",
  });
  assert.equal(mcpRes.status, 0, mcpRes.stderr);
  const mcp = JSON.parse(mcpRes.stdout);
  assert.equal(mcp.mcpServers["smithers-evmts-zevm"].url, "https://smithers.sh/evmts/zevm/mcp");

  const untrustedRes = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "untrusted", "--pr", "42", "--json"],
    { encoding: "utf8" },
  );
  assert.equal(untrustedRes.status, 0, untrustedRes.stderr);
  const u = JSON.parse(untrustedRes.stdout);
  assert.equal(u.trust, "untrusted");
  assert.equal(u.cacheWriteAllowed, false);
  assert.equal(u.gateAuthoritative, false);
  assert.equal(u.env.SMITHERS_CACHE_NAMESPACE, "pr-42");
  assert.equal(u.env.SMITHERS_CACHE_WRITE_TOKEN, "");
});

test("sandbox_auth rejects approve scopes, oversized TTLs, and invalid origin/repo", () => {
  const badScope = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "gateway", "--scope", "approve:runs"],
    { encoding: "utf8" },
  );
  assert.notEqual(badScope.status, 0);
  assert.match(badScope.stderr, /unsupported scope/);

  const badTtl = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "gateway", "--ttl", "999999d"],
    { encoding: "utf8" },
  );
  assert.notEqual(badTtl.status, 0);
  assert.match(badTtl.stderr, /invalid ttl/);

  const badOrigin = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "attach", "--origin", "http://evil.example"],
    { encoding: "utf8" },
  );
  assert.notEqual(badOrigin.status, 0);
  assert.match(badOrigin.stderr, /invalid --origin/);

  const badRepo = spawnSync(
    "node",
    ["tools/sandbox_auth.mjs", "--mode", "attach", "--repo", "../etc/passwd"],
    { encoding: "utf8" },
  );
  assert.notEqual(badRepo.status, 0);
  assert.match(badRepo.stderr, /invalid --repo/);
});
