# Release Qualification Assertion Map

`assertion-map.json` is the machine-readable phase-1 release qualification map required by `docs/specs/prd.md` section 3.5.

Each record maps one shipped phase-1 surface to either a default `zig build test` assertion or a release-asset validation assertion.

## Qualification Gate

Run the release qualification gate locally (same command for CI):

```sh
./scripts/release-qualification/run.sh
```

The gate executes:

```sh
zig build test
zig build qualification-check -- --require-covered
```

It fails when:

- Any shipped surface is unmapped or marked with non-covered status.
- Listener/socket smoke assertions fail in the test graph.
- Transport-path notification-only `204` checks fail.

## Qualification Artifacts

- Assertion map artifact: `docs/specs/qualification/assertion-map.json`
- Release-asset validation rows (for metadata-backed release claims):
  - `RELEASE_METADATA_RELEASE_TUPLE_JSON`
  - `RELEASE_METADATA_LIGHT_DEFAULT_CHECKPOINTS_JSON`
  - `RELEASE_METADATA_REQUIRED_ARTIFACTS_PRESENT_EXACTLY_ONCE`

These rows are validated by `zig build qualification-check` and must remain covered for release-ready qualification.
