# Release Qualification Assertion Map

`assertion-map.json` is the machine-readable phase-1 release qualification map required by `docs/specs/prd.md` section 3.5.

Each record maps one shipped phase-1 surface to either a default `zig build test` assertion or a release-asset validation assertion. Records with incomplete coverage are not omitted or silently treated as passing; they are marked with `coverageStatus = "gap"` and include an owner ticket.

Run the structural check with:

```sh
zig build qualification-check
```

The default check verifies schema shape, required fields, allowed categories, release-asset rows, explicit gap metadata, and covered-row evidence references. Covered rows must point to allowed gate commands, existing repo-relative files, or named Zig tests that exist in those files. It exits successfully when gaps are explicit so the map can be maintained before the release gate is fully closed.

For a release-candidate gate that must fail while any explicit gaps remain, run:

```sh
zig build qualification-check -- --require-covered
```

`qualification-check` validates evidence references; it does not replace the behavioral execution performed by `zig build test`, `zig build verify-fast`, `zig build verify`, or the Hive gates.
