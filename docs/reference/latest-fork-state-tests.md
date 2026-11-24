# Latest-Fork State Tests

`zig build verify-latest-state` runs every Cancun and Prague `GeneralStateTests` post case against ZEVM and reports pass, fail, and unsupported counts per fork and per category.

```bash
zig build verify-latest-state -Doptimize=ReleaseFast
zig build verify-latest-state -Doptimize=ReleaseFast -- --match=stEIP7702 --dump-state-on-mismatch
```

## Fixture source

| Fork | Source | Path |
| --- | --- | --- |
| Cancun | `ethereum/tests` (pinned submodule) | `lib/ethereum-tests/fixtures_general_state_tests.tgz` |
| Prague | `ethereum/tests` (pinned submodule) | `lib/ethereum-tests/fixtures_general_state_tests.tgz` |
| Osaka, Amsterdam | `ethereum/execution-specs` fixture releases | not active yet |

The runner reads the archive in place with `std.tar` and `std.compress.flate`. Nothing is extracted to disk. The curated `zig build verify` slice in `tools/external_verify.zig` still reads the extracted `LegacyTests/Cancun/GeneralStateTests` directories.

`ethereum/tests` stopped adding forks after Prague. `ethereum/execution-spec-tests` was archived on July 2, 2026, and fixture releases moved to [`ethereum/execution-specs`](https://github.com/ethereum/execution-specs/releases). To add Osaka or Amsterdam:

1. Pin the `execution-specs` fixture release archive (`fixtures_stable.tar.gz` or `fixtures_develop.tar.gz`) with a SHA-256 hash.
2. Point `--latest-fork-state-archive=<path>` at it. The archive holds the same state-test JSON shape under `state_tests/`. Map that root in `latestForkStateCategory`.
3. Add the fork to `latest_fork_state_forks` and its floors to the baseline.

## Classification

Each post case in a `Cancun` or `Prague` section gets one result:

| Result | Meaning |
| --- | --- |
| `passed` | The post-state root and logs hash match. For `expectException` cases, ZEVM also rejected the transaction. |
| `failed` | Any other outcome. The run logs `latest-fork-state: FAIL` with the fixture label and error, then continues. |
| `unsupported` | The category is listed in `latest_fork_state_unsupported_categories` with a reason. The report prints every listed category and its reason. |

Post cases for other forks are counted as `other_fork_cases`.

The category is the directory below `GeneralStateTests/`, for example `stCreate2` or `Cancun/stEIP4844-blobtransactions`.

For `expectException` cases, exception names that map to a ZEVM `TxError` must match that error exactly. Unmapped names, such as EEST `TransactionException.*` names, accept any rejection. The state-root check still applies.

## Baseline

`tools/latest_fork_state_baseline.json` holds the minimum `passed` count for each fork and category. A full run fails with `LatestForkStateRegression` when a category falls below its floor or disappears. Runs filtered with `--match` or `--shard` skip the check.

When a fix raises a pass count, raise the floor in the same change. The baseline records the current pass level. It is not a claim that the suite fully passes. The `failed` count in the report is the remaining work.

## Current results

Pinned `ethereum/tests` `c67e485f`, ZEVM ReleaseFast, about 6 minutes on 4 vCPUs:

```
fork     passed   failed   unsupported   total
Cancun   19527    205      0             19732
Prague   17767    225      0             17992
```

Failures by cluster. Each needs its own EVM fix:

| Cluster | Failed (Cancun + Prague) | Symptom |
| --- | --- | --- |
| `stSStoreTest/sstore_*`, `InitCollisionParis` | 286 | State root mismatch on SSTORE refund and storage collision paths |
| `stPreCompiledContracts`, `stPreCompiledContracts2`, `stStaticCall` | 74 | State root mismatch on precompile calls, including ecrecover through STATICCALL; 22 are Prague-only |
| `stCreateTest`, `stCreate2` OOG-after-initcode and collision cases | 30 | State root mismatch |
| `Cancun/stEIP4844-blobtransactions` | 11 | `tx_processor` accepts blob transactions the fixture rejects: empty hash list, wrong version byte, contract creation, too many blobs |
| `stStaticFlagEnabled`, other single cases | 29 | State root mismatch |

Run one cluster with `-- --match=<fixture path fragment> --dump-state-on-mismatch`.

## CI

The `Official External Verification` job runs `zig build verify-latest-state -Doptimize=ReleaseFast` after `zig build verify`. It runs on tag pushes, manual dispatches, and the weekly schedule.
