import { existsSync } from "node:fs";
import { join } from "node:path";

const root = import.meta.dir;
const localCli = join(root, "node_modules/smithers-orchestrator/src/cli/index.ts");

if (!existsSync(localCli)) {
  console.error("smithers-orchestrator CLI is not installed in this checkout.");
  console.error("Install local dependencies first (../../smithers and workflow/super-ralph).");
  console.error("Expected command after local deps are present:");
  console.error("  bun run workflow:list");
  process.exit(1);
}

const proc = Bun.spawn(["bun", "run", localCli, "workflow", "list", "components/workflow.tsx", "--root", root], {
  stdout: "inherit",
  stderr: "inherit",
  stdin: "inherit",
});

const code = await proc.exited;
process.exit(code);
