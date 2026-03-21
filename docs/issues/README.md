# PRD Gap Issues

This directory tracks the PRD gaps re-verified on 2026-03-19 from code, local build/test attempts, and targeted inspection of the runnable path.

- `001-runnable-dev-node-and-rpc-wiring.md`: The installed binary is still only a generic HTTP transport shell; neither the trusted dev node nor the light client is composed into startup.
- `002-core-eth-read-methods.md`: Core read helpers exist, but they are unwired and several still return placeholder or semantically wrong data.
- `003-eth-call-and-estimate-gas.md`: `eth_call` and `eth_estimateGas` are absent.
- `004-transaction-submission-and-mempool.md`: Tx submission is stale against the current runtime and there is no real mempool or pending-state model.
- `005-mining-modes.md`: Mining helper code exists, but it does not seal canonical blocks or update runtime query state.
- `006-block-transaction-and-log-queries.md`: Query helpers are unwired and still rely on placeholder tx hydration and lossy receipt/log serialization.
- `007-snapshots-and-state-manipulation.md`: Snapshot and mutator helpers are disconnected, stale against sibling APIs, and do not restore full node state.
- `008-forking-impersonation-and-time-controls.md`: Fork mode, impersonation, and time controls are absent from the real runtime.
- `009-debug-tracing-filters-and-subscriptions.md`: Tracing, filter lifecycle, subscriptions, and WebSocket transport are not implemented.
- `010-light-client-mode-and-proof-verified-reads.md`: Consensus-sync libraries exist, but there is no runnable light-client mode or proof-verified execution-read surface.
- `011-build-and-test-coverage.md`: Default build/test signals are red and the default graph still omits material feature coverage.
- `012-block-state-root-and-context-integrity.md`: State-root, storage-root, code-registry, and `BLOCKHASH` integrity are not integrated into canonical block production.
- `013-upstream-api-alignment-and-ownership.md`: ZEVM is still drifting against sibling APIs and carries orphaned local stacks with ambiguous ownership.
- `014-json-rpc-transport-compliance.md`: JSON-RPC batching, notifications, validation, and error semantics are not release-ready even apart from the startup gap.
