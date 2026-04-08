# Runnable Dev Node And RPC Wiring

> **Archived / non-normative:** This issue is historical context only. Claims below are filing-time observations and may contradict current contract docs. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md); if anything differs, those normative docs win.
>
> **Resolved / superseded status:** This issue is closed as an active gap tracker and retained for archive history only. For current requirements and behavior, use [docs/specs/prd.md](../specs/prd.md), [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md), and [docs/specs/page-ownership.md](../specs/page-ownership.md).


## Historical Gap Snapshot At Filing Time

- `src/main.zig` only parses `--host` / `--port`, creates an empty `HandlerRegistry`, and starts the HTTP server.
- No startup path constructs `NodeRuntime`, `Database`, `Blockchain`, genesis state, receipt/log indexes, managed accounts, or a light-client sync engine.
- There is no mode selection for trusted dev node vs light client.
- The deterministic dev-account set is internally inconsistent today: `src/node/runtime.zig` and `src/genesis.zig` disagree on account `#7`.

## Evidence

- `build.zig`
- `src/main.zig`
- `src/rpc/server.zig`
- `src/rpc/dispatcher.zig`
- `src/node/runtime.zig`
- `src/genesis.zig`

## Historical Resolution Criteria

- `zig build` from a clean checkout produces a runnable binary.
- Default startup serves `eth_chainId`, `eth_blockNumber`, `eth_accounts`, and `eth_getBalance`.
- Startup initializes funded dev accounts, genesis head, coinbase, gas/base-fee config, and block gas limit consistently.
- Mode selection exists for trusted dev node vs light client, and invalid flag combinations fail deterministically.
- Runtime, genesis, banner output, and signing path agree on the same managed-account addresses and private keys.
