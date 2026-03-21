# Transaction Submission And Mempool

## Verified Gap

- `eth_sendTransaction` / `eth_sendRawTransaction` are not on the runnable product path.
- `src/rpc/handlers/tx_submission.zig` is stale against `NodeRuntime`: it expects `rt.pool`, `rt.mining_mode`, and `NodeRuntime.lookupManagedAccount`, none of which exist.
- There is no mempool or txpool module under `src/`; future-nonce queueing, replacement rules, and pending-state ownership are not implemented.
- Accepted txs would lose their real payload before mining: the handler stores only reduced metadata and `automine()` reconstructs synthetic legacy txs with `to = null`, `value = 0`, and empty `data`.
- `automine()` never executes transactions or builds receipts; it only increments `head_block_number` and removes hashes from the pool.
- Typed raw transactions can be admitted by decode helpers, but execution is still legacy-only end-to-end.
- `src/rpc/handlers/tx_submission_test.zig` is both omitted from the default graph and stale against the current runtime API.

## Evidence

- `src/main.zig`
- `src/rpc/handlers/tx_submission.zig`
- `src/rpc/handlers/tx_submission_test.zig`
- `src/node/runtime.zig`
- `src/tx_processor.zig`
- `src/mining_coordinator.zig`

## Resolution Verification

- `eth_sendRawTransaction` accepts valid envelopes and rejects malformed hex/RLP, chain-ID mismatches, bad signatures, nonce errors, and balance/intrinsic-gas failures deterministically.
- `eth_sendTransaction` signs for managed dev accounts and preserves submitted semantics.
- Pending transactions retain full original payloads and are mined without lossy reconstruction.
- Future-nonce queueing and replacement rules are implemented and tested.
- Legacy and typed transactions have explicit support or deterministic rejection.
- Accepted txs only leave the pool after real block production with matching receipt/hash/state transitions.
