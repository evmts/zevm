/**
 * ZEVM Slop Factory — Effect Builder Pattern Version
 *
 * This is the Effect.ts builder equivalent of workflow.tsx.
 * It uses Smithers.workflow().build($) to define the same ticket pipeline
 * with typed step handles, explicit needs, and composable control flow.
 *
 * NOTE: Requires `effect` as a dependency. Install with:
 *   bun add effect @effect/schema
 *
 * Usage:
 *   bun run smithers-orchestrator/src/cli/index.ts run components/workflow-effect.ts \
 *     --root /path/to/zevm --max-concurrency 4 --hot
 */

// @ts-ignore — effect must be installed: bun add effect @effect/schema
import { Effect, Schema } from "effect";
import { Smithers } from "smithers-orchestrator";
import {
  AmpAgent,
  CodexAgent,
  GeminiAgent,
  KimiAgent,
} from "smithers-orchestrator";
// @ts-ignore — super-ralph linked dependency
import { ralphOutputSchemas } from "super-ralph";
import { focuses } from "./focuses";
import { getTarget } from "../targets";
import { WORKFLOW_MAX_CONCURRENCY, WORKFLOW_TASK_RETRIES } from "../config";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const REPO_ROOT = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");
const target = getTarget();

const agentmd = readFileSync(join(__dirname, "..", "..", "CLAUDE.md"), "utf-8");

const SYSTEM_PROMPT = `${agentmd}
We have many resources available such as:

- EIPs/
- consensus/specs/
- ethereum-tests/
- execution-apis/
- execution-specs-tests/
- execcution-specs/
- hive/
- yellowpaper/
- edr/ hardhat ipmlementation in rust
- foundry/ contains an anvil implementation

- ../tevm-monorepo (a typescript anvil like thing)

Use these resources to help guide development.

Plan and research for ZEVM, a Zig Ethereum client that serves as both a light client and a trusted dev node (like Hardhat/Anvil).

CRITICAL — DO NOT REINVENT THE WHEEL:
Before implementing ANYTHING, you MUST check these upstream dependencies (we own all of them):
1. voltaire (../voltaire/packages/voltaire-zig/src/) — JSON-RPC types, StateManager, ForkBackend, Blockchain, EVM, crypto, precompiles, primitives
2. guillotine-mini (../bench/guillotine-mini/) — EVM interpreter, RPC dispatch/routing, envelope parsing, response serialization, Engine API
3. If voltaire or guillotine-mini are MISSING something, add it THERE, not in zevm

ZIG STYLE:
- No local type aliases. No stored allocators. Fully qualified paths only.
- Zig 0.15 with lowercase @typeInfo variants (.int, .bool, .float).
- Minimize abstractions in favor of inlining code except where abstraction is high leverage.
`;

// ---------------------------------------------------------------------------
// Agents
// ---------------------------------------------------------------------------

const ampDeep = new AmpAgent({
  model: "amp-deep",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  timeoutMs: 60 * 60 * 1000,
});

const codex = new CodexAgent({
  model: "gpt-5.3-codex",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  timeoutMs: 60 * 60 * 1000,
});

const amp = new AmpAgent({
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  timeoutMs: 60 * 60 * 1000,
});

const gemini = new GeminiAgent({
  model: "gemini-3.1-pro-preview",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  timeoutMs: 30 * 60 * 1000,
});

const kimi = new KimiAgent({
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  timeoutMs: 60 * 60 * 1000,
});

// ---------------------------------------------------------------------------
// Output Schemas (from ralphOutputSchemas)
// ---------------------------------------------------------------------------

const out = ralphOutputSchemas;

// ---------------------------------------------------------------------------
// Workflow Definition
// ---------------------------------------------------------------------------

class WorkflowInput extends Schema.Class<WorkflowInput>("WorkflowInput")({
  maxConcurrency: Schema.optionalWith(Schema.Number, { default: () => WORKFLOW_MAX_CONCURRENCY }),
  taskRetries: Schema.optionalWith(Schema.Number, { default: () => WORKFLOW_TASK_RETRIES }),
}) {}

