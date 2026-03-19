# ZEVM Docs-First Process

We are building ZEVM docs first, before implementation work.

The goal is to make ZEVM explicit enough that a human can read the docs and understand exactly how the product should work, while an agent can use the same docs as a precise source of truth for review, ticket writing, and code generation.

## What We Are Producing

- public, user-facing docs that explain ZEVM clearly and accessibly
- internal product/spec docs that are more detailed than the public docs
- a complete description of the API surface, expected behavior, mode boundaries, and relevant architecture

The docs should be as thorough as possible. They should remove ambiguity, not hand-wave over it.

## Standard

The docs should be:

- easy for a human to read
- detailed enough for agents to execute against
- explicit about API behavior, not just high-level concepts
- clear about what is supported, unsupported, deferred, or mode-specific
- specific enough that we can review the design from the docs before touching code

## How We Use The Docs

We use the docs as the primary artifact for:

1. reviewing and refining the product shape
2. identifying unclear or missing behavior
3. breaking the work into tickets
4. defining the tests needed for confidence
5. implementing the code against the documented behavior

The intended flow is:

1. write the docs as completely as possible
2. review the docs and ask follow-up questions where behavior is still unclear
3. derive issues and implementation plans from the docs plus the source code
4. build and verify the code against the docs

## Rule For Agents

Do not jump straight to implementation when the documented behavior is still ambiguous.

First improve the docs until the intended product behavior, API, and architecture are clear enough to support confident ticket-writing and code changes.
