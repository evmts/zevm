# AGENTS.md

Follow the [Uphill rules](.agents/uphill/rules.md) (`uphill rules --write`): @.agents/uphill/rules.md

## Operating on Smithers Cloud

`evmts/zevm` is developed publicly through its Smithers Cloud Coding Factory:

- **Factory UI:** https://smithers.sh/evmts/zevm (personalized for Maintainers, Contributors, and Viewers)
- **Public MCP Server:** https://smithers.sh/evmts/zevm/mcp (Streamable HTTP; OAuth 2.1 or one-time BYOA attach)
- **Shared Object Store:** https://build.smithers.sh (split read/write tokens; trunk writes isolated to `main` CI)
- **Docs & `llms.txt`:** https://zevm.sh/docs and https://zevm.sh/docs/llms.txt
- **Lighthouse Backpressure Audit:** https://zevm.sh/docs/audit/
- **Obsidian Wiki & Mythical History:** `.smithers/wiki/` and `.smithers/history/epics.json`

## Agent Rules & Trust Boundaries

1. **Interact through Smithers Cloud MCP.** Use the Smithers MCP server (`https://smithers.sh/evmts/zevm/mcp`) and `smthrs` CLI to inspect issues, TODO stacks, pull requests, docs, flows, and artifacts.
2. **One-time-use sandbox auth only.** Never embed long-lived tokens or personal API keys in prompts, logs, or container images. Run `scripts/sandbox-auth --mode attach` to print the single-use BYOA attach command (`smthrs attach --intent <XXXX-XXXX> --origin https://smithers.sh`) or `scripts/sandbox-auth --mode gateway --ttl 30m` for short-lived scoped gateway tokens.
3. **Untrusted execution is encouraged, never authoritative.** Non-maintainers are encouraged to run tests, fuzzers, `scripts/smthrs ci '//...'`, and `node tools/audit_report.mjs --run --trust untrusted` locally and on forks. Untrusted runs never write to trunk cache (`SMITHERS_CACHE_NAMESPACE=pr-<N>`, no write token) and never skip controlled-sandbox merge gates.
4. **Person-only approvals and merges.** Agents never approve, merge, commit TODOs, or modify protected paths without maintainer review. Protected paths are enforced in `.smithers/FACTORY.ts`.
5. **Version control uses `jj`.** Use `jj --no-pager` for status, diff, log, workspaces, bookmarks, fetch, and push.
6. **Upstream ownership.** We maintain `../voltaire` and `../guillotine-mini`. Fix upstream defects there, push upstream, and bump `native-dependencies.json`.
7. **Zig style & allocator ownership.** See `CLAUDE.md` (no private imported-symbol aliases, explicit `std.mem.Allocator` ownership, zero leaks under `std.testing.allocator`).
8. **Backpressure before finishing.** Run:
   - `sh .smithers/checks/fast-check.sh`
   - `scripts/smthrs ci '//...'`
   - `node tools/audit_report.mjs --run`
   - If editing `.smithers/FACTORY.ts` or `.smithers/flows/**`: `scripts/smthrs target //.smithers:factory-write --write`
   - If editing `docs/`: `node tools/docs_mirror.mjs --write && node tools/generate_llms_txt.mjs --write`
