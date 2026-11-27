/**
 * The coding factory for evmts/zevm (https://smithers.sh/evmts/zevm):
 * featured flows, Dispatcher rules, Smithers Cloud repository workflow triggers,
 * GitHub trust policy, saved issue views and transitions, and the personalized
 * 3-audience app home (maintainer, contributor, everyone).
 *
 * Projected into .smithers/factory.json and .smithers/home.json by
 * //.smithers:factory-write and drift-checked by //.smithers:factory-check.
 * Edit this file, never the projected JSON files.
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
  // Two-way issue sync with GitHub. Maintainers merge via Smithers Cloud's
  // person-only pr/Merge flow, which pushes main on GitHub and triggers CI,
  // docs publishing (zevm.sh), and tagged npm/GitHub releases automatically.
  // Switch to { mirror: "push", changes: "land" } once evmts/zevm moves to
  // Smithers-hosted primary landing.
  github: S.Github.Policy({
    mirror: "pull",
    issues: "two-way",
    changes: "send-upstream",
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

export const home = S.Factory.Home({
  docs: "https://zevm.sh/docs/llms.txt",
  contributors: "role",
  sections: [
    {
      title: "Today",
      audience: "maintainer",
      blocks: [
        {
          type: "action",
          flow: "branch.new",
          title: "New branch",
          key: "b"
        },
        {
          type: "issues",
          title: "Issues and pull requests"
        },
        {
          type: "stack",
          title: "TODO stack"
        },
        {
          type: "runs",
          title: "Recent factory runs"
        },
        {
          type: "flows",
          title: "Maintainer flows"
        }
      ]
    },
    {
      title: "Contribute",
      audience: "contributor",
      blocks: [
        {
          type: "code",
          title: "Local setup, incremental CI, and Lighthouse backpressure",
          language: "sh",
          code: "bash tools/checkout-native.sh\nzig build --fetch\nscripts/smthrs ci '//...'\nnode tools/audit_report.mjs --run\n# Attach your agent via one-time-use Smithers Cloud MCP auth:\nnode tools/sandbox_auth.mjs --mode attach"
        },
        {
          type: "cards",
          title: "How contributions and trust work",
          cards: [
            {
              label: "Untrusted encouraged",
              title: "Run freely on your machine or fork",
              text: "Non-maintainers are encouraged to run tests, fuzzers, and Uphill audits locally. Trunk cache writes and required merge gates stay isolated to controlled sandboxes."
            },
            {
              label: "Repro first",
              title: "Start with a failing fixture or test",
              text: "Add the smallest failing Zig unit test, execution-apis transcript, or Lean property before changing production code."
            },
            {
              label: "Lighthouse backpressure",
              title: "Keep every audit score moving up",
              text: "Run uphill and node tools/audit_report.mjs to check safety, style, verification, conformance, docs, and factory hygiene before opening a change."
            },
            {
              label: "Human merge gate",
              title: "Connect via MCP, humans merge",
              text: "Agents interact over https://smithers.sh/evmts/zevm/mcp using one-time-use attach tokens. Only maintainers approve and merge."
            }
          ]
        },
        {
          type: "links",
          title: "Contributor workspace",
          links: [
            { label: "Issues", url: "https://smithers.sh/evmts/zevm/issues" },
            { label: "Pull requests", url: "https://smithers.sh/evmts/zevm/pulls" },
            { label: "Project Wiki", url: "https://smithers.sh/evmts/zevm/-/wiki" },
            { label: "Lighthouse Backpressure Audit", url: "https://zevm.sh/docs/audit/" },
            { label: "Qualification Map", url: "https://github.com/evmts/zevm/tree/main/docs/specs/qualification" },
            { label: "MCP Endpoint", url: "https://smithers.sh/evmts/zevm/mcp" }
          ]
        }
      ]
    },
    {
      audience: "everyone",
      blocks: [
        {
          type: "hero",
          title: "ZEVM",
          tagline: "Embeddable Zig Ethereum execution and proof-backed light-client node with C ABI, Node-API, WASM, and a Lean 4 formal spec.",
          text: "Powered by pinned Voltaire cryptography and Guillotine Mini execution with zero JavaScript EVM dependencies, built and verified continuously on Smithers Cloud.",
          install: "npm install @evmts/zevm",
          actions: [
            { label: "Read Docs", url: "https://zevm.sh/docs" },
            { label: "Backpressure Audit", url: "https://zevm.sh/docs/audit/" },
            { label: "GitHub Mirror", url: "https://github.com/evmts/zevm" }
          ],
          announcement: {
            label: "v0.1.0 native Zig engine: Fusaka/Osaka EIPs, Lean 4 spec (140k diff-fuzz cases, 0 divergences), ExEx + Rebase Fork",
            url: "https://zevm.sh/docs/audit/"
          }
        },
        {
          type: "code",
          title: "Embed ZEVM in Node.js (zero JS EVM)",
          file: "node.mjs",
          language: "js",
          code: "import { NativeNode } from \"@evmts/zevm\"\n\nconst node = new NativeNode({ chain_id: 31337 })\ntry {\n  const chainId = node.rpc(JSON.stringify({\n    jsonrpc: \"2.0\",\n    id: 1,\n    method: \"eth_chainId\",\n    params: []\n  }))\n  console.log(chainId)\n} finally {\n  node.close()\n}"
        },
        {
          type: "stats",
          stats: [
            { value: "Zig 0.15.2", label: "Native, C ABI, N-API, WASM" },
            { value: "140k / 0", label: "Lean 4 diff-fuzz cases / divergences" },
            { value: "99.0% / 98.7%", label: "Cancun & Prague GeneralStateTests" },
            { value: "30 Targets", label: "Coverage-guided Zig fuzzing" },
            { value: "11 Platforms", label: "macOS, Linux, FreeBSD, Windows" },
            { value: "MIT", label: "Open source on Smithers Cloud" }
          ]
        },
        {
          type: "cards",
          title: "Why ZEVM",
          cards: [
            {
              label: "Trusted mode",
              title: "Local dev and fork node",
              text: "Deterministic accounts, snapshots, mining controls, Hardhat console.log capture, ExEx event streams, and rebase forks."
            },
            {
              label: "Light mode",
              title: "Proof-backed consensus reads",
              text: "Beacon sync-committee BLS verification and MPT state proofs anchored to baked checkpoints for Mainnet, Sepolia, Holesky, and Hoodi."
            },
            {
              label: "Fusaka & Osaka",
              title: "Modern hardfork coverage",
              text: "EIP-7951 P256VERIFY, EIP-7825 gas cap, EIP-7934 block size cap, EIP-7892 BPO blobs, EIP-7918 reserve, EIP-7594 PeerDAS, and EIP-7910 eth_config."
            },
            {
              label: "Formal verification",
              title: "Lean 4 spec and 30 fuzz targets",
              text: "Zero-sorry Lean 4 reference spec differentially fuzzed against Zig alongside 14 property suites and Hive rpc-compat transcripts."
            },
            {
              label: "Embeddable",
              title: "C ABI, Node-API, and Browser WASM",
              text: "Call one verified Zig engine from C, Rust, Go, Node.js, or browsers through include/zevm.h and @evmts/zevm."
            },
            {
              label: "Smithers Factory",
              title: "Public backpressure and shared cache",
              text: "Incremental smthrs CI backed by build.smithers.sh, public Lighthouse audit reports, Obsidian wiki, and authenticated MCP."
            }
          ]
        },
        {
          type: "cards",
          title: "Bindings & Ecosystem",
          cards: [
            {
              label: "npm",
              title: "@evmts/zevm",
              text: "Prebuilt native N-API addons for 11 targets plus browser WASM backend with zero JavaScript EVM dependencies.",
              url: "https://www.npmjs.com/package/@evmts/zevm"
            },
            {
              label: "Primitives",
              title: "evmts/voltaire",
              text: "Pinned Zig Ethereum primitives, RLP, ABI, Keccak, secp256k1, BLS12-381, BN254, and KZG cryptography.",
              url: "https://smithers.sh/evmts/voltaire"
            },
            {
              label: "Execution",
              title: "evmts/guillotine-mini",
              text: "Spec-compliant Zig EVM interpreter plugged behind ZEVM's evm_backend seam.",
              url: "https://smithers.sh/evmts/guillotine-mini"
            },
            {
              label: "C Header",
              title: "include/zevm.h",
              text: "Stable C ABI for embedding trusted dev nodes and verified light clients in any host language.",
              url: "https://github.com/evmts/zevm/blob/main/include/zevm.h"
            },
            {
              label: "Audit UI",
              title: "Lighthouse Backpressure",
              text: "Live Uphill scorecards across safety, style, verification, Ethereum conformance, docs, and factory trust.",
              url: "https://zevm.sh/docs/audit/"
            },
            {
              label: "Agent API",
              title: "Smithers Cloud MCP",
              text: "Public Streamable HTTP MCP endpoint for agents to inspect code, docs, flows, issues, and PRs.",
              url: "https://smithers.sh/evmts/zevm/mcp"
            }
          ]
        },
        {
          type: "releases",
          title: "Releases",
          releases: [
            {
              name: "v0.1.0",
              url: "https://github.com/evmts/zevm/blob/main/CHANGELOG.md",
              date: "2026-11-26",
              summary: "Native Zig replacement for EthereumJS with Osaka/Fusaka EIPs, ExEx, rebase fork, Lean 4 spec, and 11-platform N-API + WASM."
            },
            {
              name: "v0.0.0",
              url: "https://www.npmjs.com/package/@evmts/zevm/v/0.0.0",
              date: "2026-05-25",
              summary: "Initial TypeScript and EthereumJS wrapper package (superseded by native Zig 0.1.0)."
            }
          ],
          more: {
            label: "Full changelog",
            url: "https://github.com/evmts/zevm/blob/main/CHANGELOG.md"
          }
        },
        {
          type: "flows",
          title: "Run or inspect a ZEVM flow"
        }
      ]
    }
  ]
})
