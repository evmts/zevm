# CLAUDE.md

Follow the [Uphill rules](.agents/uphill/rules.md), which `uphill rules --write` rewrites from each metric's description: @.agents/uphill/rules.md

## Smithers Cloud Factory & MCP

- **Factory & MCP:** `evmts/zevm` runs on Smithers Cloud (`https://smithers.sh/evmts/zevm`, MCP at `https://smithers.sh/evmts/zevm/mcp`). See `AGENTS.md` and `.smithers/wiki/Smithers-Factory-and-Trust.md` for one-time-use sandbox auth (`scripts/sandbox-auth`), untrusted execution isolation, and Lighthouse backpressure (`node tools/audit_report.mjs --run`).
- **Wiki & Mythical History:** Keep `.smithers/wiki/` and `.smithers/history/epics.json` updated alongside architectural changes (`node tools/wiki_sync.mjs --check`).

## Project Context

- **We maintain voltaire (`../voltaire`) and guillotine-mini (`../guillotine-mini`).** They are upstream dependencies and we own them. Fix any issues in those repos directly rather than working around them.

## Zig Style

- **Avoid private imported-symbol aliases.** Do not create private top-level aliases like `const Foo = bar.Foo`; use the fully qualified path inline instead (for example `std.mem.Allocator`, `primitives.Address`, `primitives.AccountState.AccountState`). Top-level module imports such as `const std = @import("std")` and deliberate public re-exports that define a module API are allowed. Local aliases inside a function are acceptable for comptime-generated or generic types when the fully qualified expression would obscure the implementation.
- **Make allocator ownership explicit.** Prefer passing `std.mem.Allocator` to stateless helpers, short-lived operations, and unmanaged collection methods. Storing an allocator is allowed only for owning lifecycle types that allocate and free memory across multiple methods or background work, such as `NodeRuntime`, `RpcServer`, and `TransactionPool`. A type that stores an allocator must use it consistently for owned allocations and free those allocations from `deinit`.
