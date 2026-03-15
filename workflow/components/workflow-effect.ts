/**
 * ZEVM Slop Factory — Effect Builder Pattern Version
 *
 * This is the Effect.ts builder equivalent of workflow.tsx.
 * It uses Smithers.workflow().build($) to define the same SuperRalph-driven
 * ticket pipeline with typed step handles, explicit needs, and Effect services.
 *
 * Usage:
 *   bun run smithers-orchestrator/src/cli/index.ts run components/workflow-effect.ts \
 *     --root /path/to/zevm --max-concurrency 4 --hot
 */

import { Context, Effect, Layer, Schema } from "effect";
import { Smithers } from "smithers-orchestrator";
import {
  AmpAgent,
  CodexAgent,
  GeminiAgent,
  KimiAgent,
} from "smithers-orchestrator";
import { ralphOutputSchemas } from "super-ralph";
import { focuses } from "./focuses";
import { focusTestSuites } from "./focusTestSuites";
import { focusDirs } from "./focusDirs";
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
  mode: "deep",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  label: "zevm-workflow",
  timeoutMs: 60 * 60 * 1000,
});

const codex = new CodexAgent({
  model: "gpt-5.3-codex",
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  yolo: true,
  config: { model_reasoning_effort: "xhigh" },
  timeoutMs: 60 * 60 * 1000,
});

const amp = new AmpAgent({
  systemPrompt: SYSTEM_PROMPT,
  cwd: REPO_ROOT,
  label: "zevm-workflow",
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
  finalMessageOnly: true,
});

const agentPool = {
  "amp-deep": {
    agent: ampDeep,
    description: "Best orchestrator and deepest thinker. Expensive — reserve for high-stakes work.",
  },
  codex: {
    agent: codex,
    description: "Main workhorse for bulk implementation. Good at Zig code.",
  },
  amp: {
    agent: amp,
    description: "Fast Amp agent for testing, review-fix cycles, and lighter research.",
    isScheduler: true,
    isMergeQueue: true,
  },
  gemini: {
    agent: gemini,
    description: "Large context window. Best for planning and architecture analysis. Unreliable at tool calls.",
  },
  kimi: {
    agent: kimi,
    description: "Cheapest agent. Use for simple work: RPC handler wiring, boilerplate.",
  },
};

// ---------------------------------------------------------------------------
// Output Schemas (from ralphOutputSchemas — re-exported as Effect Schema.Class)
// ---------------------------------------------------------------------------

// The ralphOutputSchemas are Zod schemas. The Effect builder accepts them
// directly via Smithers' Zod→Effect bridge, so we pass them through as-is.
const out = ralphOutputSchemas;

// ---------------------------------------------------------------------------
// Service Tags — thin wrappers for agent invocation
// ---------------------------------------------------------------------------

class AgentPoolService extends Context.Tag("AgentPoolService")<
  AgentPoolService,
  typeof agentPool
>() {}