const ZevmWorkflow = Smithers.workflow({
  name: "zevm-slop-factory",
  input: WorkflowInput,
}).build(($) => {
  // -----------------------------------------------------------------------
  // Step 1: Ticket Scheduler — decide what to work on
  // -----------------------------------------------------------------------
  const ticketScheduler = $.step("ticket-scheduler", {
    output: out.ticket_schedule,
    run: () =>
      Effect.promise(() =>
        amp.generate({
          prompt: buildSchedulerPrompt(),
          outputSchema: out.ticket_schedule,
        }),
      ),
    timeout: "10m",
    retry: 2,
  });

  // -----------------------------------------------------------------------
  // Step 2: Discovery & Progress (parallel)
  // -----------------------------------------------------------------------

  const discover = $.step("discover", {
    output: out.discover,
    run: () =>
      Effect.promise(() =>
        ampDeep.generate({
          prompt: buildDiscoverPrompt(),
          outputSchema: out.discover,
        }),
      ),
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const progressUpdate = $.step("progress-update", {
    output: out.progress,
    run: () =>
      Effect.promise(() =>
        kimi.generate({
          prompt: `Update PROGRESS.md for ${target.name}. Summarize completed tickets and remaining work.`,
          outputSchema: out.progress,
        }),
      ),
    timeout: "15m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  // -----------------------------------------------------------------------
  // Ticket pipeline stages
  // -----------------------------------------------------------------------

  const research = $.step("research", {
    output: out.research,
    run: () =>
      Effect.promise(() =>
        ampDeep.generate({
          prompt: `Research the next ticket. Check voltaire and guillotine-mini first.`,
          outputSchema: out.research,
        }),
      ),
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const plan = $.step("plan", {
    output: out.plan,
    needs: { researchResult: research },
    run: ({ researchResult }: any) =>
      Effect.promise(() =>
        gemini.generate({
          prompt: `Create implementation plan based on research: ${researchResult.summary}`,
          outputSchema: out.plan,
        }),
      ),
    timeout: "20m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const implement = $.step("implement", {
    output: out.implement,
    needs: { planResult: plan },
    run: ({ planResult }: any) =>
      Effect.promise(() =>
        codex.generate({
          prompt: `Implement the plan at ${planResult.planFilePath}. Follow steps: ${(planResult.implementationSteps ?? []).join(", ")}`,
          outputSchema: out.implement,
        }),
      ),
    timeout: "60m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const test = $.step("test", {
    output: out.test_results,
    needs: { implResult: implement },
    run: ({ implResult }: any) =>
      Effect.promise(() =>
        amp.generate({
          prompt: `Run tests after implementation: ${implResult.whatWasDone}. Commands: ${Object.values(target.testCmds).join(", ")}`,
          outputSchema: out.test_results,
        }),
      ),
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const specReview = $.step("spec-review", {
    output: out.spec_review,
    needs: { implResult: implement, testResult: test },
    run: ({ implResult, testResult }: any) =>
      Effect.promise(() =>
        gemini.generate({
          prompt: `Review implementation against specs. Files: ${[...(implResult.filesCreated ?? []), ...(implResult.filesModified ?? [])].join(", ")}. Tests: ${testResult.goTestsPassed ? "PASS" : "FAIL"}`,
          outputSchema: out.spec_review,
        }),
      ),
    timeout: "20m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const codeReview = $.step("code-review", {
    output: out.code_review,
    needs: { implResult: implement },
    run: ({ implResult }: any) =>
      Effect.promise(() =>
        ampDeep.generate({
          prompt: `Code review files: ${[...(implResult.filesCreated ?? []), ...(implResult.filesModified ?? [])].join(", ")}. Checklist: ${target.reviewChecklist.join("; ")}`,
          outputSchema: out.code_review,
        }),
      ),
    timeout: "20m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  // -----------------------------------------------------------------------
  // Review-fix loop
  // -----------------------------------------------------------------------

  const reviewFix = $.step("review-fix", {
    output: out.review_fix,
    needs: { specResult: specReview, codeResult: codeReview },
    run: ({ specResult, codeResult }: any) => {
      const allClear = specResult.severity === "none" && codeResult.severity === "none";
      if (allClear) {
        return Effect.succeed({ allIssuesResolved: true, summary: "All reviews passed." });
      }
      return Effect.promise(() =>
        codex.generate({
          prompt: `Fix review issues. Spec: ${specResult.feedback}. Code: ${codeResult.feedback}`,
          outputSchema: out.review_fix,
        }),
      );
    },
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const report = $.step("report", {
    output: out.report,
    needs: { fixResult: reviewFix },
    run: ({ fixResult }: any) =>
      Effect.promise(() =>
        amp.generate({
          prompt: `Generate ticket report. Issues resolved: ${fixResult.allIssuesResolved}. ${fixResult.summary}`,
          outputSchema: out.report,
        }),
      ),
    timeout: "15m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  // -----------------------------------------------------------------------
  // Merge queue
  // -----------------------------------------------------------------------

  const mergeQueue = $.step("merge-queue", {
    output: out.land,
    needs: { reportResult: report },
    run: ({ reportResult }: any) => {
      if (reportResult.status !== "complete") {
        return Effect.succeed({
          merged: false, mergeCommit: null, ciPassed: false,
          summary: `Ticket ${reportResult.ticketId} not complete: ${reportResult.status}`,
          evicted: false, evictionReason: null, evictionDetails: null,
          attemptedLog: null, attemptedDiffSummary: null, landedOnMainSinceBranch: null,
        });
      }
      return Effect.promise(() =>
        amp.generate({
          prompt: `Land ticket ${reportResult.ticketId} to main. Run CI: ${Object.values(target.testCmds).join(", ")}`,
          outputSchema: out.land,
        }),
      );
    },
    timeout: "15m",
    retry: 2,
  });

  // -----------------------------------------------------------------------
  // Compose: outer loop wrapping the full pipeline
  // -----------------------------------------------------------------------

  const ticketPipeline = $.sequence(
    research,
    plan,
    implement,
    test,
    $.parallel(specReview, codeReview),
    reviewFix,
    report,
    mergeQueue,
  );

  return $.loop({
    id: "main-loop",
    children: $.sequence(
      ticketScheduler,
      $.parallel(discover, progressUpdate, ticketPipeline, {
        maxConcurrency: WORKFLOW_MAX_CONCURRENCY,
      }),
    ),
    until: () => false,
    maxIterations: Infinity,
    onMaxReached: "return-last",
  });
});

// ---------------------------------------------------------------------------
// Prompt builders
// ---------------------------------------------------------------------------

function buildSchedulerPrompt(): string {
  const focusTable = focuses
    .map((f) => `- ${f.id}: ${f.name}`)
    .join("\n");
  return `You are the ticket scheduler for ${target.name}.

Available focuses:
${focusTable}

Available agents:
- amp-deep: Best orchestrator and deepest thinker. Expensive — reserve for high-stakes work.
- codex: Main workhorse for bulk implementation. Good at Zig code.
- amp: Fast Amp agent for testing, review-fix cycles, and lighter research.
- gemini: Large context window. Best for planning and architecture analysis. Unreliable at tool calls.
- kimi: Cheapest agent. Use for simple work: RPC handler wiring, boilerplate.

Schedule the next batch of jobs. Consider pipeline stages, dependencies, and agent strengths.
Max concurrency: ${WORKFLOW_MAX_CONCURRENCY}. Task retries: ${WORKFLOW_TASK_RETRIES}.`;
}

function buildDiscoverPrompt(): string {
  return `Discover implementation tickets for ${target.name}.

Focuses:
${focuses.map((f) => `- ${f.id}: ${f.name}`).join("\n")}

Check ${target.specsPath} for specs. Check voltaire and guillotine-mini before creating tickets.
Reference files: ${target.referenceFiles.join(", ")}`;
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export default ZevmWorkflow;
