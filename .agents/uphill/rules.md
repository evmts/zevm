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

## Ethereum Conformance

Pinned Voltaire and Guillotine Mini provenance, release qualification coverage, Cancun/Prague GeneralStateTests floors, and npm release version parity.

- Keep native-dependencies.json pinned to pushed 40-hex commit SHAs for evmts/voltaire and evmts/guillotine-mini.
- Keep every release qualification assertion in docs/specs/qualification/assertion-map.json covered. At least 100.
- Raise the Cancun GeneralStateTests pass floor in tools/latest_fork_state_baseline.json toward 100%. At least 100.
- Raise the Prague GeneralStateTests pass floor in tools/latest_fork_state_baseline.json toward 100%. At least 100.
- Keep package versions, platform optionalDependencies, build.zig.zon, and native ZEVM_VERSION aligned (npm run verify:release).

## Smithers Factory & Trust

Coding factory projection, 3-audience personalized home, shared cache trust isolation, Obsidian wiki, llms.txt index, and one-time sandbox auth.

- Declare Smithers Cloud repository workflow triggers in .smithers/FACTORY.ts so factory.json emits apiVersion 1 and contributes.triggers.
- Enforce policy.approvals approve=person and merge=person in .smithers/FACTORY.ts.
- Protect consensus, ABI, native pins, build, and factory paths in github.protectedPaths.
- Declare maintainer, contributor, and everyone sections in .smithers/HOME.mjs (projected to .smithers/home.json) without markdown blocks so smithers.sh renders pre-clone.
- Declare docs pointing to https://zevm.sh/docs/llms.txt in .smithers/HOME.mjs.
- Isolate untrusted PR execution from trunk cache writes using split SMITHERS_CACHE_READ_TOKEN and main-only SMITHERS_CACHE_WRITE_TOKEN.
- Keep .smithers/wiki/ wikilinks, frontmatter, mythical history, and code citations valid (node tools/wiki_sync.mjs --check).
- Keep docs/public/llms.txt synchronized with docs/ (node tools/generate_llms_txt.mjs --check).
- Maintain .smithers/merge.json and tools/sandbox_auth.mjs for one-time-use sandbox agent authentication.
