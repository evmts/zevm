---
title: Fusaka & Osaka Hardfork Implementation
tags: [osaka, fusaka, prague, eips, consensus]
---

# Fusaka & Osaka Hardfork Implementation

Part of [[Execution-Engine]] and verified by [[Formal-Verification-and-Fuzzing]].

ZEVM ships full Prague and Osaka/Fusaka protocol support across execution, genesis initialization, blob fee markets, and JSON-RPC introspection:

| EIP | Feature | Primary Modules |
| --- | --- | --- |
| EIP-4788 / 2935 / 7002 / 7251 | Prague/Osaka genesis system contracts & `requests_hash` | `src/system_contracts.zig`, `src/genesis_alloc.zig`, `src/block_builder.zig` |
| EIP-7594 | PeerDAS v1 blob data parameters | `src/blob_fee.zig`, `src/blob_kzg.zig`, `src/hardfork_schedule.zig` |
| EIP-7623 | Calldata floor gas metering | `src/tx_processor.zig` |
| EIP-7702 | Set-code authorization-list transactions | `src/transaction_encoding.zig`, `src/tx_processor.zig` |
| EIP-7825 | Per-transaction gas limit cap | `src/tx_processor.zig`, `src/block_builder.zig` |
| EIP-7892 | Blob Parameter Only (BPO) schedule | `src/hardfork_schedule.zig`, `src/blob_fee.zig` |
| EIP-7910 | `eth_config` fork configuration RPC | `src/rpc/handlers/eth_config.zig` |
| EIP-7918 | Blob base fee reserve bounded by execution cost | `src/blob_fee.zig` |
| EIP-7934 | RLP execution block size limit | `src/block_builder.zig` |
| EIP-7951 | `P256VERIFY` precompile (`0x100`) | `src/precompile_compat.zig`, `src/system_contracts_test.zig` |

## Genesis System Contract Guarantee

Every node-owned local/dev genesis deploys canonical EIP-4788, EIP-2935, EIP-7002, and EIP-7251 bytecode (nonce 1, empty storage) so mining Prague and Osaka blocks works out of the box while explicit `--genesis` files and forked chains preserve exact external state.
