export type Target = {
  id: "zevm";
  name: string;
  buildCmds: Record<string, string>;
  testCmds: Record<string, string>;
  fmtCmds: Record<string, string>;
  specsPath: string;
  codeStyle: string;
  reviewChecklist: string[];
  referenceFiles: string[];
};

export const ZEVM_TARGET: Target = {
  id: "zevm",
  name: "ZEVM — Zig Ethereum Virtual Machine (light client + trusted dev node)",
  buildCmds: {
    zig: "zig build",
  },
  testCmds: {
    zig: "zig build test",
  },
  fmtCmds: {
    zig: "zig fmt src/",
  },
  specsPath: "docs/specs/",
  codeStyle:
    "Zig 0.15: No local type aliases (always use fully qualified paths like std.mem.Allocator, primitives.Address). No stored allocators (pass explicitly to methods). snake_case for functions/variables, PascalCase for types.",
  reviewChecklist: [
    "DO NOT REINVENT — Before implementing anything, check if voltaire (../voltaire) already provides it. voltaire has: JSON-RPC types (65 methods with Params/Results), StateManager, ForkBackend, Blockchain, EVM, crypto, precompiles, primitives.",
    "DO NOT REINVENT — Check if guillotine-mini (../bench/guillotine-mini) already provides it. guillotine-mini has: RPC dispatch/routing, envelope parsing, response serialization, EVM interpreter, Engine API types.",
    "UPSTREAM FIRST — voltaire and guillotine-mini are upstream deps we own. If they're missing something, add it there, not in zevm.",
    "REFERENCE IMPLEMENTATIONS — Study tevm-monorepo, hardhat/edr, and foundry/anvil for behavior and edge cases before implementing.",
    "SPECS — Use execution-apis/ for JSON-RPC spec, execution-specs/ for EVM behavior, EIPs/ for individual proposals, consensus-specs/ for beacon chain, yellowpaper/ for formal spec.",
    "TESTS — Use ethereum-tests/ for golden test vectors, execution-spec-tests/ for hardfork-specific state tests, hive/ for integration tests.",
    "Zig style — No local type aliases (const Foo = bar.Foo). No stored allocators. Always use fully qualified paths. Good use of zig std library.",
    "Architecture — zevm is a thin integration layer. Heavy logic belongs in voltaire or guillotine-mini.",
    "Test coverage — every RPC method handler has a unit test. Integration tests against reference implementations where possible.",
    "Security — no command injection, proper input validation on all RPC params.",
  ],
  referenceFiles: [
    // Upstream deps we own (check before implementing)
    "../voltaire/packages/voltaire-zig/src/jsonrpc/",
    "../voltaire/packages/voltaire-zig/src/state-manager/",
    "../voltaire/packages/voltaire-zig/src/blockchain/",
    "../voltaire/packages/voltaire-zig/src/evm/",
    "../bench/guillotine-mini/client/rpc/",
    "../bench/guillotine-mini/client/engine/",
    // Reference implementations
    "edr/crates/edr_provider/src/requests/",
    "foundry/",
    "hardhat/",
    "../tevm-monorepo/packages/actions/src/",
    // Ethereum specs & tests
    "execution-apis/",
    "execution-specs/src/ethereum/",
    "ethereum-tests/",
    "execution-spec-tests/tests/",
    "EIPs/EIPS/",
    "consensus-specs/specs/",
    "yellowpaper/",
    "hive/simulators/ethereum/",
  ],
};

export function getTarget(_id?: string): Target {
  return ZEVM_TARGET;
}
