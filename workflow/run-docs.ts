#!/usr/bin/env bun

import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { delimiter, join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mdxPlugin, runWorkflow } from "smithers-orchestrator";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT_DIR = resolve(__dirname, "..");
const WORKFLOW_ENTRY = resolve(ROOT_DIR, "docs/workflows/docs.tsx");
const NODE_MODULES = resolve(__dirname, "node_modules");
const smithersRequire = createRequire(import.meta.resolve("smithers-orchestrator"));
const { Effect } = smithersRequire("effect");

const args = new Set(process.argv.slice(2));
const smoke = args.has("--smoke");
const reviewOnly = args.has("--review-only");

let tempDir: string | null = null;
let exitCode = 0;

process.env.NODE_PATH = [NODE_MODULES, process.env.NODE_PATH]
  .filter(Boolean)
  .join(delimiter);

if (smoke) {
  tempDir = mkdtempSync(join(tmpdir(), "zevm-docs-workflow-"));
  process.env.SMITHERS_DOCS_SMOKE = "1";
  process.env.ZEVM_DOCS_WORKFLOW_DB = join(tempDir, "docs-workflow.db");
  process.env.ZEVM_DOCS_MAX_ITERATIONS = process.env.ZEVM_DOCS_MAX_ITERATIONS ?? "3";
}

if (reviewOnly) {
  process.env.ZEVM_DOCS_SKIP_IMPLEMENTATION = "1";
}

mdxPlugin();

const workflowModule = await import(pathToFileURL(WORKFLOW_ENTRY).href);
const workflow = workflowModule.default;

try {
  const mode = [
    "Running docs workflow",
    reviewOnly ? "in review-only mode" : "",
    smoke ? "in smoke mode" : "",
  ]
    .filter(Boolean)
    .join(" ");
  console.log(mode);
  const result = await Effect.runPromise(runWorkflow(workflow, {
    input: {},
    runId: smoke ? "zevm-docs-smoke" : undefined,
    rootDir: ROOT_DIR,
    workflowPath: WORKFLOW_ENTRY,
    maxConcurrency: 1,
  }));

  console.log(JSON.stringify(result, null, 2));

  if (result.status !== "finished") {
    exitCode = 1;
  }
} finally {
  try {
    (workflow.db as any)?.$client?.close?.();
  } catch {}

  if (tempDir) {
    rmSync(tempDir, { force: true, recursive: true });
  }
}

process.exit(exitCode);
