# ZEVM Internal Support: Phase 1 Product Shape

Last updated: 2026-03-21

## Product Boundary

- intended behavior: phase 1 is a trusted-mode local execution node with one public product surface: startup, HTTP JSON-RPC transport, core reads, execution simulation, transaction submission, mining controls, canonical queries, snapshots, and fork-aware dev workflows. Light mode remains part of ZEVM's product contract, but its verified-read surface is phase 2.
- observed repo reality: `src/main.zig` only wires `src/rpc/server.zig` with `--host` and `--port`, the executable path still does not compose a trusted runtime, and the light-client components are not exposed through startup.
- consequence for docs: public docs must keep the intended phase-1 contract intact while stating plainly that current `HEAD` does not yet implement a runnable trusted node.
- source IDs: `ARCH-01`, `BOOT-01`, `BOOT-02`, `RPC-01`, `RPC-04`, `RPC-05`, `RPC-06`, `LIGHT-01`, `LIGHT-04`, `LIGHT-05`
- contradiction IDs: `C-001`, `C-002`, `C-003`, `C-004`, `C-005`, `C-006`, `C-010`, `C-011`, `C-012`

## Docs-First Framing

- intended behavior: the public docs are a build target for ZEVM. They must specify the exact startup, configuration, transport, and JSON-RPC contract even where the implementation is incomplete.
- observed repo reality: earlier docs drifted into “conceptual buckets only” wording for startup and config even though the repo already contains concrete defaults and product decisions sufficient to write a real contract.
- authoring rule: if a public surface is meant to exist, the internal docs must name the exact flag, config field, precedence rule, invalid combination, and error behavior. Current `HEAD` gaps are documented separately as implementation contradictions.
- source IDs: `DOCS-01`, `BOOT-01`, `BOOT-02`, `BOOT-03`
