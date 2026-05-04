---
title: "Submodule Update Policy"
---

# Submodule Update Policy

Last updated: 2026-05-01

## Classification

Normative submodules (official test/spec confidence inputs):
- `hive`
- `execution-apis`
- `execution-specs`
- `execution-spec-tests`
- `ethereum-tests`

Reference-only submodules (vendor comparison and ecosystem context):
- `foundry`
- `hardhat`
- `edr`
- `consensus-specs`
- `EIPs`
- `yellowpaper`

## Cadence And Gating

- Normative submodules should be refreshed intentionally at least weekly and before release confidence snapshots.
- Reference-only submodules should be updated only for explicit compatibility review goals.
- Every meaningful normative update batch must run:
  - `git submodule status --recursive`
  - `zig build verify-fast`
  - `zig build verify`
- Any introduced fixture/spec failure must get an owner ticket with a concrete reproduction command.

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
