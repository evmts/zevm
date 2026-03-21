# ZEVM Docs-First Process

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

## Evidence Hierarchy

Use this order when writing or reviewing ZEVM docs:

1. `docs/specs/prd.md`
2. `docs/specs/docs-first-process.md`
3. `src/` and tests
4. `docs/issues/*`, `docs/context/*`, `docs/plans/*`, `PROGRESS.md`

Repository-local docs remain the primary authority. Code and tests are reality checks. Secondary evidence may explain context, but it must not silently override the PRD or replace repo-primary evidence.

## What The Docs Must Produce

The ZEVM docs set must collectively provide:

- public user docs that are explicit and directly usable
- internal support docs that are more detailed than the public docs
- a complete startup contract for both modes
- a complete configuration contract
- a complete HTTP JSON-RPC transport contract
- a complete mode-by-mode method contract
- a clear separation between intended behavior and current `HEAD`
- traceability from public pages back to authoritative claims and observed evidence

## Required Authoring Pattern

For every material surface:

1. define the intended contract completely
2. inspect `src/` and tests for current repo reality
3. record any mismatch explicitly
4. keep intended behavior and current `HEAD` behavior separate

The correct response to ambiguity is to remove it in the docs or log it as an explicit open question. Do not hide ambiguity behind broad buckets like “startup settings”, “mode config”, or “status surface” when the product actually needs exact names and rules.

## Review Gate

The docs pass is not complete unless reviewers can answer all of the following from the docs alone:

- How does ZEVM start in each mode?
- Which exact flags and config fields does the user provide?
- What are the defaults?
- What wins when multiple configuration sources disagree?
- Which combinations are invalid?
- Which methods exist in each mode?
- How do notifications behave?
- What do `pending`, `safe`, and `finalized` mean in each mode?
- What happens when light mode is not ready?
- Which parts describe the intended product contract versus current repo mismatch?

If those answers are missing, the docs are incomplete.

## Rule For Agents

Do not jump straight to implementation when the documented behavior is still ambiguous.

First improve the docs until the intended product behavior, startup contract, API behavior, and architecture are explicit enough to support confident ticket writing, review, testing, and code changes.
