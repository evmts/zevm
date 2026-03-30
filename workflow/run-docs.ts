#!/usr/bin/env bun

import { existsSync, lstatSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT_DIR = resolve(__dirname, "..");
const WORKFLOW_ENTRY = resolve(ROOT_DIR, "docs/workflows/docs.tsx");
const NODE_MODULES = resolve(__dirname, "node_modules");
const SMITHERS_NODE_MODULES = resolve(ROOT_DIR, "docs/references/smithers/node_modules");

const args = new Set(process.argv.slice(2));
const smoke = args.has("--smoke");
const reviewOnly = args.has("--review-only");

let tempDir: string | null = null;
let linkedSmithersNodeModules = false;

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

if (!existsSync(SMITHERS_NODE_MODULES)) {
  symlinkSync(NODE_MODULES, SMITHERS_NODE_MODULES, "dir");
  linkedSmithersNodeModules = true;
} else if (
  lstatSync(SMITHERS_NODE_MODULES).isSymbolicLink() &&
  linkedSmithersNodeModules
) {
  linkedSmithersNodeModules = true;
} else if (
  lstatSync(SMITHERS_NODE_MODULES).isSymbolicLink() &&
  !linkedSmithersNodeModules
) {
  // Respect an existing symlink created outside this runner.
} else {
  // A real node_modules directory under docs/references/smithers is valid.
}

const { mdxPlugin, runWorkflow } = await import("../docs/references/smithers/src/index.ts");

mdxPlugin();

const workflowModule = await import("../docs/workflows/docs.tsx");
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
  const result = await runWorkflow(workflow, {
    input: {},
    runId: smoke ? "zevm-docs-smoke" : undefined,
    rootDir: ROOT_DIR,
    workflowPath: WORKFLOW_ENTRY,
    maxConcurrency: 1,
  });

  console.log(JSON.stringify(result, null, 2));

  if (result.status !== "finished") {
    process.exitCode = 1;
  }
} finally {
  try {
    (workflow.db as any)?.$client?.close?.();
  } catch {}

  if (linkedSmithersNodeModules) {
    rmSync(SMITHERS_NODE_MODULES, { force: true, recursive: true });
  }

  if (tempDir) {
    rmSync(tempDir, { force: true, recursive: true });
  }
}
