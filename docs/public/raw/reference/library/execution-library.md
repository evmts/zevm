The root ZEVM module exports transaction processing, block building, consensus verification, chain import, MPT proofs, and mining configuration. Reach for it when building a Zig application that needs execution primitives without starting the JSON-RPC server.

## Working example

This program exercises the rc.151-equivalent source rules for intrinsic gas and the London refund cap.

```zig
const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    const intrinsic = zevm.tx_processor.intrinsicGas(&.{ 0x00, 0xff }, false);
    const billed = zevm.tx_processor.effectiveGasUsed(100_000, 0, 60_000, .CANCUN);

    if (intrinsic != 21_020) return error.WrongIntrinsicGas;
    if (billed != 80_000) return error.WrongRefundCap;

    std.debug.print("intrinsic_gas={d}\nbilled_gas={d}\n", .{ intrinsic, billed });
}
```

```bash
zig build run-execution
```

```text
intrinsic_gas=21020
billed_gas=80000
```

## Modules

The export list is defined in [`src/root.zig`](https://github.com/evmts/zevm/blob/main/src/root.zig).

| Module | Primary public surface |
| --- | --- |
| `tx_processor` | `ExecutionTx`, `ProcessTransactionOptions`, `intrinsicGas`, `effectiveGasUsed`, `processTransaction`, `processTransactionWithOptions` |
| `block_builder` | `BuildBlockOptions`, `BlockResult`, `buildBlock`, `buildBlockWithOptions`, `validateBlock`, root and reward helpers |
| `consensus_verifier` | Bootstrap and update verification, signing roots, committee selection, light-client store updates |
| `chain_import` | `ImportStats`, `importChainFile`, `importChainBytes`, `decodeNextBlock` |
| `mpt_proof` | `Proof`, `secureProof` |
| `mining` | `MiningConfigType`, `MiningConfig` |

Execution APIs mutate the supplied state manager. Result types that expose `deinit` transfer owned allocations to the caller.

## Neighbours

[Database](./database) · [Genesis and chain import](./genesis-and-chain-import) · [Runtime modes](../../concepts/runtime-modes)
