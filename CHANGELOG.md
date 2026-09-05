# Changelog

## 0.1.0

- Always return canonical `difficulty` and `totalDifficulty` quantities in block responses, including zero-valued dev blocks.
- Embed the execution node through the C ABI and JavaScript Node-API bindings.
- Execute using adjacent Voltaire and Guillotine Mini sources, with immutable CI pins.
- Support serialized native JSON-RPC, fork state resolution, deployment, state editing,
  mining, receipts, filters, and bounded opcode tracing for the TEVM host.
- Remove the EthereumJS implementation and all owned TypeScript source.
- Preserve constructor output and structured execution failure diagnostics.

This is a breaking replacement for the old EthereumJS re-export package.
