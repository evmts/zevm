/**
 * The coding factory for evmts/zevm (https://smithers.sh/evmts/zevm):
 * featured flows, Dispatcher rules, Smithers Cloud repository workflow triggers,
 * GitHub trust policy, saved issue views and transitions, and the personalized
 * 3-audience app home (maintainer, contributor, everyone).
 *
 * Projected into .smithers/factory.json by //.smithers:factory-write and
 * drift-checked by //.smithers:factory-check. Edit this file, never the JSON.
 *
 * The 3-audience homepage (maintainer, contributor, everyone) lives in
 * .smithers/HOME.mjs and projects into .smithers/home.json via
 * //.smithers:home-write and //.smithers:home-check.
 */
import { Smithers as S } from "@smthrs/targets"

// Pure data Trigger.Binding helpers (matches @smthrs/triggers Trigger.Binding
// schema verbatim without requiring root node_modules in a Zig repository).
const bind = (
  flow: string,
  on:
    | { readonly _tag: "Push"; readonly branches?: ReadonlyArray<string>; readonly tags?: ReadonlyArray<string> }
    | { readonly _tag: "PullRequest"; readonly branches?: ReadonlyArray<string>; readonly actions?: ReadonlyArray<string> }
    | { readonly _tag: "Manual" }
    | { readonly _tag: "Cron"; readonly cron: string; readonly timezone?: string; readonly overlap?: "skip" | "buffer-one" | "supersede" },
  title: string
) => ({ _tag: "TriggerBinding" as const, flow, on, title })

export const review = S.Flow({
  flow: "checks/review",
  featured: true,
  summary: "Review consensus, JSON-RPC contract, light-client safety, Zig ownership, and native ABI changes."
})

export const issueRepro = S.Flow({
  flow: "issue/repro",
  featured: true,
  summary: "Reproduce a ZEVM execution, RPC, or light-client defect with real fixtures before planning a fix."
})

export const issuePoc = S.Flow({
  flow: "issue/poc",
  featured: true,
  summary: "Implement a bounded fix with a failing regression first and incremental smthrs checks."
})

export const prTriage = S.Flow({
  flow: "pr-triage",
  featured: true,
  summary: "Assess pull request readiness from its diff and CI evidence without executing PR code."
})

export const conformanceReview = S.Flow({
  flow: "conformance-review",
  featured: true,
  summary: "Audit spec conformance, native pin drift, qualification coverage, and benchmark deltas."
})

export const auditReport = S.Flow({
  flow: "audit-report",
  featured: true,
  summary: "Run Uphill scoring and build the Lighthouse-style backpressure audit report and Factory feed."
})

export const playground = S.Flow({
  flow: "playground/exec",
  featured: true,
  summary: "Inspect ZEVM bytecode execution and local JSON-RPC opcode traces in a sandboxed devnet."
})

export const factory = S.Factory({
  summary: "ZEVM: native Zig Ethereum execution and light-client node with Lean 4 spec, Lighthouse backpressure, and Smithers CI.",
  flows: [review, issueRepro, issuePoc, prTriage, conformanceReview, auditReport, playground],
  on: {
    "issue.labeled:todo": {
      flow: "issue/poc",
      description: "Build a failing regression and bounded fix for every maintainer-accepted TODO"
    },
    "change.opened": {
      flow: "checks/review",
      description: "Review every Change across consensus, RPC, light client, memory, and build graph lenses"
    },
    "change.updated": {
      flow: "checks/review",
      description: "Re-review every updated Change before maintainer merge"
    },
    "change.landed": {
      flow: ["wiki-refresh", "docs-publish"],
      description: "Verify the Obsidian wiki, mythical history, and docs bundle after every landing"
    },
    "github.push:main": {
      flow: ["wiki-refresh", "docs-publish"],
      description: "Keep wiki citations, llms.txt, and docs artifacts aligned with main"
    },
    "schedule:17 9 * * 1": {
      flow: "conformance-review",
      description: "Weekly Monday conformance, native pin, and benchmark audit"
    }
  },
  triggers: {
    "ci-main": bind("ci", { _tag: "Push", branches: ["main"] }, "ZEVM CI on main"),
    "ci-pr": bind("ci", { _tag: "PullRequest" }, "ZEVM CI on pull request"),
    "uphill-main": bind("uphill", { _tag: "Push", branches: ["main"] }, "Lighthouse backpressure audit on main"),
    "uphill-pr": bind("uphill", { _tag: "PullRequest" }, "Lighthouse backpressure audit on pull request"),
    "docs-main": bind("docs-publish", { _tag: "Push", branches: ["main"] }, "Verify and build ZEVM docs + llms.txt"),
    "wiki-main": bind("wiki-refresh", { _tag: "Push", branches: ["main"] }, "Verify ZEVM wiki and mythical history"),
    "release-tag": bind("release-check", { _tag: "Push", tags: ["v*"] }, "Validate release parity and qualification metadata"),
    "weekly-backpressure": bind("uphill", { _tag: "Cron", cron: "17 9 * * 1", timezone: "UTC", overlap: "skip" }, "Weekly backpressure and conformance audit")
  },
  // Permanent Smithers Cloud switchover:
  // Smithers Cloud lands human-approved Changes and pushes main to GitHub,
  // which automatically triggers GitHub Actions CI, docs publishing (zevm.sh),
  // Lighthouse backpressure audits, and tagged npm/GitHub releases.
  github: S.Github.Policy({
    mirror: "push",
    issues: "two-way",
    changes: "land",
    maintainers: ["roninjin10"],
    dailyTokens: 1_000_000_000,
    protectedPaths: [
      ".smithers",
      ".agents/uphill",
      ".github/workflows",
      "PACKAGE.ts",
      "build.zig",
      "build.zig.zon",
      "native-dependencies.json",
      "include/zevm.h",
      "src/c_bindings.zig",
      "src/tx_processor.zig",
      "src/consensus_verifier.zig",
      "src/hardfork_schedule.zig",
      "src/light_default_checkpoints.zig",
      "docs/specs/qualification",
      "spec/lean"
    ]
  }),
  policy: {
    lifecycle: { docs: "evergreen", tests: "evergreen" },
    approvals: { approve: "person", merge: "person" }
  },
  machine: {
    vcpus: 4,
    memoryMiB: 8192,
    tools: ["zig", "cargo", "rustc", "cc", "node", "bun", "jq", "uphill"]
  },
  issueViews: [
    { id: "triage", title: "Needs triage", state: "open", labels: ["proposed"] },
    { id: "todo", title: "Committed TODOs", state: "open", labels: ["todo"] },
    { id: "bugs", title: "Open bugs", state: "open", labels: ["bug"] },
    { id: "consensus", title: "Consensus & EVM", state: "open", labels: ["consensus"] },
    { id: "rpc", title: "JSON-RPC parity", state: "open", labels: ["rpc"] },
    { id: "light-client", title: "Beacon light client", state: "open", labels: ["light-client"] },
    { id: "exex-rebase", title: "ExEx & rebase fork", state: "open", labels: ["exex"] },
    { id: "external-tests", title: "External test suites", state: "open", labels: ["external-tests"] }
  ],
  issueTransitions: [
    { id: "accept", title: "Accept for discussion", from: "proposed", to: "accepted", actor: "person" },
    { id: "needs-repro", title: "Needs minimal repro", from: "proposed", to: "needs-repro", actor: "anyone" },
    { id: "todo", title: "Commit to TODO", from: "accepted", to: "todo", actor: "person" },
    { id: "wontfix", title: "Decline proposal", from: "proposed", to: "wontfix", actor: "person" }
  ]
})
