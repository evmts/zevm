# ZEVM Docs-First Process

Last updated: 2026-03-27

ZEVM is a docs-first product. The repository docs define the product contract before the code fully satisfies it.

The goal is twofold:

- a human reader should be able to read the docs and understand exactly how ZEVM is supposed to behave
- an agent should be able to use the docs as an executable source of truth for review, ticketing, test planning, and implementation

## Non-Negotiable Standard

ZEVM docs must describe the full intended contract, not a conceptual sketch.

When a surface is part of the product contract, the docs must specify it exactly, including:

- exact CLI flags
- exact config-file fields
- defaults
- precedence rules
- invalid combinations
- startup failure behavior
- JSON-RPC method names
- parameter shapes
- return payloads
- supported block tags
- notification behavior
- mode-specific gating
- error behavior

“Stay conceptual until implementation stabilizes” is not an acceptable ZEVM docs stance for startup, configuration, transport, or public JSON-RPC surfaces. Those surfaces are part of the product contract and must be documented exactly even when `HEAD` is incomplete.

## Authority Order

Use this order when writing or reviewing ZEVM docs:

1. `docs/specs/prd.md`
2. `docs/specs/docs-first-process.md`
3. `src/` and tests as implementation reality check and contradiction detector only
4. `docs/issues/*`, `docs/context/*`, `docs/plans/*`, and `PROGRESS.md` as non-normative evidence only

Repository-local control docs such as `docs/specs/maintainer-decisions.md`, `docs/specs/json-rpc-contract.md`, and the files under `docs/specs/internal/` are still required inputs, but they are support-layer artifacts. They may backfill exact detail or record an explicit contradiction plus public-doc stance for a surface; they must not silently override the PRD or this process doc.

Public docs may cite internal or control docs in traceability sections, but the main public prose must stand on its own. Do not outsource exact public contract detail to `docs/specs/json-rpc-contract.md` or any other internal page as a substitute for usable public documentation.

## Conflict Rule

When a support-layer control doc needs to diverge from the PRD or this process doc, it must explicitly record:

- the contradiction
- the affected surface
- the public-doc stance to follow until the higher-order docs are backfilled

If that explicit record is missing, treat the divergence as a blocking docs bug rather than as an implicit authority change.

## What The Docs Must Produce

The ZEVM docs set must collectively provide:

- public user docs that are explicit and directly usable
- public pages whose main prose is self-contained even when internal or control docs are cited in traceability blocks
- internal support docs that are more detailed than the public docs
- a complete startup contract for both modes
- a complete configuration contract
- a complete HTTP JSON-RPC transport contract
- a complete mode-by-mode method contract
- an authoritative exact JSON-RPC contract for phase 1 and the light-mode read surface
- a clear separation between intended behavior and current `HEAD`
- traceability from public pages back to authoritative claims and observed evidence

## Required Authoring Pattern

For every material surface:

1. define the intended contract completely
2. inspect `src/` and tests for current repo reality
3. record any mismatch explicitly
4. keep intended behavior and current `HEAD` behavior separate
5. when documenting repo health, record exact commands, absolute dates, and the top-level observed failure sites before inferring downstream drift

The correct response to ambiguity is to remove it in the docs or log it as an explicit open question. Do not hide ambiguity behind broad buckets like “startup settings”, “mode config”, or “status surface” when the product actually needs exact names and rules.

## Review Gate

The docs pass is not complete unless reviewers can answer all of the following from the docs alone:

- How does ZEVM start in each mode?
- Which exact flags and config fields does the user provide?
- What are the defaults?
- What wins when multiple configuration sources disagree?
- Which combinations are invalid?
- Which methods exist in each mode?
- What are the exact params and return payloads for the public JSON-RPC surface?
- How do notifications behave?
- What do `pending`, `safe`, `finalized`, `earliest`, and numeric selectors mean in each mode?
- What happens when light mode is not ready?
- Which parts describe the intended product contract versus current repo mismatch?

If those answers are missing, the docs are incomplete.

## Rule For Agents

Do not jump straight to implementation when the documented behavior is still ambiguous.

First improve the docs until the intended product behavior, startup contract, API behavior, and architecture are explicit enough to support confident ticket writing, review, testing, and code changes.
