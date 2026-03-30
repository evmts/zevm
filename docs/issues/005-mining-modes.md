# Mining Modes

> **Archived / non-normative:** This issue is historical context only. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md).


## Verified Gap

- `MiningCoordinator` is standalone helper code; nothing in startup or `NodeRuntime` owns it.
- There is no exposed `evm_mine`, `hardhat_mine`, `evm_setAutomine`, or interval-mining control surface.
- The helper mining path never inserts a sealed block into `Blockchain` and never updates receipt/log indexes.
- `MiningCoordinator` block context drifts from ZEVM's intended dev-node defaults: chain ID `1`, synthetic coinbase, and zero `base_fee`, `blob_base_fee`, and `prevrandao`.
- `MiningCoordinator.mineBlock` returns a `BlockResult` and also stores the same owning value in `mined_blocks`, which is a double-ownership hazard.

## Evidence

- `src/mining_coordinator.zig`
- `src/mining.zig`
- `src/block_builder.zig`
- `src/node/runtime.zig`
- `src/receipt_index.zig`
- `src/log_index.zig`

## Resolution Verification

- Automine, manual mining, and interval mining are exposed over RPC and owned by the main runtime.
- Mined blocks are inserted into `Blockchain` and become queryable immediately.
- Receipt/log indexes update with every sealed block.
- Block context fields (`coinbase`, gas limit, timestamp, base fee, blob base fee, `prevrandao`, recent block hashes) are correct across mode changes.
- Multi-block mining, empty-block mining, and ownership/lifetime of mined results are covered by end-to-end tests.
