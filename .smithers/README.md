# ZEVM factory and incremental CI

`smthrs ci '//...'` builds and tests ZEVM incrementally. Results cache locally
in `.smithers/cache` and sync through `https://build.smithers.sh` when
`SMITHERS_CACHE_READ_TOKEN` / `SMITHERS_CACHE_WRITE_TOKEN` are set.

- Workspace: `.smithers/WORKSPACE.ts`, the only declaration; smthrs refuses a
  second `.smithers/WORKSPACE.smithers` beside it.
- Targets: root `PACKAGE.ts`, `bench/**/PACKAGE.ts`, `.smithers/PACKAGE.ts`.
- Factory: `.smithers/FACTORY.ts` and `.smithers/flows/**`, projected into the
  checked-in `factory.json` and `home.json`.

## Native dependency keys

`build.zig.zon` resolves `../voltaire` and `../guillotine-mini` by path, outside
the workspace, where Smithers cannot hash them. `tools/native_deps_digest.mjs`
writes their source digest to `.native-deps.digest` (gitignored), and every Zig
target declares that file as an input, so editing a sibling or changing its
checkout invalidates dependent results. `scripts/smthrs` and CI regenerate the
digest before each run; run `node tools/native_deps_digest.mjs` first when
calling `smthrs` directly. Check out the pins with `bash tools/checkout-native.sh`.

Zig targets run with `sandbox: "none"` because they read the siblings and the
host Zig cache. Smithers publishes only confined results, so these results stay
in the local and GitHub Actions caches.

## Targets

| Target | Kind | Runs |
| --- | --- | --- |
| `//:dependency-preflight` | test | `zig build dependency-preflight` |
| `//:build` | build | `zig build` |
| `//:test` | test | `zig build verify-fast` (needs `lib/execution-apis`) |
| `//:c-smoke` | test | `zig build c-smoke` |
| `//:npm-smoke` | test | `zig build npm-smoke` |
| `//:release-binaries` | build | `zig build release-binaries -Doptimize=ReleaseSafe` |
| `//:npm-platform-artifacts` | build | `zig build npm-platform-artifacts -Doptimize=ReleaseSafe` |
| `//:qualification-check` | test | `zig build qualification-check` |
| `//:fmt` | test | `zig fmt --check` |
| `//:js-check` | test | `node --check` on npm and tool scripts |
| `//:docs-mirror` | test | `node tools/docs_mirror.mjs` (Starlight mirror drift check) |
| `//bench/<suite>:bench`, `:test` | build, test | ReleaseFast suite, report vs `bench/baseline.json` |
| `//bench:deps-check` | test | bench PACKAGE.ts source closure check |
| `//.smithers:factory-check` | build, lint | factory projection drift check |
| `//.smithers:factory-write` | build, lint | regenerate projections (`smthrs target //.smithers:factory-write --write`) |

## Commands

```sh
scripts/smthrs ci '//...'
scripts/smthrs ci //:test //:fmt
scripts/smthrs target //.smithers:factory-write --write
scripts/smthrs explain //:build
```
