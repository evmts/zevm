---
title: Smithers Cloud Coding Factory & Trust Model
tags: [smithers, factory, security, cache, mcp, backpressure]
---

# Smithers Cloud Coding Factory & Trust Model

See [[Overview]], [[Formal-Verification-and-Fuzzing]], and [[Mythical-History]].

ZEVM is developed publicly through its Smithers Cloud Coding Factory at `https://smithers.sh/evmts/zevm`, mirrored continuously to GitHub (`evmts/zevm`).

## Personalized 3-Audience Factory UI

`.smithers/FACTORY.ts` projects `.smithers/home.json` with three audience-gated sections (`contributors: "role"`):

- **Maintainers (`Today`):** immediate `New branch` action (`b`), live issue/PR triage queue, TODO stack, recent runs, and maintainer flows.
- **Contributors (`Contribute`):** local setup, `smthrs ci`, Lighthouse backpressure commands, untrusted execution guidelines, one-time-use MCP attach instructions, and workspace links.
- **Viewers / Everyone:** instant pre-clone product hero (zero blocking `markdown` blocks), quickstart code, verified stats, subsystem cards, releases, and interactive flows.

## Shared Object Store & Untrusted Execution Isolation

- `.smithers/WORKSPACE.ts` connects to `https://build.smithers.sh` with split credentials:
  - `SMITHERS_CACHE_READ_TOKEN`: read-only token used by PRs and non-maintainers (server refuses `PUT`/`DELETE` with `403`).
  - `SMITHERS_CACHE_WRITE_TOKEN`: write token isolated strictly to the protected `cache-publish` GitHub Environment on `main` pushes.
  - Pull requests additionally scope to `SMITHERS_CACHE_NAMESPACE="pr-<number>"` for defense in depth.
- **Non-maintainers are encouraged to run tests, fuzzers, and Uphill audits locally and on forks**, because most contributors are honest. Those runs produce `untrusted` advisory audit reports and **can never write to trunk cache or skip required controlled-sandbox gates**.
- **Protected paths** (`github.protectedPaths`) guard `.smithers`, `.agents/uphill`, `.github/workflows`, `PACKAGE.ts`, `build.zig*`, `native-dependencies.json`, `include/zevm.h`, consensus files, `docs/specs/qualification`, and `spec/lean`.
- **Person-only approvals:** `policy.approvals` locks `approve` and `merge` to authenticated humans (`person`), never agents.

## Authenticated MCP & One-Time-Use Sandbox Auth

- Agents interact over Streamable HTTP MCP at `https://smithers.sh/evmts/zevm/mcp`.
- Never embed long-lived tokens in prompts, logs, or container images. Run `node tools/sandbox_auth.mjs` to print a clean one-time-use BYOA attach flow (`smthrs attach --intent <XXXX-XXXX> --origin https://smithers.sh`) or mint a short-lived scoped gateway token (`smthrs token mint --scope read:runs --ttl 30m`).
