#!/usr/bin/env node
/**
 * Print or mint safe, one-time-use authentication handoffs for sandboxed
 * agents operating on evmts/zevm via Smithers Cloud MCP.
 *
 * Security invariants:
 * - Never embeds long-lived personal tokens or API keys in prompts or logs.
 * - Uses BYOA one-time attach intents (XXXX-XXXX + PKCE S256 + 6-digit pairing
 *   code -> 8h scoped `smat_` token with `act: "agent"`) or short-lived
 *   gateway tokens (`smthrs token mint --scope ... --ttl ...`).
 * - Untrusted external contributor sandboxes receive read-only cache namespace
 *   config (`SMITHERS_TRUST=untrusted`) and zero write secrets.
 *
 * Usage:
 *   node tools/sandbox_auth.mjs --mode attach [--intent K7QF-2MXD] [--origin https://smithers.sh] [--json]
 *   node tools/sandbox_auth.mjs --mode gateway [--scope read:runs] [--ttl 30m] [--run <id>] [--flow <id>] [--mint]
 *   node tools/sandbox_auth.mjs --mode mcp-config [--repo evmts/zevm] [--origin https://smithers.sh]
 *   node tools/sandbox_auth.mjs --mode untrusted [--pr <number>]
 */

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const idx = args.indexOf(name);
  return idx === -1 ? fallback : (args[idx + 1] ?? fallback);
};
const allFlags = (name) => {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === name && args[i + 1]) out.push(args[i + 1]);
  }
  return out;
};
const hasFlag = (name) => args.includes(name);

const mode = flag("--mode", "attach");
const origin = (flag("--origin", process.env.SMITHERS_ORIGIN || "https://smithers.sh") || "https://smithers.sh").replace(/\/$/, "");
const repo = flag("--repo", "evmts/zevm");
const jsonOut = hasFlag("--json");

const INTENT_RE = /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;
const ALLOWED_SCOPES = new Set(["read:runs", "write:runs", "approve:runs"]);

function makeDemoCodeVerifier() {
  // RFC 7636 PKCE verifier (never reused; freshly generated per handoff if requested)
  return crypto.randomBytes(32).toString("base64url");
}

function findSmthrs() {
  if (process.env.SMTHRS_BIN && fs.existsSync(process.env.SMTHRS_BIN)) return process.env.SMTHRS_BIN;
  const sibling = path.resolve(process.cwd(), "../smithers/node_modules/.bin/smthrs");
  if (fs.existsSync(sibling)) return sibling;
  const probe = spawnSync("which", ["smthrs"], { encoding: "utf8" });
  if (probe.status === 0 && probe.stdout.trim()) return probe.stdout.trim();
  return null;
}

