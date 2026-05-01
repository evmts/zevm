# Release Qualification Assertion Map

`assertion-map.json` is the machine-readable phase-1 release qualification map required by `docs/specs/prd.md` section 3.5.

Each record maps one shipped phase-1 surface to either a default `zig build test` assertion or a release-asset validation assertion. Default-graph coverage means executable tests wired into `src/root.zig` (including `src/rpc/listener_smoke_test.zig`) currently assert the behavior. Release qualification means the assertion map itself is structurally valid release evidence. External official verification is a separate `zig build verify` step that runs active upstream suite slices.

Records with incomplete coverage are not omitted or silently treated as passing; they are marked with `coverageStatus = "gap"` and include an owner ticket.

Run the structural check with:

```sh
zig build qualification-check
```

The default check verifies schema shape, required fields, allowed categories, release-asset rows, and explicit gap metadata. It exits successfully when gaps are explicit so the map can be maintained before the release gate is fully closed.

For a release-candidate gate that must fail while any explicit gaps remain, run:

```sh
zig build qualification-check -- --fail-on-gap
```

`--require-covered` remains supported as an alias. Covered rows must not use `TODO:` assertion identifiers; the checker rejects stale placeholders to keep the map aligned with executable truth.
