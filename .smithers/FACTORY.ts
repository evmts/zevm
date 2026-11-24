/**
 * The factory that develops evmts/zevm: featured flows, Dispatcher rules,
 * GitHub policy, and the app home. Projected into .smithers/factory.json and
 * .smithers/home.json by //.smithers:factory-write and drift-checked by
 * //.smithers:factory-check.
 */
import { Smithers as S } from "@smthrs/targets"

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

export const factory = S.Factory({
  summary: "ZEVM: incremental Zig/C/N-API CI, Ethereum spec conformance, native pin hygiene, and maintainer triage.",
  flows: [review, issueRepro, issuePoc, prTriage, conformanceReview],
  on: {
    "schedule:17 9 * * 1": {
      flow: "conformance-review",
      description: "Weekly Monday conformance, native pin, and benchmark audit"
    }
  },
  github: S.Github.Policy({
    mirror: "pull",
    issues: "read",
    changes: "send-upstream",
    maintainers: ["roninjin10"],
    protectedPaths: [
      "build.zig.zon",
      "native-dependencies.json",
      "include/zevm.h",
      "src/c_bindings.zig",
      "src/tx_processor.zig",
      "src/consensus_verifier.zig",
      "src/hardfork_schedule.zig",
      "src/light_default_checkpoints.zig",
      "docs/specs/qualification"
    ]
  })
})

export const home = S.Factory.Home({
  blocks: [
    {
      type: "text",
      title: "ZEVM factory",
      text: "Embeddable Zig Ethereum node: execution on guillotine-mini, primitives from Voltaire, JSON-RPC, a beacon light client, and C and Node-API bindings. Every Zig target keys on the pinned sibling sources, so `smthrs ci //...` replays unchanged checks locally and from the Smithers remote cache."
    },
    {
      type: "prompt",
      title: "Ask about ZEVM",
      placeholder: "Describe an execution, JSON-RPC, light-client, or binding issue…"
    },
    {
      type: "flows",
      title: "Review, reproduce, and audit"
    },
    {
      type: "links",
      links: [
        { label: "Repository", url: "https://github.com/evmts/zevm" },
        { label: "CI", url: "https://github.com/evmts/zevm/actions/workflows/ci.yml" },
        { label: "Docs", url: "https://zevm.sh/docs" },
        { label: "Qualification map", url: "https://github.com/evmts/zevm/tree/main/docs/specs/qualification" }
      ]
    }
  ]
})
