/**
 * Agent definitions for TOON workflow import.
 * These are imported by workflow.toon via `imports.agents`.
 */

import {
  AmpAgent,
  CodexAgent,
  GeminiAgent,
  KimiAgent,
} from "smithers-orchestrator";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const REPO_ROOT = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");
const agentmd = readFileSync(join(__dirname, "..", "..", "CLAUDE.md"), "utf-8");

const SYSTEM_PROMPT = `${agentmd}
CRITICAL — DO NOT REINVENT THE WHEEL:
1. voltaire (../voltaire/packages/voltaire-zig/src/) — JSON-RPC types, StateManager, ForkBackend, Blockchain, EVM, crypto, precompiles, primitives
2. guillotine-mini (../bench/guillotine-mini/) — EVM interpreter, RPC dispatch/routing, envelope parsing, response serialization
3. If they're MISSING something, add it THERE, not in zevm

ZIG STYLE: No local type aliases. No stored allocators. Fully qualified paths only. Zig 0.15.
`;

export const ampDeep = new AmpAgent({
  mode: "deep",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  label: "zevm-workflow",
  timeoutMs: 60 * 60 * 1000,
});

export const codex = new CodexAgent({
  model: "gpt-5.3-codex",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  config: { model_reasoning_effort: "xhigh" },
  timeoutMs: 60 * 60 * 1000,
});

export const amp = new AmpAgent({
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  label: "zevm-workflow",
  timeoutMs: 60 * 60 * 1000,
});

export const gemini = new GeminiAgent({
  model: "gemini-3.1-pro-preview",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  timeoutMs: 30 * 60 * 1000,
});

export const kimi = new KimiAgent({
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  timeoutMs: 60 * 60 * 1000,
  finalMessageOnly: true,
});