if (mode === "attach") {
  const intent = flag("--intent", "<XXXX-XXXX>");
  if (intent !== "<XXXX-XXXX>" && !INTENT_RE.test(intent)) {
    console.error(`sandbox-auth: invalid intent format ${JSON.stringify(intent)} (expected Crockford base32 XXXX-XXXX)`);
    process.exit(1);
  }
  const command = `smthrs attach --intent ${intent} --origin ${origin}`;
  const mcpUrl = `${origin}/${repo}/mcp`;
  const payload = {
    mode: "attach",
    repository: repo,
    origin,
    mcpUrl,
    oneTimeUse: true,
    intent,
    attachCommand: command,
    tokenLifetime: "8h",
    intentLifetime: "10m",
    actorKind: "agent",
    personOnlyBlocked: ["pr/merge", "repo:secret-write", "todo/commit", "todo/drop", "feed/answer", "pull/review"],
    steps: [
      `1. Maintainer mints a single-use 10-minute intent (XXXX-XXXX) at ${origin}/${repo} (POST /api/attach/intents).`,
      `2. Inside the sandbox, run: ${command}`,
      "3. Sandbox generates a fresh RFC 7636 PKCE S256 challenge and displays a 6-digit pairing code.",
      "4. Maintainer confirms the 6-digit pairing code in the consent dialog (single-use approval code, 2-minute TTL).",
      "5. Sandbox redeems the one-time approval code for an 8-hour scoped agent token (smat_...) and bridges MCP over stdio."
    ]
  };
  if (jsonOut) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    console.log(`Smithers Cloud One-Time Sandbox Attach (${repo})`);
    console.log(`MCP Endpoint : ${mcpUrl}`);
    console.log(`Command      : ${command}`);
    console.log(`TTL          : intent 10m (single-use) -> agent token 8h (act: agent, revocable)`);
    console.log(`Blocked      : person-only actions (merge, approve, commit TODO, secrets)`);
    console.log("");
    for (const s of payload.steps) console.log(s);
  }
} else if (mode === "gateway") {
  const scopes = allFlags("--scope");
  const effectiveScopes = scopes.length > 0 ? scopes : ["read:runs"];
  for (const s of effectiveScopes) {
    if (!ALLOWED_SCOPES.has(s)) {
      console.error(`sandbox-auth: unsupported scope ${JSON.stringify(s)} (allowed: ${[...ALLOWED_SCOPES].join(", ")})`);
      process.exit(1);
    }
  }
  const ttl = flag("--ttl", "30m");
  if (!/^\d+[smhd]$/.test(ttl)) {
    console.error(`sandbox-auth: invalid ttl ${JSON.stringify(ttl)} (expected e.g. 15m, 1h)`);
    process.exit(1);
  }
  const runId = flag("--run", null);
  const flowId = flag("--flow", null);
  const mintNow = hasFlag("--mint");

  const cmdArgs = ["token", "mint", ...effectiveScopes.flatMap((s) => ["--scope", s]), "--ttl", ttl];
  if (runId) cmdArgs.push("--run", runId);
  if (flowId) cmdArgs.push("--flow", flowId);

  if (mintNow) {
    if (!process.env.SMITHERS_TOKEN) {
      console.error("sandbox-auth: SMITHERS_TOKEN must be set in the operator environment to mint a gateway token");
      process.exit(1);
    }
    const smthrs = findSmthrs();
    if (!smthrs) {
      console.error("sandbox-auth: smthrs CLI not found (set SMTHRS_BIN or install @smthrs/cli)");
      process.exit(1);
    }
    const res = spawnSync(smthrs, cmdArgs, { encoding: "utf8", env: process.env });
    if (res.status !== 0) {
      console.error(res.stderr || res.stdout || "sandbox-auth: smthrs token mint failed");
      process.exit(res.status ?? 1);
    }
    process.stdout.write(res.stdout);
  } else {
    const payload = {
      mode: "gateway",
      repository: repo,
      scopes: effectiveScopes,
      ttl,
      run: runId,
      flow: flowId,
      command: `smthrs ${cmdArgs.join(" ")}`,
      note: "Pass --mint with SMITHERS_TOKEN set in a trusted maintainer environment to mint the scoped token."
    };
    console.log(jsonOut ? JSON.stringify(payload, null, 2) : `${payload.command}\n# ${payload.note}`);
  }
} else if (mode === "mcp-config") {
  const mcpUrl = `${origin}/${repo}/mcp`;
  const config = {
    mcpServers: {
      [`smithers-${repo.replace("/", "-")}`]: {
        url: mcpUrl,
        transport: "streamable-http"
      }
    }
  };
  console.log(JSON.stringify(config, null, 2));
} else if (mode === "untrusted") {
  const pr = flag("--pr", "local");
  const namespace = `pr-${String(pr).replace(/[^A-Za-z0-9_-]/g, "")}`;
  const pkceHint = makeDemoCodeVerifier().slice(0, 12);
  const payload = {
    mode: "untrusted",
    repository: repo,
    trust: "untrusted",
    gateAuthoritative: false,
    cacheEndpoint: "https://build.smithers.sh",
    cacheWriteAllowed: false,
    env: {
      SMITHERS_TRUST: "untrusted",
      SMITHERS_CACHE_NAMESPACE: namespace,
      SMITHERS_CACHE_WRITE_TOKEN: ""
    },
    commands: [
      `SMITHERS_TRUST=untrusted SMITHERS_CACHE_NAMESPACE=${namespace} scripts/smthrs ci '//...'`,
      `SMITHERS_TRUST=untrusted node tools/audit_report.mjs --run --trust untrusted`
    ],
    sessionNonce: pkceHint,
    policy: "Non-maintainer runs are encouraged and produce full local and PR audit reports, but can never write to trunk cache or skip controlled-sandbox merge gates."
  };
  if (jsonOut) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    console.log(`ZEVM Untrusted Contributor Sandbox Profile (${repo})`);
    console.log(`Trust        : untrusted (advisory only, trunk cache write blocked)`);
    console.log(`Namespace    : ${namespace}`);
    console.log(`Run CI       : ${payload.commands[0]}`);
    console.log(`Run Audit UI : ${payload.commands[1]}`);
  }
} else {
  console.error(`sandbox-auth: unknown mode ${JSON.stringify(mode)} (use attach | gateway | mcp-config | untrusted)`);
  process.exit(1);
}
