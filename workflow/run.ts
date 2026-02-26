#!/usr/bin/env bun
/**
 * Run the ZEVM Slop Factory build workflow
 * Usage: bun run.ts
 */

import { existsSync } from "fs";
import { resolve, dirname, join } from "path";
import { fileURLToPath } from "url";
import { $ } from "bun";
import { backupDb } from "./db/backup";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT_DIR = resolve(__dirname, "..");

// Force CLI agent for all workflow tasks
process.env.USE_CLI_AGENTS = "1";

// Allow Claude Code subprocesses when launched from within a Claude Code session
delete process.env.CLAUDECODE;

// Show engine errors instead of swallowing them
process.env.SMITHERS_DEBUG = "1";

// DB backup directory
const DB_FILE = join(__dirname, "zevm-build.db");
const BACKUP_DIR = join(__dirname, ".db-backups");

// Backup on exit
const backup = () => backupDb(DB_FILE, BACKUP_DIR);
process.on("exit", backup);
process.on("SIGINT", () => {
  backup();
  process.exit(130);
});
process.on("SIGTERM", () => {
  backup();
  process.exit(143);
});

const maxConcurrency = parseInt(process.env.WORKFLOW_MAX_CONCURRENCY || "16", 10);

// Refresh Kimi OAuth token before starting (and every 10min in background)
const kimiRefresh = Bun.spawn(["bun", join(__dirname, "kimi-refresh.ts"), "--daemon"], {
  stdout: "inherit",
  stderr: "inherit",
});
process.on("exit", () => kimiRefresh.kill());

console.log("Starting ZEVM Slop Factory build workflow");
console.log(`Root directory: ${ROOT_DIR}`);
console.log(`Workflow max concurrency: ${maxConcurrency}`);
console.log("Press Ctrl+C to stop.\n");

// Find Smithers CLI
const smithersCli = existsSync(join(__dirname, "node_modules/smithers-orchestrator/src/cli/index.ts"))
  ? join(__dirname, "node_modules/smithers-orchestrator/src/cli/index.ts")
  : existsSync(join(process.env.HOME || "", "smithers/src/cli/index.ts"))
    ? join(process.env.HOME || "", "smithers/src/cli/index.ts")
    : null;

if (!smithersCli) {
  console.error("error: smithers CLI not found");
  process.exit(1);
}

// Find the latest run ID to resume (preserves outputs across restarts)
const { Database } = await import("bun:sqlite");
const dbFile = join(__dirname, "zevm-build.db");
let resumeRunId: string | null = null;
if (existsSync(dbFile)) {
  try {
    const sdb = new Database(dbFile, { readonly: true });
    const row = sdb.prepare("SELECT run_id FROM _smithers_runs ORDER BY rowid DESC LIMIT 1").get() as { run_id: string } | null;
    if (row) resumeRunId = row.run_id;
    sdb.close();
  } catch {}
}

// Resume existing run (preserves discovered tickets etc.) or start fresh
if (resumeRunId) {
  console.log(`Resuming run: ${resumeRunId}`);
  await $`bun run ${smithersCli} resume components/workflow.tsx --run-id ${resumeRunId} --root ${ROOT_DIR} --max-concurrency ${maxConcurrency} --hot`.cwd(__dirname);
} else {
  await $`bun run ${smithersCli} run components/workflow.tsx --root ${ROOT_DIR} --max-concurrency ${maxConcurrency} --hot`.cwd(__dirname);
}
