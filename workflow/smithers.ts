import { createSmithers } from "smithers-orchestrator";
import { ralphOutputSchemas } from "super-ralph";

export const { Workflow, Task, useCtx, smithers, outputs, db } = createSmithers(ralphOutputSchemas, {
  dbPath: `./zevm-build.db`,
});
