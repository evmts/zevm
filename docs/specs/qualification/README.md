# Release Qualification Assertion Map

`assertion-map.json` is the machine-readable phase-1 release qualification map required by `docs/specs/prd.md` section 3.5.

Each record maps one shipped phase-1 surface to either a default `zig build test` assertion or a release-asset validation assertion. Records with incomplete coverage are not omitted or silently treated as passing; they are marked with `coverageStatus = "gap"` and include an owner ticket.

Run the structural check with:

```sh
zig build qualification-check
```

The default check verifies schema shape, required fields, allowed categories, release-asset rows, and explicit gap metadata. It exits successfully when gaps are explicit so the map can be maintained before the release gate is fully closed.

For a release-candidate gate that must fail while any explicit gaps remain, run:

```sh
zig build qualification-check -- --require-covered
```
