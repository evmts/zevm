# ZEVM Documentation Process

Last updated: 2026-03-30

ZEVM documentation is contract-first.

## Purpose

The documentation set must define ZEVM behavior clearly enough to drive implementation, review, and external integration without hidden assumptions.

## Contract Sources

Normative product-definition sources are:

1. `docs/specs/prd.md`
2. `docs/specs/json-rpc-contract.md`

Support summaries live under `docs/specs/internal/*` and help explain the normative contract, but they do not override it.

Historical planning/audit artifacts under `docs/specs/*` and `docs/issues/*` that are marked archival are non-normative.

`docs/context/*` and `docs/plans/*` are historical implementation artifacts and are non-normative unless a file is explicitly marked otherwise.

## Documentation Standard

For product surfaces, docs must be explicit and testable:

- startup flags and config fields
- defaults and precedence rules
- invalid combinations and startup failures
- runtime-mode boundaries
- transport and envelope behavior
- method availability by mode
- exact params, payloads, selectors, and errors

Avoid ambiguous language for behaviors that affect user-visible runtime semantics.

## Change Rules

When updating ZEVM docs:

1. update normative contract docs first (`prd.md`, `json-rpc-contract.md`) if behavior changes
2. update internal support summaries to match
3. update public Mintlify docs to match
4. remove or archive stale process artifacts that could conflict with current contract docs
5. when mapped normative or public pages change, refresh any referenced internal support docs in the same PR and keep their `Last updated` metadata aligned with that docs cycle

## Review Gate

A docs pass is complete only when a reviewer can answer, from docs alone:

- how ZEVM starts in each mode
- which flags/config fields are accepted
- what defaults and precedence apply
- which startup combinations fail
- which methods are supported in each mode
- exact method params/results/errors for the published JSON-RPC surface
- selector and readiness semantics in trusted vs light mode

If any of these are unclear, the docs pass is incomplete.
