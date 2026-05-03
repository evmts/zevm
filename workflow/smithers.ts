import { createSmithers } from "smithers-orchestrator";
import { ralphOutputSchemas } from "super-ralph";

const runtime = (createSmithers as (schemas: Record<string, unknown>, options: Record<string, unknown>) => any)(ralphOutputSchemas, {
  dbPath: `./zevm-build.db`,
});

export const { Workflow, Task, useCtx, smithers, outputs, db } = runtime;
