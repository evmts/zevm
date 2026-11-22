---
title: "Submodule Update Policy"
---

# Submodule Update Policy

Last updated 2026-11-22

## Classification

| Submodule | Role and update policy |
| --- | --- |
| `hive`, `execution-apis`, `ethereum-tests` | Active inputs to `zig build verify`. Keep pinned and refresh with the verification gates below. |
| `execution-specs` | Current upstream for execution specs and EEST fixture releases. Use it as the source for future fixture updates. |
| `execution-spec-tests` | Archived July 2, 2026. Keep the existing pin while `tools/external_verify.zig` reads state, blockchain, and negative fixtures from `lib/execution-spec-tests`. |
| `foundry` | Reference only. It can be dropped from the build checkout. Preserve links to the pinned upstream files cited by `REVIEWS.md` when removing the submodule. |
| `consensus-specs`, `EIPs`, `yellowpaper` | Reference material. Refresh when a review needs a newer revision. |

EEST development moved to [`ethereum/execution-specs`](https://github.com/ethereum/execution-specs), which publishes the [current fixture releases](https://github.com/ethereum/execution-specs/releases). To retire the archived pin, migrate the verifier to fixtures from that upstream, confirm equivalent coverage with `zig build verify`, and then remove the old submodule entry and pin. See the [upstream archive notice](https://github.com/ethereum/execution-spec-tests).

## Cadence And Gating

- Review active upstream pins weekly and before release confidence snapshots.
- For each verification input update, review the pinned revisions with `jj debug tree lib`, then run `zig build verify-fast` and `zig build verify`.
- File an issue with a reproduction command for any new fixture or spec failure.

## 2026-04-30 Refresh Record

Normative submodule pointer changes:
- `hive`: `6a6476e9` -> `c37a9a26` (`origin/master`)
- `execution-apis`: `56449267` -> `e263bc91` (`origin/main`)
- `execution-specs`: `01c5e904` -> `9d187336` (`origin/forks/amsterdam`, remote default branch)
- `execution-spec-tests`: unchanged (`88e9fb8f`, already current vs `origin/main`)
- `ethereum-tests`: unchanged (`c67e485f`, already current vs `origin/develop`)

Reference-only submodules were intentionally left pinned.

Verification result for this refresh batch:
- `zig build verify-fast`: pass
- `zig build verify`: pass
- External verifier summary after MODEXP quarantine removal: `discovered=18186 selected=18186 completed=18186 quarantined=0 failed=0`
- Active legacy state-test expansion since the refresh: `stShift`; `stPreCompiledContracts/modexpTests.json`
- Quarantined fixtures: 0
- Attempted but not yet active: `stExtCodeHash/dynamicAccountOverwriteEmpty.json` has a Cancun state-root mismatch; `stCreate2/CREATE2_FirstByte_loop.json` has Cancun/Shanghai state-root mismatches
- Failed fixtures: 0
