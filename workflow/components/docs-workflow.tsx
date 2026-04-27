/** @jsxImportSource ../../docs/references/smithers/src */
import {
  createSmithers,
  CodexAgent,
  Loop,
  Sequence,
} from "../../docs/references/smithers/src/index";
import { z } from "zod";
import ImplementationPrompt from "../prompts/ImplementationPrompt.mdx";
import ColdReviewPrompt from "../prompts/ColdReviewPrompt.mdx";
import FixFindingsPrompt from "../prompts/FixFindingsPrompt.mdx";

const REPO_ROOT = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");

function parsePositiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return parsed;
}

function parseBooleanFlag(value: string | undefined): boolean {
  if (!value) {
    return false;
  }

  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

const MAX_ITERATIONS = parsePositiveInt(process.env.ZEVM_DOCS_MAX_ITERATIONS, 6);
const DB_PATH = process.env.ZEVM_DOCS_WORKFLOW_DB ?? "./zevm-docs.db";
const SMOKE_MODE = process.env.SMITHERS_DOCS_SMOKE === "1";
const SKIP_IMPLEMENTATION = parseBooleanFlag(process.env.ZEVM_DOCS_SKIP_IMPLEMENTATION);

const findingSchema = z.object({
  severity: z.enum(["critical", "high", "medium", "low"]),
  location: z.string(),
  problem: z.string(),
  requiredAction: z.string(),
});

const reviewSchema = z
  .object({
    verdict: z.enum(["LGTM", "CHANGES_REQUIRED"]),
    findings: z.array(findingSchema),
    blockers: z.array(z.string()),
    residualRisks: z.array(z.string()),
  })
  .superRefine((value, ctx) => {
    if (value.verdict === "LGTM" && (value.findings.length > 0 || value.blockers.length > 0)) {
      ctx.addIssue({
        code: "custom",
        message: "LGTM is only valid when there are zero findings and zero blockers.",
      });
    }

    if (
      value.verdict === "CHANGES_REQUIRED" &&
      value.findings.length === 0 &&
      value.blockers.length === 0
    ) {
      ctx.addIssue({
        code: "custom",
        message: "CHANGES_REQUIRED must include at least one finding or blocker.",
      });
    }
  });

const docsPassSchema = z
  .object({
    status: z.enum(["READY_FOR_COLD_REVIEW", "NEEDS_PRODUCT_DECISION"]),
    summary: z.string(),
    filesChanged: z.array(z.string()),
    productDecisionsNeeded: z.array(z.string()),
  })
  .superRefine((value, ctx) => {
    if (value.status === "READY_FOR_COLD_REVIEW" && value.productDecisionsNeeded.length > 0) {
      ctx.addIssue({
        code: "custom",
        message: "READY_FOR_COLD_REVIEW is only valid when there are zero unresolved product decisions.",
      });
    }

    if (
      value.status === "NEEDS_PRODUCT_DECISION" &&
      value.productDecisionsNeeded.length === 0
    ) {
      ctx.addIssue({
        code: "custom",
        message: "NEEDS_PRODUCT_DECISION must include at least one unresolved product decision.",
      });
    }
  });

const gateSchema = z.object({
  ok: z.boolean(),
  reason: z.string(),
});

const summarySchema = z.object({
  finalVerdict: z.enum(["LGTM", "CHANGES_REQUIRED"]),
  reviewIterations: z.number().int().nonnegative(),
  finalSummary: z.string(),
});

const { Workflow, Task, smithers, outputs } = createSmithers(
  {
    docsPass: docsPassSchema,
    review: reviewSchema,
    gate: gateSchema,
    summary: summarySchema,
  },
  {
    dbPath: DB_PATH,
  },
);

const IMPLEMENTATION_SYSTEM_PROMPT = `You are operating inside the ZEVM repository.

This workflow is docs-only.
Ignore src, tests, build state, and implementation artifacts unless the human explicitly changes the rules.

Focus on the docs corpus:
- docs/specs/prd.md
- relevant docs under docs/
- public docs under docs/

Use subagents heavily and intelligently.
Prefer explorer passes before editing.
Keep write scopes disjoint when delegating.
Keep the final integration coherent.
`;

const REVIEW_SYSTEM_PROMPT = `You are operating inside the ZEVM repository.

This task is a cold docs review.
Ignore src, tests, build state, and implementation artifacts unless the human explicitly changes the rules.

Review the docs corpus as a self-contained product-definition system.
Use subagents intelligently and keep the final judgment integrated.
`;

function createSmokeAgent(kind: "implementation" | "review" | "fix") {
  return {
    id: `smoke-${kind}`,
    tools: {},
    async generate(args: { prompt: string }) {
      if (kind === "implementation") {
        return {
          output: {
            status: "READY_FOR_COLD_REVIEW",
            summary: "Smoke implementation pass completed.",
            filesChanged: [
              "docs/specs/prd.md",
              "docs/specs/internal/runtime-modes-and-boundaries.md",
              "docs/index.mdx",
            ],
            productDecisionsNeeded: [],
          },
        };
      }

      if (kind === "fix") {
        return {
          output: {
            status: "READY_FOR_COLD_REVIEW",
            summary: "Smoke fix pass applied the cold-review findings.",
            filesChanged: [
              "docs/specs/prd.md",
              "docs/index.mdx",
            ],
            productDecisionsNeeded: [],
          },
        };
      }

      const roundMatch = args.prompt.match(/Review round:\s*(\d+)/i);
      const reviewRound = roundMatch ? Number.parseInt(roundMatch[1] ?? "0", 10) : 0;

      if (reviewRound >= 1) {
        return {
          output: {
            verdict: "LGTM",
            findings: [],
            blockers: [],
            residualRisks: [],
          },
        };
      }

      return {
        output: {
          verdict: "CHANGES_REQUIRED",
          findings: [
            {
              severity: "medium",
              location: "docs/specs/prd.md",
              problem: "Smoke review found an intentionally unresolved wording inconsistency.",
              requiredAction: "Normalize the product wording across the PRD and public docs.",
            },
          ],
          blockers: [],
          residualRisks: [],
        },
      };
    },
  };
}

const implementationAgent = SMOKE_MODE
  ? createSmokeAgent("implementation")
  : new CodexAgent({
      model: "gpt-5.4",
      cwd: REPO_ROOT,
      yolo: true,
      timeoutMs: 60 * 60 * 1000,
      config: {
        model_reasoning_effort: "xhigh",
      },
      systemPrompt: IMPLEMENTATION_SYSTEM_PROMPT,
    });

const fixAgent = SMOKE_MODE
  ? createSmokeAgent("fix")
  : new CodexAgent({
      model: "gpt-5.4",
      cwd: REPO_ROOT,
      yolo: true,
      timeoutMs: 60 * 60 * 1000,
      config: {
        model_reasoning_effort: "xhigh",
      },
      systemPrompt: IMPLEMENTATION_SYSTEM_PROMPT,
    });

const reviewAgent = SMOKE_MODE
  ? createSmokeAgent("review")
  : new CodexAgent({
      model: "gpt-5.4",
      cwd: REPO_ROOT,
      yolo: true,
      timeoutMs: 45 * 60 * 1000,
      config: {
        model_reasoning_effort: "xhigh",
      },
      systemPrompt: REVIEW_SYSTEM_PROMPT,
    });

export default smithers((ctx) => {
  const latestReview = ctx.latest("review", "cold-review");
  const latestFix = ctx.latest("docsPass", "fix-findings");
  const latestImplementation = ctx.latest("docsPass", "implementation");
  const reviewRound = ctx.iterations?.["docs-review-loop"] ?? 0;
  const reviewApproved = latestReview?.verdict === "LGTM";
  const lastDocsPass = latestFix ?? latestImplementation;

  return (
    <Workflow name="zevm-docs-convergence-loop" cache={false}>
      <Sequence>
        {!SKIP_IMPLEMENTATION ? (
          <Task
            id="implementation"
            output={outputs.docsPass}
            agent={implementationAgent}
            timeoutMs={60 * 60 * 1000}
          >
            <ImplementationPrompt />
          </Task>
        ) : null}

        {!SKIP_IMPLEMENTATION ? (
          <Task id="implementation-gate" output={outputs.gate}>
            {() => {
              if (!latestImplementation) {
                throw new Error("Implementation pass did not produce output.");
              }

              if (latestImplementation.status !== "READY_FOR_COLD_REVIEW") {
                throw new Error(
                  `Implementation requires a product decision: ${latestImplementation.productDecisionsNeeded.join(" | ")}`,
                );
              }

              return {
                ok: true,
                reason: "Implementation pass is ready for cold review.",
              };
            }}
          </Task>
        ) : null}

        <Loop
          id="docs-review-loop"
          until={reviewApproved}
          maxIterations={MAX_ITERATIONS}
          onMaxReached="fail"
        >
          <Sequence>
            <Task
              id="cold-review"
              output={outputs.review}
              agent={reviewAgent}
              timeoutMs={45 * 60 * 1000}
            >
              <ColdReviewPrompt reviewRound={reviewRound} />
            </Task>

            <Task
              id="fix-findings"
              output={outputs.docsPass}
              agent={fixAgent}
              timeoutMs={60 * 60 * 1000}
              skipIf={reviewApproved}
            >
              <FixFindingsPrompt
                reviewRound={reviewRound}
                reviewVerdict={latestReview?.verdict ?? "CHANGES_REQUIRED"}
                findings={latestReview?.findings ?? []}
                blockers={latestReview?.blockers ?? []}
                residualRisks={latestReview?.residualRisks ?? []}
              />
            </Task>

            <Task id="fix-gate" output={outputs.gate} skipIf={reviewApproved}>
              {() => {
                if (!latestFix) {
                  throw new Error("Fix pass did not produce output.");
                }

                if (latestFix.status !== "READY_FOR_COLD_REVIEW") {
                  throw new Error(
                    `Fix pass requires a product decision: ${latestFix.productDecisionsNeeded.join(" | ")}`,
                  );
                }

                return {
                  ok: true,
                  reason: "Fix pass is ready for the next cold review.",
                };
              }}
            </Task>
          </Sequence>
        </Loop>

        <Task id="final-summary" output={outputs.summary}>
          {() => ({
            finalVerdict: latestReview?.verdict ?? "CHANGES_REQUIRED",
            reviewIterations: ctx.iterationCount("review", "cold-review"),
            finalSummary:
              latestReview?.verdict === "LGTM"
                ? "LGTM"
                : lastDocsPass?.summary ??
                  "Review loop ended without a final summary.",
          })}
        </Task>
      </Sequence>
    </Workflow>
  );
});
