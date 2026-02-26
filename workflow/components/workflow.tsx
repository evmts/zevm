import { Workflow, smithers, outputs } from "../smithers";
import { getTarget } from "../targets";
import { focuses } from "./focuses";
import { SuperRalph } from "super-ralph";
import { WORKFLOW_MAX_CONCURRENCY, WORKFLOW_TASK_RETRIES } from "../config";
import {
  GeminiAgent,
  ClaudeCodeAgent,
  CodexAgent,
  KimiAgent,
} from "smithers-orchestrator";
import { focusTestSuites } from "./focusTestSuites";
import { focusDirs } from "./focusDirs";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const REPO_ROOT = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");

const agentmd = readFileSync(join(__dirname, "..", "..", "CLAUDE.md"));

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

We will be making our client able to run as a full client in future too

Plan and research for ZEVM, a Zig Ethereum client that serves as both a light client and a trusted dev node (like Hardhat/Anvil).

CRITICAL — DO NOT REINVENT THE WHEEL:
Before implementing ANYTHING, you MUST check these upstream dependencies (we own all of them):
1. voltaire (../voltaire/packages/voltaire-zig/src/) — has JSON-RPC types for 65 methods (Params/Results with JSON serde), StateManager with fork support, ForkBackend with RPC client + caching, Blockchain with block storage, full EVM, crypto (BLS, secp256k1, keccak), precompiles, and all Ethereum primitives
2. guillotine-mini (../bench/guillotine-mini/) — has EVM interpreter, RPC dispatch/routing (client/rpc/), envelope parsing, response serialization, Engine API
3. If voltaire or guillotine-mini are MISSING something you need, add it THERE, not in zevm

REFERENCE IMPLEMENTATIONS (read for behavior/edge cases, do not copy wholesale):
4. tevm-monorepo (../tevm-monorepo/packages/actions/src/) — TypeScript trusted client with eth/anvil/debug handlers
5. hardhat EDR (edr/crates/edr_provider/src/requests/) — Rust dev node with 73 RPC methods
6. foundry anvil (foundry/) — Rust dev node reference
7. If the reference implementation includes e2e or integration tests that are a black box and can be easily replicated we should flag them and make sure we port them

ALREADY DONE in zevm 
Explore zevm to learn what has and has not been done

ZIG STYLE:
- No local type aliases (no "const Foo = bar.Foo"). Always use fully qualified paths.
- No stored allocators. Pass allocator explicitly to methods.
- Zig 0.15 with lowercase @typeInfo variants (.int, .bool, .float).

Tun tests for ZEVM. Use: zig build test

CRITICAL — DO NOT REINVENT THE WHEEL:
voltaire and guillotine-mini (upstream deps we own) already provide most infrastructure.
Only test zevm's integration layer — the wiring between voltaire/guillotine-mini and RPC handlers.

ALREADY PASSING (maintain, don't rewrite):
- tx_processor_test.zig — intrinsic gas, ETH transfers, precompiles, nonce validation
- host_adapter_test.zig — vtable delegation, balance/nonce/code/storage
- block_builder_test.zig — gas limit enforcement, invalid tx filtering
- consensus_verifier_test.zig, beacon_api_test.zig, consensus_sync_test.zig, checkpoint_test.zig
- database_test.zig

ZIG STYLE:
- No local type aliases. No stored allocators. Fully qualified paths only.
- No useless methods that are only 1 or 2 lines of code. Just inline
- Minimize abstractions in favor of inlining code except where abstraction is high leverage
`;

export default smithers((ctx) => {
  return (
    <Workflow name="zevm-slop-factory">
      <SuperRalph
        ctx={ctx}
        outputs={outputs}
        focuses={focuses}
        projectId={getTarget().id}
        projectName={getTarget().name}
        specsPath={getTarget().specsPath}
        referenceFiles={getTarget().referenceFiles}
        buildCmds={getTarget().buildCmds}
        testCmds={getTarget().testCmds}
        codeStyle={getTarget().codeStyle}
        reviewChecklist={getTarget().reviewChecklist}
        maxConcurrency={WORKFLOW_MAX_CONCURRENCY}
        taskRetries={WORKFLOW_TASK_RETRIES}
        agents={{
          opus: {
            agent: new ClaudeCodeAgent({
              model: "claude-opus-4-6",
              systemPrompt: SYSTEM_PROMPT,
              cwd: REPO_ROOT,
              permissionMode: "bypassPermissions",
              timeoutMs: 30 * 60 * 1000,
            }),
            description:
              "Best orchestrator and deepest thinker. Use for the most important research tasks that require careful reasoning about how to integrate voltaire/guillotine-mini. Expensive — reserve for high-stakes work.",
          },
          codex: {
            agent: new CodexAgent({
              model: "gpt-5.3-codex",
              systemPrompt: SYSTEM_PROMPT,
              cwd: REPO_ROOT,
              yolo: true,
              config: { model_reasoning_effort: "high" },
              timeoutMs: 30 * 60 * 1000,
            }),
            description:
              "Main workhorse for bulk implementation. Good at following instructions and writing Zig code. Use for most implementation tickets.",
          },
          sonnet: {
            agent: new ClaudeCodeAgent({
              model: "claude-sonnet-4-6",
              systemPrompt: SYSTEM_PROMPT,
              cwd: REPO_ROOT,
              permissionMode: "bypassPermissions",
              timeoutMs: 30 * 60 * 1000,
            }),
            description:
              "Fast Claude model for testing, review-fix cycles, and lighter research. Good balance of speed and quality.",
            isScheduler: true,
            isMergeQueue: true,
          },
          gemini: {
            agent: new GeminiAgent({
              model: "gemini-3.1-pro-preview",
              systemPrompt: SYSTEM_PROMPT,
              cwd: REPO_ROOT,
              yolo: true,
              timeoutMs: 30 * 60 * 1000,
            }),
            description:
              "Very smart with large context window. Best for planning, reading reference implementations (edr, tevm-monorepo), and architecture analysis. Unreliable at tool calls. CAUTION: Has strict rate limits — avoid scheduling multiple gemini tasks in parallel or back-to-back.",
          },
          kimi: {
            agent: new KimiAgent({
              systemPrompt: SYSTEM_PROMPT,
              cwd: REPO_ROOT,
              timeoutMs: 30 * 60 * 1000,
              finalMessageOnly: true,
            }),
            description:
              "Cheapest agent. Use as much as possible for simple work: straightforward RPC handler wiring, boilerplate, and low-complexity tickets.",
          },
        }}
        focusTestSuites={focusTestSuites}
        focusDirs={focusDirs}
      />
    </Workflow>
  );
});