const AgentPoolLive = Layer.succeed(AgentPoolService, agentPool);

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
    run: ({ input }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const schedulerAgentId = Object.entries(pool).find(([, e]) => e.isScheduler)?.[0] ?? Object.keys(pool)[0];
        const schedulerAgent = pool[schedulerAgentId as keyof typeof pool].agent;

        // The scheduler prompt would be built from focuses, pipeline state, etc.
        // In practice this delegates to the SuperRalph TicketScheduler component logic.
        return yield* Effect.promise(() =>
          schedulerAgent.generate({
            prompt: buildSchedulerPrompt(focuses, target),
            outputSchema: out.ticket_schedule,
          }),
        );
      }),
    timeout: "10m",
    retry: 2,
  });

  // -----------------------------------------------------------------------
  // Step 2: Execute scheduled jobs in parallel
  // -----------------------------------------------------------------------
  // Each job type maps to a pipeline stage. In the full implementation,
  // these would dynamically dispatch based on the scheduler output.
  // Here we show the static structure:

  const discover = $.step("discover", {
    output: out.discover,
    needs: { schedule: ticketScheduler },
    run: ({ schedule }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const discoveryJob = schedule.jobs.find((j) => j.jobType === "discovery");
        if (!discoveryJob) return yield* Effect.fail(new Error("No discovery job scheduled"));
        const agent = pool[discoveryJob.agentId as keyof typeof pool]?.agent ?? Object.values(pool)[0].agent;
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: buildDiscoverPrompt(target, focuses),
            outputSchema: out.discover,
          }),
        );
      }),
    skipIf: (ctx) => {
      const schedule = ctx.needs?.schedule;
      return !schedule?.jobs?.some((j: any) => j.jobType === "discovery");
    },
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const progressUpdate = $.step("progress-update", {
    output: out.progress,
    needs: { schedule: ticketScheduler },
    run: ({ schedule }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const job = schedule.jobs.find((j) => j.jobType === "progress-update");
        if (!job) return yield* Effect.fail(new Error("No progress-update job scheduled"));
        const agent = pool[job.agentId as keyof typeof pool]?.agent ?? Object.values(pool)[0].agent;
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Update PROGRESS.md for ${target.name}. Summarize completed tickets and remaining work.`,
            outputSchema: out.progress,
          }),
        );
      }),
    skipIf: (ctx) => {
      const schedule = ctx.needs?.schedule;
      return !schedule?.jobs?.some((j: any) => j.jobType === "progress-update");
    },
    timeout: "15m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  // -----------------------------------------------------------------------
  // Ticket pipeline stages — research → plan → implement → test → review → report
  // -----------------------------------------------------------------------

  const research = $.step("research", {
    output: out.research,
    needs: { schedule: ticketScheduler },
    run: ({ schedule }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const job = schedule.jobs.find((j) => j.jobType === "ticket:research");
        if (!job) return yield* Effect.fail(new Error("No research job"));
        const agent = pool[job.agentId as keyof typeof pool]?.agent ?? Object.values(pool)[0].agent;
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Research ticket ${job.ticketId}. Check voltaire and guillotine-mini first.`,
            outputSchema: out.research,
          }),
        );
      }),
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const plan = $.step("plan", {
    output: out.plan,
    needs: { researchResult: research },
    run: ({ researchResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = Object.values(pool)[0].agent;
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Create implementation plan based on research: ${researchResult.summary}`,
            outputSchema: out.plan,
          }),
        );
      }),
    timeout: "20m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const implement = $.step("implement", {
    output: out.implement,
    needs: { planResult: plan },
    run: ({ planResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = pool.codex.agent; // codex is the main workhorse
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Implement the plan at ${planResult.planFilePath}. Follow steps: ${(planResult.implementationSteps ?? []).join(", ")}`,
            outputSchema: out.implement,
          }),
        );
      }),
    timeout: "60m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const test = $.step("test", {
    output: out.test_results,
    needs: { implResult: implement },
    run: ({ implResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = pool.sonnet.agent; // sonnet for test runs
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Run tests after implementation: ${implResult.whatWasDone}. Commands: ${Object.values(target.testCmds).join(", ")}`,
            outputSchema: out.test_results,
          }),
        );
      }),
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const specReview = $.step("spec-review", {
    output: out.spec_review,
    needs: { implResult: implement, testResult: test },
    run: ({ implResult, testResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = pool.gemini.agent; // gemini for deep review
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Review implementation against specs. Files: ${[...(implResult.filesCreated ?? []), ...(implResult.filesModified ?? [])].join(", ")}. Tests: ${testResult.goTestsPassed ? "PASS" : "FAIL"}`,
            outputSchema: out.spec_review,
          }),
        );
      }),
    timeout: "20m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const codeReview = $.step("code-review", {
    output: out.code_review,
    needs: { implResult: implement },
    run: ({ implResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = pool.opus.agent; // opus for quality review
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Code review files: ${[...(implResult.filesCreated ?? []), ...(implResult.filesModified ?? [])].join(", ")}. Checklist: ${target.reviewChecklist.join("; ")}`,
            outputSchema: out.code_review,
          }),
        );
      }),
    timeout: "20m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  // -----------------------------------------------------------------------
  // Review-fix loop — iterate until reviews pass
  // -----------------------------------------------------------------------

  const reviewFix = $.step("review-fix", {
    output: out.review_fix,
    needs: { specResult: specReview, codeResult: codeReview },
    run: ({ specResult, codeResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = pool.codex.agent;
        const allClear = specResult.severity === "none" && codeResult.severity === "none";
        if (allClear) {
          return { allIssuesResolved: true, summary: "All reviews passed." };
        }
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Fix review issues. Spec: ${specResult.feedback}. Code: ${codeResult.feedback}`,
            outputSchema: out.review_fix,
          }),
        );
      }),
    timeout: "30m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  const report = $.step("report", {
    output: out.report,
    needs: { fixResult: reviewFix },
    run: ({ fixResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const agent = pool.sonnet.agent;
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Generate ticket report. Issues resolved: ${fixResult.allIssuesResolved}. ${fixResult.summary}`,
            outputSchema: out.report,
          }),
        );
      }),
    timeout: "15m",
    retry: WORKFLOW_TASK_RETRIES,
  });

  // -----------------------------------------------------------------------
  // Merge queue — land completed tickets
  // -----------------------------------------------------------------------

  const mergeQueue = $.step("merge-queue", {
    output: out.land,
    needs: { reportResult: report },
    run: ({ reportResult }) =>
      Effect.gen(function* () {
        const pool = yield* AgentPoolService;
        const mqAgentId = Object.entries(pool).find(([, e]) => e.isMergeQueue)?.[0] ?? Object.keys(pool)[0];
        const agent = pool[mqAgentId as keyof typeof pool].agent;
        if (reportResult.status !== "complete") {
          return {
            merged: false, mergeCommit: null, ciPassed: false,
            summary: `Ticket ${reportResult.ticketId} not complete: ${reportResult.status}`,
            evicted: false, evictionReason: null, evictionDetails: null,
            attemptedLog: null, attemptedDiffSummary: null, landedOnMainSinceBranch: null,
          };
        }
        return yield* Effect.promise(() =>
          agent.generate({
            prompt: `Land ticket ${reportResult.ticketId} to main. Run CI: ${Object.values(target.testCmds).join(", ")}`,
            outputSchema: out.land,
          }),
        );
      }),
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
    until: () => false, // runs forever — Ctrl+C to stop
    maxIterations: Infinity,
    onMaxReached: "return-last",
  });
});

// ---------------------------------------------------------------------------
// Prompt builders (simplified — full versions live in super-ralph MDX prompts)
// ---------------------------------------------------------------------------

function buildSchedulerPrompt(
  focusList: ReadonlyArray<{ readonly id: string; readonly name: string }>,
  tgt: ReturnType<typeof getTarget>,
): string {
  const focusTable = focusList
    .map((f) => `- ${f.id}: ${f.name}`)
    .join("\n");
  return `You are the ticket scheduler for ${tgt.name}.

Available focuses:
${focusTable}

Available agents:
${Object.entries(agentPool)
    .map(([id, { description }]) => `- ${id}: ${description}`)
    .join("\n")}

Schedule the next batch of jobs. Consider pipeline stages, dependencies, and agent strengths.
Max concurrency: ${WORKFLOW_MAX_CONCURRENCY}. Task retries: ${WORKFLOW_TASK_RETRIES}.`;
}

function buildDiscoverPrompt(
  tgt: ReturnType<typeof getTarget>,
  focusList: ReadonlyArray<{ readonly id: string; readonly name: string }>,
): string {
  return `Discover implementation tickets for ${tgt.name}.

Focuses:
${focusList.map((f) => `- ${f.id}: ${f.name}`).join("\n")}

Check ${tgt.specsPath} for specs. Check voltaire and guillotine-mini before creating tickets.
Reference files: ${tgt.referenceFiles.join(", ")}`;
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export default ZevmWorkflow;
