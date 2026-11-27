# Rules

Uphill writes these rules from each metric's `description`. Write code that meets them. `uphill` scores each metric against its target, and `uphill --compare HEAD --compact` lists what a change made worse.

## Safety & TigerStyle

Execution-client crash freedom, explicit error handling, and assertion density across Zig and npm JS wrappers.

- Never use @panic or unreachable in production src/**/*.zig; validate inputs and return typed errors.
- Replace std.debug.print in production src/**/*.zig modules with structured logging via src/log.zig.
- Never swallow errors with empty catch {} or leave error.NotImplemented stubs in production src/**/*.zig.
- Add invariant assertions to production Zig execution, RPC, and consensus paths toward TigerStyle density. At least 20.
- Keep every JavaScript file under npm/zevm/src/ syntactically valid under `node --check`.

## Style & Limits

CLAUDE.md Zig style rules, TigerStyle structural bounds (70-line functions, 120-char lines), and canonical formatting.

- Keep every Zig file under src/ formatted with `zig fmt`.
- Follow CLAUDE.md Zig style: use fully qualified imported symbol paths inline instead of private top-level `const Foo = bar.Foo` aliases.
- Keep every production Zig runtime function at or below 70 lines (TigerStyle limit); decompose large RPC/block handlers. At most 70.
- Keep production Zig lines at or below 120 characters (TigerStyle limit).
- Resolve TODO, FIXME, XXX, and HACK markers in production src/**/*.zig instead of leaving deferred work.

## Footprint & Modularity

Source file and subsystem modularity limits to keep the execution client auditable.

- Keep production Zig files focused and under 500 lines; split monolithic modules like src/block_builder.zig and src/rpc/. At most 500.
- Keep each src/ subsystem modular and well-bounded in source footprint. At most 80 kB.

## Verification & Fuzzing

Native Zig fuzz targets, Lean 4 consensus/execution proofs, and module test coverage.

- Close every `sorry` and unproved `axiom` in spec/lean/**/*.lean formal proofs.
- Expand Lean 4 theorem and lemma coverage in spec/lean/ for block validation, consensus, and state transitions. At least 60.
- Expand native `std.testing.fuzz` target coverage across RPC, Engine API, consensus, MPT, and C ABI boundaries. At least 50.
- Ensure every production src/**/*.zig module has inline `test` blocks or a dedicated sibling `*_test.zig`. At least 100.

## Documentation

Astro/Starlight docs mirror parity (`tools/docs_mirror.mjs`) and markdown link integrity.

- Keep docs/ and docs/src/content/docs/ synchronized by running `node tools/docs_mirror.mjs --write` after editing docs.
- Fix broken local paths and machine-specific links in root Markdown files and docs/.
