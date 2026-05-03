# ZEVM Internal Support: Trusted Mode Semantics

This page supports the normative trusted-mode contract in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

## 1. Runtime Role

Trusted mode is the writable local dev-node runtime.

It provides:

- local execution and state mutation
- optional RPC fork backing with local-first overlay behavior
- transaction submission and mining
- snapshots/revert, impersonation, and time controls

## 2. Defaults

Trusted defaults:

- `chainId`: `31337` (`0x7a69`)
- deterministic 10-account managed set
- `coinbaseIndex`: `0`
- `initialBalance`: `10000 ETH` per managed account
- `gasPrice`: `2000000000`
- `baseFee`: `1000000000`
- `blobBaseFee`: `1`
- `maxPriorityFeePerGas`: `1000000000`
- `blockGasLimit`: `30000000`
- mining mode: `auto`
- hardfork policy: explicit dev schedule with Cancun active from genesis and Prague/Osaka inactive until configured
- genesis allocation: absent; default startup pre-funds the deterministic managed accounts

The exact account/address/private-key table is part of the product contract and is defined in `docs/specs/prd.md`, then reflected by RPC behavior (`eth_accounts`, signing scope).

If trusted startup supplies a genesis JSON file, ZEVM imports the file's top-level `alloc` object into the local state before computing the genesis state root. Alloc entries support `balance` or legacy `wei`, plus optional `nonce`, `code`, and `storage`. This replaces default dev-account pre-funding, but the deterministic managed accounts remain the signing scope.

If trusted startup supplies a chain RLP stream, ZEVM imports each encoded block after genesis initialization as query-only block history and advances the canonical head to the last imported block. Imported block bodies retain raw transaction envelopes for block transaction arrays and transaction-by-block/index reads.

Phase-1 chain RLP import does not execute imported transactions, validate post-state roots, materialize account/storage state, or populate receipt/log indexes. State-backed reads, simulation, receipts, and logs remain bound to genesis plus subsequent local execution. Startup logs must identify this path as query-only.

If trusted startup enables `engineRpc`, ZEVM binds a second plain-HTTP Engine API listener. The implemented Engine surface is intentionally narrow: capability exchange, transition configuration exchange, and forkchoice updates that validate referenced hashes against local block history. Full Engine payload execution/building and blob/body retrieval are not release-ready.

## 3. Fee Model And Tx Types

Phase-1 trusted submission supports only legacy tx type `0x0`.

Transaction admission, simulation, mining, and block persistence use the same runtime-owned hardfork policy. `chainId = 1` defaults to the mainnet activation schedule; non-mainnet trusted defaults use the dev Cancun schedule unless `mode.trusted.hardfork` overrides activation fields.

For `TransactionRequest`:

- accepted fee field: `gasPrice`
- unsupported fee/type fields fail with `-32602` (`maxFeePerGas`, `maxPriorityFeePerGas`, `maxFeePerBlobGas`, `blobVersionedHashes`, `accessList`, `authorizationList`, `type`, `chainId`)

For `eth_sendRawTransaction`:

- accepted envelope: legacy only
- typed EIP-2718 envelopes are unsupported (`-32602`)

## 4. Mining Semantics

Mining modes are exact:

- `auto`: tx submission of an executable tx triggers immediate single-block mining pass; no timer empty blocks
- `manual`: no background mining; mine only on explicit mine RPC
- `interval`: periodic mining every configured `blockTime`; empty blocks are allowed

The trusted runtime owns the interval timer. It starts from startup interval config or interval-mining RPC controls, and it stops when mining mode switches to auto/manual or the runtime shuts down.

Shared invariants:

- block timestamps strictly increase
- explicit multi-block mining advances timestamp per block
- inclusion ordering is nonce-aware and gas-limit bounded

Detailed trigger and timestamp precedence rules are normative in `docs/specs/json-rpc-contract.md`.

## 5. Trusted Method Surface

Trusted-mode standard methods include:

- core reads (`eth_chainId`, `eth_blockNumber`, account/state reads, fee reads, `eth_feeHistory`)
- simulation (`eth_call`, `eth_estimateGas`)
- submission (`eth_sendTransaction`, `eth_sendRawTransaction`)
- queries (`eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getBlockTransactionCountByHash`, `eth_getBlockTransactionCountByNumber`, `eth_getTransactionByHash`, `eth_getTransactionByBlockHashAndIndex`, `eth_getTransactionByBlockNumberAndIndex`, `eth_getTransactionReceipt`, `eth_getBlockReceipts`, `eth_getLogs`)
- phase-1 transaction/receipt/log payloads exclude nonstandard `blockTimestamp` extension fields

Trusted nonstandard controls are canonical `zevm_*` methods with exact accepted aliases listed in `docs/specs/json-rpc-contract.md`.

Phase-1 light-mode boundary for simulation:

- `eth_call` and `eth_estimateGas` remain trusted-only and return `-32010` in light mode
- `eth_call` is a deferred light-mode proof-backed target

## 6. Selector Semantics

Trusted selectors:

- `latest`: local canonical head
- `pending`, `safe`, `finalized`: aliases of `latest`
- `earliest`: block `0`
- numeric: exact local block

Trusted `pending`/`safe`/`finalized` are compatibility aliases, not consensus finality.
