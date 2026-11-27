# ZEVM Coding Factory on Smithers Cloud

ZEVM (`evmts/zevm`) is built, audited, and published through its public Smithers Cloud Coding Factory at **https://smithers.sh/evmts/zevm** (mirrored to GitHub).

## Architecture at a Glance

- **Workspace & Shared Object Store (`.smithers/WORKSPACE.ts`):** incremental build graph (`PACKAGE.ts`, `bench/**/PACKAGE.ts`, `.smithers/PACKAGE.ts`) backed by `https://build.smithers.sh` using split read/write credentials.
- **Factory & Personalized 3-Audience Home (`.smithers/FACTORY.ts`):** projects into checked-in `.smithers/factory.json` (`apiVersion: 1`, `contributes.triggers`, `policy`, `machine`, `issueViews`, `issueTransitions`, `github`) and `.smithers/home.json` (`docs: "https://zevm.sh/docs/llms.txt"`, `contributors: "role"`, `sections` for `maintainer`, `contributor`, and `everyone`).
- **Lighthouse Backpressure (`.agents/uphill/` + `tools/audit_report.mjs`):** 7 scored categories (`safety`, `style`, `footprint`, `verification`, `documentation`, `conformance`, `factory`) rendered as an interactive Lighthouse HTML report (`.uphill/audit-report.html` and `https://zevm.sh/docs/audit/`) plus a Smithers Factory feed JSON.
- **Obsidian Wiki & Mythical History (`.smithers/wiki/` + `.smithers/history/epics.json`):** verified wikilinks and source citations projected to `plugins/wiki` via `tools/wiki_sync.mjs`.
- **Authenticated MCP & One-Time Sandbox Auth (`tools/sandbox_auth.mjs`):** Streamable HTTP MCP at `https://smithers.sh/evmts/zevm/mcp` with single-use BYOA attach (`smthrs attach --intent <XXXX-XXXX> --origin https://smithers.sh`) and scoped gateway token minting (`smthrs token mint`).
- **Sandboxed Execution Workbench (`.smithers/playground/`):** bounded in-memory NativeNode bytecode tracer with strict SHA-256 CSP (`node .smithers/playground/csp.mjs --check`).

## Trust & Untrusted Execution Model

- **Non-maintainers are encouraged to run tests, fuzzers, and Uphill audits locally and on PRs.**
- Pull requests and external runs execute with `SMITHERS_TRUST=untrusted`, `SMITHERS_CACHE_NAMESPACE=pr-<N>`, and zero write tokens (`build.smithers.sh` returns `403` on writes with a read token).
- Untrusted runs produce full advisory audit reports clearly badged `Untrusted External Run`, and can **never** poison trunk cache or skip required controlled-sandbox merge gates.
- Approvals and merges are locked to authenticated humans (`policy.approvals: { approve: "person", merge: "person" }`, `.smithers/merge.json`).

## Native Dependency Keys

`build.zig.zon` resolves `../voltaire` and `../guillotine-mini` by path outside the workspace. `tools/native_deps_digest.mjs` hashes both sibling source trees (with symlink-cycle protection) into `.native-deps.digest` (gitignored), and every Zig target keys on that file. Check out pinned siblings with `bash tools/checkout-native.sh`.

## Commands

```sh
# Fast tier-1 hygiene checks (seconds)
sh .smithers/checks/fast-check.sh

# Full incremental Smithers CI
scripts/smthrs ci '//...'

# Lighthouse-style Backpressure Audit Report
node tools/audit_report.mjs --run --publish-docs docs/public/audit/index.html

# Regenerate & verify factory.json + home.json after editing .smithers/FACTORY.ts
scripts/smthrs target //.smithers:factory-write --write
scripts/smthrs ci //.smithers:factory-check

# Verify Obsidian wiki & mythical history (add --push with SMITHERS_FEED_KEY to sync to smithers.sh)
node tools/wiki_sync.mjs --check --out .smithers/reports/wiki-feed.json

# Print one-time-use sandbox auth handoff for agents
scripts/sandbox-auth --mode attach
scripts/sandbox-auth --mode untrusted --pr 42
```
