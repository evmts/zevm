# zevm — Cross-spec Review Report

All 5 smithers review workflows on full default chunks, codex (gpt-5.3-codex) only.

## Review: EIPs

_chunks=14 avgConform=40 avgCov=14 issues=64 crit=12_

# EIPs Spec Review

## Executive Summary
- Chunks reviewed: 14
- Average conformance: 40 / 100
- Average test coverage: 14 / 100
- Total issues: 64
- Severity counts: 12 critical, 38 major, 14 minor, 0 nit
- Overall: conformance is low-to-moderate and dominated by missing typed-transaction execution, missing fork-aware runtime wiring, and missing fixture-driven compliance coverage.

## Top Risks
- [critical] EIP-1559 fee accounting is legacy-only, with no burn/tip split or effective-gas-price semantics (`src/tx_processor.zig:120`).
- [critical] EIP-2930 type-1 execution is missing end-to-end, including access-list intrinsic gas and pre-warming (`src/tx_processor.zig:10`, `src/tx_processor.zig:24`, `src/tx_processor.zig:144`).
- [critical] EIP-3860 create-tx rules are missing: no initcode word metering and no MAX_INITCODE_SIZE rejection (`src/tx_processor.zig:25`, `src/tx_processor.zig:116`).
- [critical] EIP-4844 core Cancun behavior is missing: no type-3 execution, no blob fee accounting/validation, and dropped blob semantics in submission/automine (`src/tx_processor.zig:10`, `src/rpc/handlers/tx_submission.zig:47`, `src/mining_coordinator.zig:74`).
- [critical] EIP-4895 withdrawals are not processed in block execution, and withdrawals-root validity is not enforced (`src/block_builder.zig:28`, `src/consensus_verifier.zig:405`).
- [critical] EIP-7702 type-4 authorization processing is absent in execution (`src/tx_processor.zig:10`, `src/tx_processor.zig:103`).
- [major] Mining context hardcodes base-fee and prevrandao to zero, breaking EIP-3198/EIP-4399 runtime semantics (`src/mining_coordinator.zig:82`, `src/mining_coordinator.zig:74`).
- [major] Fork activation is mostly implicit (`hardfork = null`), creating brittle activation for 3529/3855/5656/6780-era behavior (`src/tx_processor.zig:139`).
- [major] Repeated missing external runner path blocks fixture-backed proof (`tests/external/state_tests_runner.zig`).

## Foreign Feature Gaps
- EDR has next-base-fee computation and strict EIP-1559 fee validation/miner-tip logic; zevm does not (`lib/edr/crates/block/header/src/lib.rs`, `lib/edr/crates/block/miner/src/lib.rs`, `lib/edr/crates/edr_provider/src/requests/validation.rs`).
- EDR validates pooled EIP-4844 sidecars (vector counts, versioned-hash mapping, batch KZG verification); equivalent zevm path not found (`lib/edr/crates/edr_transaction/src/pooled/eip4844.rs`).
- EDR wires dynamic `eth_blobBaseFee` from blob-fee progression while zevm returns runtime field directly (`lib/edr/crates/edr_provider/src/provider.rs`, `lib/edr/crates/edr_provider/src/requests/eth/config.rs`, `src/rpc/handlers/eth_read.zig:117`).
- Foundry maps blob fields into tx/block env for simulation; zevm does not preserve blob fields through tx processing/mining (`lib/foundry/crates/evm/core/src/utils.rs`, `lib/foundry/crates/evm/core/src/backend/mod.rs`).
- EDR includes EIP-4844 integration tests for blob gas evolution and `BLOBHASH`; comparable zevm integration coverage is absent (`lib/edr/crates/edr_provider/tests/integration/eip4844.rs`).
- Foundry/EDR include EIP-7702 authorization-aware execution entrypoints, request wiring, validation, and RPC serialization; zevm does not (`lib/foundry/crates/evm/evm/src/executors/mod.rs`, `lib/foundry/crates/evm/core/src/utils.rs`, `lib/edr/crates/edr_provider/src/requests/validation.rs`, `lib/edr/crates/edr_chain_l1/src/rpc/transaction.rs`, `lib/edr/crates/edr_provider/tests/integration/eip7702.rs`).
- Hardhat v-next includes blob transaction request schema support not mirrored by zevm hydrated tx behavior (`lib/hardhat/v-next/hardhat-zod-utils/src/rpc/types/tx-request.ts`).

## Per-Chunk Findings

### EIP-1559 (eip-1559)
- Conformance: 18
- Test coverage: 12
- Summary: partial surface-level artifacts only; core 1559 execution/mining semantics are missing.
- Issues:
  - [critical/conformance] Legacy-only fee accounting; no burn/tip split or effective gas price (`src/tx_processor.zig:120`).
  - [major/conformance] No type-2 execution path (`src/tx_processor.zig:10`).
  - [major/conformance] Base-fee progression algorithm missing in mining (`src/mining_coordinator.zig:74`).
  - [major/conformance] GASPRICE effective-gas-price wiring missing (`src/tx_processor.zig:137`).
  - [major/test-coverage] Test graph does not cover EIP-1559 behavior (`src/root.zig:14`).
  - [minor/missing-feature] `eth_feeHistory` is placeholder-level (`src/rpc/handlers/eth_read.zig:125`).

### Awaiting User Direction (eip-2929)
- Conformance: 0
- Test coverage: 0
- Summary: paused.
- Issues:
  - [minor/conformance] Unexpected workspace mutation detected (`.claude/scheduled_tasks.lock`).

### Optional access lists (eip-2930)
- Conformance: 3
- Test coverage: 1
- Summary: effectively not implemented in execution path.
- Issues:
  - [critical/conformance] Execution pipeline is legacy-only (`src/tx_processor.zig:10`).
  - [critical/conformance] Intrinsic gas omits access-list charges (`src/tx_processor.zig:24`).
  - [critical/conformance] No access-list pre-warming before execution (`src/tx_processor.zig:144`).
  - [major/conformance] Type-1 signing/hash semantics missing (`src/tx_processor.zig:86`).
  - [major/conformance] RPC submission helpers omit `.eip2930` (`src/rpc/handlers/tx_submission.zig:276`).
  - [minor/conformance] Block tx mapping hardcodes legacy type (`src/rpc/handlers/block_query_handlers.zig:182`).
  - [major/test-coverage] EIP-2930 paths are not in active test harness (`src/root.zig:14`).
  - [major/test-coverage] External state-test runner path is missing (`tests/external/state_tests_runner.zig`).

### BASEFEE opcode (eip-3198)
- Conformance: 55
- Test coverage: 20
- Summary: delegated opcode support exists, but zevm mining feeds zero base fee.
- Issues:
  - [major/conformance] Mining path hardcodes `block_base_fee = 0` (`src/mining_coordinator.zig:82`).
  - [major/test-coverage] No zevm test proving EIP-3198 behavior (`src/tx_processor_test.zig:29`).
  - [major/test-coverage] External runner path missing (`tests/external/state_tests_runner.zig`).
  - [minor/test-coverage] Baseline test run is red (`src/tx_processor_test.zig:79`).

### EIP-3529: Reduction in refunds (eip-3529)
- Conformance: 72
- Test coverage: 24
- Summary: London refund behavior present in dependency, but zevm activation is not fork-gated and tests are thin.
- Issues:
  - [major/conformance] EIP-3529 behavior applied unconditionally, not via fork activation (`src/tx_processor.zig`).
  - [major/test-coverage] No zevm-local tests prove refund semantics (`tests/external/state_tests_runner.zig`).
  - [minor/test-coverage] Baseline suite has failures (`src/tx_processor_test.zig`).

### EIP-3651 Warm COINBASE (eip-3651)
- Conformance: 84
- Test coverage: 22
- Summary: delegated implementation appears correct, but zevm-hosted proof is missing.
- Issues:
  - [major/test-coverage] No zevm-hosted EIP-3651 regression harness (`tests/external/state_tests_runner.zig`).
  - [minor/conformance] Warm/cold gating uses `self.hardfork` directly in dependency (`../guillotine-mini/src/evm.zig:441`).
  - [minor/test-coverage] Missing explicit Shanghai vs pre-Shanghai coinbase assertions (`src/tx_processor_test.zig`).

### EIP-3855 PUSH0 instruction (eip-3855)
- Conformance: 84
- Test coverage: 25
- Summary: delegated PUSH0 semantics look correct; zevm-level activation wiring/tests are missing.
- Issues:
  - [minor/conformance] Hardfork selection not plumbed in zevm tx execution (`src/tx_processor.zig:139`).
  - [major/test-coverage] No zevm-owned PUSH0 tests + missing external runner (`src/root.zig:14`, `tests/external/state_tests_runner.zig`).

### EIP-3860: Limit and meter initcode (eip-3860)
- Conformance: 35
- Test coverage: 10
- Summary: create-transaction rules are non-conformant.
- Issues:
  - [critical/conformance] Missing create-tx initcode word intrinsic charge (`src/tx_processor.zig:25`).
  - [critical/conformance] Missing MAX_INITCODE_SIZE invalidity check (`src/tx_processor.zig:116`).
  - [major/conformance] RPC admission inherits non-3860 intrinsic logic (`src/rpc/handlers/tx_submission.zig:58`).
  - [major/test-coverage] No unit tests for EIP-3860 boundaries (`src/tx_processor_test.zig:43`).
  - [major/test-coverage] No end-to-end CREATE/CREATE2 EIP-3860 assertions.

### EIP-4399: Supplant DIFFICULTY Opcode with PREVRANDAO (eip-4399)
- Conformance: 42
- Test coverage: 18
- Summary: delegated opcode behavior exists, but zevm context/sealing paths are incomplete.
- Issues:
  - [major/conformance] PREVRANDAO hardcoded to zero in post-Merge context (`src/mining_coordinator.zig:74`).
  - [major/conformance] No block-sealing path sets header mixHash/prevRandao (`src/block_builder.zig:24`).
  - [minor/conformance] Transition-block gating not represented in zevm tx path (`src/tx_processor.zig:139`).
  - [major/test-coverage] No direct test validates opcode `0x44` semantics (`src/tx_processor_test.zig:29`).
  - [major/test-coverage] Missing external runner coverage (`tests/external/state_tests_runner.zig`).

### EIP-4844 (eip-4844)
- Conformance: 18
- Test coverage: 12
- Summary: plumbing-only support; core Cancun execution behavior missing.
- Issues:
  - [critical/conformance] Execution is legacy-only, not type-3 aware (`src/tx_processor.zig:10`).
  - [critical/conformance] Raw submission path drops blob semantics (`src/rpc/handlers/tx_submission.zig:47`).
  - [critical/conformance] Blob fee market and validity checks missing (`src/mining_coordinator.zig:74`).
  - [major/missing-feature] `BLOBHASH` opcode and point-evaluation precompile behavior absent in zevm `src/`.
  - [major/conformance] Hydrated RPC tx responses are placeholders and force legacy type (`src/rpc/block_queries.zig:229`).
  - [major/test-coverage] External state-test runner missing (`tests/external/state_tests_runner.zig`).
  - [major/test-coverage] Existing tests do not prove EIP-4844 semantics (`src/tx_processor_test.zig:8`).
  - [minor/conformance] `eth_blobBaseFee` appears static (`src/rpc/handlers/eth_read.zig:117`).

### Beacon chain push withdrawals as operations (eip-4895)
- Conformance: 12
- Test coverage: 5
- Summary: withdrawals_root appears in plumbing, but withdrawal state-transition behavior is missing.
- Issues:
  - [critical/conformance] No withdrawal processing in block execution path (`src/block_builder.zig:28`).
  - [major/conformance] No withdrawals-root validation against withdrawals list (`src/consensus_verifier.zig:405`).
  - [major/conformance] No explicit fork-activation logic for 4895 timestamp (`src/mining_coordinator.zig:74`).
  - [major/test-coverage] EIP-4895 coverage absent and external runner path missing (`tests/external/state_tests_runner.zig`).

### MCOPY - Memory copying instruction (eip-5656)
- Conformance: 68
- Test coverage: 22
- Summary: delegated MCOPY exists, but activation wiring and test proof are incomplete.
- Issues:
  - [major/conformance] MCOPY activation not block/fork-driven in zevm runtime (`src/tx_processor.zig:139`).
  - [minor/conformance] Non-spec 16MB memory cap in dependency (`../guillotine-mini/src/frame.zig:246`).
  - [major/test-coverage] MCOPY unit tests use incorrect stack push order (`../guillotine-mini/src/instructions/handlers_memory_test.zig:758`).
  - [major/test-coverage] MCOPY execution-spec target runs zero tests (`../guillotine-mini/scripts/generate_spec_tests.py:123`).
  - [minor/test-coverage] Requested zevm state-test runner path absent (`tests/external/state_tests_runner.zig`).

### SELFDESTRUCT only in same transaction (eip-6780)
- Conformance: 60
- Test coverage: 18
- Summary: delegated handler includes expected branches, but zevm control/proof is weak.
- Issues:
  - [major/conformance] Hardfork selection is implicit and not controlled by zevm (`src/tx_processor.zig:139`).
  - [major/test-coverage] Referenced external runner path missing (`tests/external/state_tests_runner.zig`).
  - [major/test-coverage] No zevm-native tests for EIP-6780 semantics (`src/tx_processor_test.zig`).
  - [minor/test-coverage] Current tx-processor test failures reduce confidence (`src/tx_processor_test.zig:79`).

### Set Code for EOAs (eip-7702)
- Conformance: 12
- Test coverage: 3
- Summary: EIP-7702 execution semantics are not implemented.
- Issues:
  - [critical/conformance] Execution pipeline only supports legacy tx (`src/tx_processor.zig:10`).
  - [critical/conformance] Authorization-list algorithm is missing (`src/tx_processor.zig:103`).
  - [major/conformance] Automine path drops typed/auth semantics (`src/rpc/handlers/tx_submission.zig:237`).
  - [major/missing-feature] RPC transaction surfaces are not type-4 capable (`src/rpc/handlers/block_query_handlers.zig:120`).
  - [major/test-coverage] No active EIP-7702 tests in default suite (`src/root.zig:14`).
  - [minor/test-coverage] Requested external runner is absent (`tests/external/state_tests_runner.zig`).

## Missing Tests

### EIP-1559 (eip-1559)
- Type-2 (`0x02`) execution tests covering signature recovery, nonce/balance checks, access-list intrinsic gas, and receipt typing.
- Base-fee update formula tests for increase/decrease/equal-target and fork-initialization behavior.
- Execution fee-accounting tests for effective-gas-price computation and tip-only miner payment with base-fee burn.
- GASPRICE opcode tests asserting it returns `effective_gas_price`.
- Validation tests for `max_fee_per_gas >= base_fee_per_gas` and `max_priority_fee_per_gas <= max_fee_per_gas`.
- State-test runner coverage for London/EIP-1559 vectors (or equivalent external fixture-driven tests).

### Awaiting User Direction (eip-2929)
- None reported (paused).

### Optional access lists (eip-2930)
- Type-1 decode/validation tests for `0x01 || rlp([chainId, nonce, gasPrice, gasLimit, to, value, data, accessList, yParity, r, s])`.
- Signature-domain tests proving hash/signature uses `keccak256(0x01 || rlp([...accessList]))`.
- Intrinsic gas tests adding `2400` per access-list address and `1900` per storage key.
- Access-list validation tests for exact 20-byte addresses and 32-byte storage keys.
- Duplicate access-list entry tests proving duplicates are accepted and charged multiple times.
- Execution tests proving access-list entries are pre-warmed in accessed-address/storage sets before opcode execution.
- Receipt/type tests proving EIP-2930 transactions produce type `0x1` receipts/tx metadata.
- State-vector integration tests for `lib/ethereum-tests/TransactionTests/ttEIP2930/*` and `lib/execution-spec-tests/tests/static/state_tests/stEIP2930/*`.

### BASEFEE opcode (eip-3198)
- Execute bytecode `0x48 0x00` through zevm tx execution with non-zero `block_base_fee` and assert stack output equals that value.
- Regression test that mined block execution context uses runtime/header base fee (not hardcoded zero).
- Gas accounting test asserting `BASEFEE` consumes exactly 2 gas.
- External London+ state-test fixture coverage for `BASEFEE` via `tests/external/state_tests_runner.zig` (or equivalent harness).
- If multi-fork behavior is intended, a pre-London test asserting opcode `0x48` is invalid before London.

### EIP-3529 (eip-3529)
- Transaction-level test for `SSTORE` nonzero-to-zero with refund 4800 (not 15000).
- Transaction-level tests for restore-to-original cases (`zero->nonzero->zero` and `nonzero->other->original`) asserting 19900 and 2800 refund paths.
- Transaction-level test with `SELFDESTRUCT` asserting no refund in London+.
- Boundary tests for refund capping at `gas_used // 5` including rounding edges.
- Fork-boundary tests (pre-London vs London) proving activation behavior.
- External state-test coverage for London/EIP-3529 vectors.

### EIP-3651 (eip-3651)
- External state-test coverage for Shanghai `stEIP3651_warmcoinbase` fixtures (`coinbaseWarmAccountCallGas`, `coinbaseWarmAccountCallGasFail`).
- Fork-boundary regression: pre-Shanghai first COINBASE access cold (2600), Shanghai+ warm (100).
- Opcode-matrix tests against COINBASE at tx start: `BALANCE`, `EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`, `CALL`, `CALLCODE`, `DELEGATECALL`, `STATICCALL`.
- Low-gas edge tests confirming 100-gas COINBASE calls fail pre-Shanghai and succeed at Shanghai+ when only warm-account cost is available.

### EIP-3855 (eip-3855)
- End-to-end zevm tx test executing bytecode with `0x5f` and asserting pushed value is zero.
- Gas-accounting assertion that PUSH0 charges exactly 2 gas.
- Boundary test for 1024 consecutive PUSH0 success and 1025th stack overflow failure.
- Fork-activation test at zevm integration level: pre-Shanghai treats `0x5f` as invalid opcode (if historical execution is supported).
- External state-test coverage for EIP-3855 fixtures via state-test runner.

### EIP-3860 (eip-3860)
- Create tx intrinsic gas includes `INITCODE_WORD_COST * ceil(len(initcode)/32)` for len 1, 32, 33.
- Create tx with initcode length 49152 accepted when gas exactly covers EIP-3860 intrinsic cost.
- Create tx with initcode length 49153 rejected as invalid before execution/pool admission.
- CREATE opcode tests for 49152 vs 49153 initcode behavior and gas outcomes.
- CREATE2 opcode tests for 49152 vs 49153 initcode behavior and gas outcomes.
- CREATE/CREATE2 gas charging includes extra 2 gas per 32-byte word before address calc/execution.
- External/state-test harness coverage for Shanghai EIP-3860 vectors.

### EIP-4399 (eip-4399)
- Pre-transition case: execute opcode `0x44` and assert return equals header difficulty in parent of transition block.
- Transition-block case: execute opcode `0x44` and assert return equals block header mixHash/prevRandao.
- Post-transition non-zero randao case, including values above `2**64`.
- Gas metering check for unchanged opcode `0x44` gas cost across pre/post transition.
- Block-production check that mined/sealed headers persist `mixHash` from consensus randao input.

### EIP-4844 (eip-4844)
- Type-3 acceptance/rejection tests enforcing non-nil `to`, non-empty `blob_versioned_hashes`, and version byte checks `0x01`.
- Upfront sender balance checks including `max_fee_per_blob_gas * total_blob_gas`, plus non-refundable blob fee burn on execution failure.
- `excess_blob_gas` transition tests including first post-fork parent semantics and ongoing update rule.
- Per-block blob gas accounting tests enforcing `MAX_BLOB_GAS_PER_BLOCK` and header `blob_gas_used` consistency.
- `BLOBHASH` opcode tests for in-range index and out-of-range zero return.
- Point-evaluation precompile `0x0A` tests: input length, versioned-hash/commitment match, KZG proof verification, non-canonical field-element rejection.
- Network-wrapper validation tests for pooled blob tx form `[tx_payload_body, blobs, commitments, proofs]` including count matching and KZG checks.
- RPC shape tests for type-3 fields `maxFeePerBlobGas` and `blobVersionedHashes` in submitted and hydrated txs.

### EIP-4895 (eip-4895)
- Post-Shanghai block execution test that applies withdrawals after txs and verifies recipient balance increase by `amount * 1_000_000_000` wei.
- Validation test rejecting blocks/payloads where `withdrawals_root` mismatches trie root of withdrawals list.
- Fork-boundary test around `FORK_TIMESTAMP = 1681338455`.
- Test proving withdrawal processing is unconditional (no gas charge, no failure), including credits to empty/new accounts.
- Multi-withdrawal ordering/accumulation test with repeated recipients and mixed txs proving post-transaction application order.

### EIP-5656 (eip-5656)
- End-to-end zevm tx execution tests asserting MCOPY fork activation by context (pre-Cancun invalid opcode, Cancun+ valid).
- Correct-stack-order MCOPY unit tests (`len`, `src`, `dst`) with exact post-memory assertions.
- Exact gas-accounting assertions for canonical EIP-5656 examples including no-expansion and expansion cases.
- Execution-spec integration guard that fails build when `specs-cancun-mcopy` selects zero tests.
- Boundary tests for large-memory behavior beyond 16MB to validate/justify divergence.

### EIP-6780 (eip-6780)
- SELFDESTRUCT on pre-existing contract: halt and transfer full balance without deleting code/storage/nonce.
- SELFDESTRUCT on same-tx-created contract: delete account state at tx end.
- Beneficiary equals self split: pre-existing contract no burn; same-tx-created contract burn.
- CREATE/CREATE2 to address with pre-existing balance still treated as created-this-tx for EIP-6780.
- Nested/reverted calls rollback SELFDESTRUCT side effects and deletion markers.
- Explicit EIP-3529/EIP-2929 invariants for SELFDESTRUCT (no refund, warm/cold beneficiary costs).

### EIP-7702 (eip-7702)
- Execute valid type-4 set-code tx and assert delegation code `0xef0100 || address`, authorizer nonce increment, and receipt type `0x4`.
- Verify authorization processing occurs before execution and persists even when execution reverts.
- Validate per-tuple failure semantics: invalid tuple skipped, processing continues, later tuples still apply.
- Validate duplicate-authority semantics: last valid tuple wins.
- Test zero delegate address behavior (clear delegation code to empty-code hash).
- Test intrinsic gas and refund accounting: `PER_EMPTY_ACCOUNT_COST * len(authorization_list)` and non-empty-authority refund adjustment.
- Test chain-id and nonce tuple rules (`chain_id` 0 or local chain only, nonce bounds, authority nonce match).
- Test delegated call resolution semantics (`CALL`, `CALLCODE`, `DELEGATECALL`, `STATICCALL`) including precompile target behavior.
- Test delegation loops/chains resolve only one hop.
- Test EIP-3607 origination behavior for delegated EOAs vs non-delegation code EOAs.
- RPC round-trip tests for type-4 tx (`eth_getTransactionByHash`, hydrated block txs) including `authorizationList` serialization.

---

## Review: Yellow Paper

_chunks=10 avgConform=30 avgCov=24 issues=72 crit=12_

# Yellow Paper Spec Review

## Executive Summary
- Chunks reviewed: 10
- Average conformance: 30/100 (raw 30.2)
- Average test coverage: 24/100 (raw 23.8)
- Issues: 72 total (12 critical, 45 major, 14 minor, 1 nit)
- Overall: conformance is low and evidence is weak; major Yellow Paper requirements are missing across block validity, typed transactions, London fee rules, message-call/create integration, and genesis.

## Top Risks
- [critical] Header validity V(H) is not implemented in block acceptance flow ([src/block_builder.zig](src/block_builder.zig)).
- [critical] Holistic block validity commitments are missing (stateRoot/transactionsRoot/receiptsRoot/withdrawalsRoot/logsBloom) ([src/block_builder.zig](src/block_builder.zig)).
- [critical] London fee settlement is incorrect: base-fee burn is missing and coinbase is over-credited ([src/tx_processor.zig:190](src/tx_processor.zig:190)).
- [critical] Typed transaction execution is missing; executor is legacy-only ([src/tx_processor.zig:10](src/tx_processor.zig:10)).
- [critical] Top-level CALL/CREATE integration does not correctly execute bytecode in key paths ([src/tx_processor.zig:149](src/tx_processor.zig:149), [/Users/williamcory/zevm/src/tx_processor.zig](/Users/williamcory/zevm/src/tx_processor.zig)).
- [critical] Canonical 21,000-gas transfer behavior currently fails ([src/tx_processor.zig:133](src/tx_processor.zig:133), [src/tx_processor_test.zig](src/tx_processor_test.zig)).
- [major] Intrinsic gas and validity checks are incomplete for modern rules (initcode word cost, initcode size cap, access-list costs, sender-with-code) ([src/tx_processor.zig](src/tx_processor.zig)).
- [critical] Appendix I genesis tuple is absent in audited pipeline; current constructor diverges from Appendix I constants and stateRoot derivation ([src/block_builder.zig:28](src/block_builder.zig:28), [src/genesis.zig:80](src/genesis.zig:80), [src/genesis.zig:96](src/genesis.zig:96)).

## Foreign Feature Gaps
- Hardfork-aware header derivation/validation and post-Merge defaults ([lib/edr/crates/block/header/src/lib.rs](lib/edr/crates/block/header/src/lib.rs)).
- Explicit withdrawals-aware block builder and required-fork checks ([lib/edr/crates/block/builder/api/src/lib.rs](lib/edr/crates/block/builder/api/src/lib.rs)).
- PREVRANDAO and next-block base-fee controls with hardfork gating ([lib/edr/crates/edr_provider/src/requests/methods.rs](lib/edr/crates/edr_provider/src/requests/methods.rs), [lib/edr/crates/edr_provider/src/data.rs](lib/edr/crates/edr_provider/src/data.rs), [lib/edr/crates/edr_provider/src/requests/hardhat/config.rs](lib/edr/crates/edr_provider/src/requests/hardhat/config.rs)).
- Typed fee/effective-gas-price logic and validation for EIP-1559 ([lib/edr/crates/edr_transaction/src/signed/eip1559.rs](lib/edr/crates/edr_transaction/src/signed/eip1559.rs), [lib/edr/crates/edr_provider/src/requests/validation.rs](lib/edr/crates/edr_provider/src/requests/validation.rs)).
- Access-list-aware execution and intrinsic gas paths ([lib/foundry/crates/evm/evm/src/inspectors/mod.rs](lib/foundry/crates/evm/evm/src/inspectors/mod.rs), [lib/foundry/crates/evm/evm/src/executors/mod.rs](lib/foundry/crates/evm/evm/src/executors/mod.rs)).
- Runtime-selectable hardfork/spec controls ([lib/foundry/crates/evm/evm/src/executors/builder.rs](lib/foundry/crates/evm/evm/src/executors/builder.rs), [lib/edr/crates/foundry/evm/evm/src/executors/builder.rs](lib/edr/crates/foundry/evm/evm/src/executors/builder.rs)).
- Strong primitive/newtype typing and explicit tx-kind modeling ([lib/edr/crates/primitives/src/lib.rs](lib/edr/crates/primitives/src/lib.rs), [lib/edr/crates/edr_chain_spec/src/transaction.rs](lib/edr/crates/edr_chain_spec/src/transaction.rs)).
- Inspector/dry-run/tracing APIs and call lifecycle observability ([lib/edr/crates/evm/src/lib.rs](lib/edr/crates/evm/src/lib.rs), [lib/edr/crates/tracing/src/lib.rs](lib/edr/crates/tracing/src/lib.rs), [lib/foundry/crates/evm/evm/src/inspectors/stack.rs](lib/foundry/crates/evm/evm/src/inspectors/stack.rs)).
- Debug trace RPCs, impersonation/prank/origin override, precompile override controls ([lib/edr/crates/edr_provider/src/requests/methods.rs](lib/edr/crates/edr_provider/src/requests/methods.rs), [lib/edr/crates/foundry/cheatcodes/src/evm/prank.rs](lib/edr/crates/foundry/cheatcodes/src/evm/prank.rs), [lib/edr/crates/edr_provider/src/data.rs](lib/edr/crates/edr_provider/src/data.rs)).
- CREATE2 helper surfaces and configurable initcode/code-size policy knobs ([lib/foundry/crates/evm/evm/src/executors/mod.rs](lib/foundry/crates/evm/evm/src/executors/mod.rs), [lib/edr/crates/edr_provider/src/requests/eth/transactions.rs](lib/edr/crates/edr_provider/src/requests/eth/transactions.rs), [lib/foundry/crates/evm/core/src/opts.rs](lib/foundry/crates/evm/core/src/opts.rs)).

## Per-Chunk Findings

### Section 2 — Blockchain & Block Validity (section-2-blocks)
- Conformance: 23
- Test coverage: 21
- Summary: only sequential tx application and block gas budgeting are implemented; Yellow Paper header/holistic validity is largely absent.
- Issues:
  - [critical/conformance] Missing V(H) header validation ([src/block_builder.zig](src/block_builder.zig)).
  - [major/conformance] Missing holistic root and bloom derivation/checks ([src/block_builder.zig](src/block_builder.zig)).
  - [major/conformance] Receipt bloom hardcoded to zero ([src/tx_processor.zig:194](src/tx_processor.zig:194)).
  - [major/conformance] Withdrawals and ommer constraints absent ([src/block_builder.zig](src/block_builder.zig)).
  - [major/missing-feature] Typed tx/receipt trie handling missing ([src/tx_processor.zig](src/tx_processor.zig)).
  - [major/test-coverage] No tests for V(H) predicates ([src/block_builder_test.zig](src/block_builder_test.zig)).
  - [major/test-coverage] No tests for root correctness ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [minor/test-coverage] Baseline tx_processor tests currently failing ([src/tx_processor_test.zig](src/tx_processor_test.zig)).

### Section 3 — Conventions (section-3-conventions)
- Conformance: 74
- Test coverage: 43
- Summary: mostly aligned at notation level, but deterministic error handling and scalar-domain safety are weak.
- Issues:
  - [major/conformance] HostAdapter methods panic on state backend errors ([src/host_adapter.zig](src/host_adapter.zig)).
  - [minor/conformance] chain_id narrowed to u64 in tx hash path ([src/tx_processor.zig:197](src/tx_processor.zig:197)).
  - [major/test-coverage] End-to-end tests were not executable in this environment (blst build failure).
  - [minor/test-coverage] Missing boundary/error-path tests for numeric/byte assumptions ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [minor/missing-feature] Missing domain-specific primitive/newtype plumbing ([src/tx_processor.zig](src/tx_processor.zig)).
  - [nit/missing-feature] Tx shape inferred from nullable destination instead of explicit kind ([src/tx_processor.zig:149](src/tx_processor.zig:149)).

### Section 4 - Blocks, State and Transactions (section-4-blocks-state-txs)
- Conformance: 28
- Test coverage: 30
- Summary: narrow legacy-only path; major Section 4 obligations are missing.
- Issues:
  - [critical/conformance] EIP-1559 fee semantics missing ([src/tx_processor.zig](src/tx_processor.zig)).
  - [critical/conformance] Execution path supports only legacy tx ([src/tx_processor.zig](src/tx_processor.zig)).
  - [major/conformance] Intrinsic gas/create validity incomplete ([src/tx_processor.zig](src/tx_processor.zig)).
  - [major/conformance] Intrinsic validity checks incomplete (sender/signature/EIP-3607) ([src/tx_processor.zig](src/tx_processor.zig)).
  - [major/conformance] Receipt logs bloom hardcoded to zero ([src/tx_processor.zig](src/tx_processor.zig)).
  - [critical/conformance] Block holistic/header validity derivations absent ([src/block_builder.zig](src/block_builder.zig)).
  - [major/conformance] Simple transfer and sequential nonce expectations currently fail ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [major/test-coverage] No fee-market correctness tests ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [major/test-coverage] No typed tx/access-list/initcode-bound tests ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [major/test-coverage] No root/header validity tests ([src/block_builder_test.zig](src/block_builder_test.zig)).
  - [minor/missing-feature] No access-list-aware execution tooling ([src/tx_processor.zig](src/tx_processor.zig)).

### Section 5 — Gas and Payment (section-5-gas-and-payment)
- Conformance: 35
- Test coverage: 22
- Summary: some legacy gas/refund mechanics exist; London-era fee rules are incorrect/incomplete.
- Issues:
  - [critical/conformance] Coinbase over-credited; base-fee burn missing ([src/tx_processor.zig:190](src/tx_processor.zig:190)).
  - [major/conformance] No base-fee floor validation ([src/tx_processor.zig:111](src/tx_processor.zig:111)).
  - [major/conformance] Type-2 fee semantics missing ([src/tx_processor.zig:10](src/tx_processor.zig:10)).
  - [major/conformance] Intrinsic gas formula incomplete for modern rules ([src/tx_processor.zig:25](src/tx_processor.zig:25)).
  - [major/conformance] Missing initcode size validity check ([src/tx_processor.zig:115](src/tx_processor.zig:115)).
  - [minor/conformance] Sender-with-code rule not enforced ([src/tx_processor.zig:111](src/tx_processor.zig:111)).
  - [major/test-coverage] Tests only cover base_fee=0 legacy settlement ([src/tx_processor_test.zig:29](src/tx_processor_test.zig:29)).
  - [major/test-coverage] Missing intrinsic/validity edge-case tests ([src/tx_processor_test.zig:43](src/tx_processor_test.zig:43)).
  - [major/test-coverage] Baseline tx_processor tests failing ([src/tx_processor_test.zig:49](src/tx_processor_test.zig:49)).

### Section 6 — Transaction Execution (section-6-transaction-execution)
- Conformance: 34
- Test coverage: 29
- Summary: legacy subset only; critical Section 6 fee and validity rules are missing.
- Issues:
  - [critical/conformance] Basic 21,000-gas transfer success path failing ([src/tx_processor.zig:133](src/tx_processor.zig:133)).
  - [major/conformance] London fee settlement semantics not implemented ([src/tx_processor.zig:190](src/tx_processor.zig:190)).
  - [major/conformance] Intrinsic gas formula incomplete ([src/tx_processor.zig:25](src/tx_processor.zig:25)).
  - [major/conformance] Typed transaction execution rules missing ([src/tx_processor.zig:10](src/tx_processor.zig:10)).
  - [major/conformance] Missing EIP-3607/initcode-size checks ([src/tx_processor.zig:111](src/tx_processor.zig:111)).
  - [major/test-coverage] Canonical transfer behavior not proven; current success-path tests fail ([src/tx_processor_test.zig:79](src/tx_processor_test.zig:79)).
  - [major/test-coverage] No London base-fee gating and fee-split coverage ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [major/test-coverage] No EIP-3860/EIP-2930 intrinsic branch coverage ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [minor/test-coverage] No explicit selfdestruct/touched-empty finalization tests ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [major/missing-feature] Missing typed fee and access-list execution support ([src/tx_processor.zig:10](src/tx_processor.zig:10)).

### Section 7 — Contract Creation (section-7-contract-creation)
- Conformance: 20
- Test coverage: 8
- Summary: contract-creation path is materially non-conformant and under-tested.
- Issues:
  - [critical/conformance] Top-level create integration does not execute creation lifecycle correctly ([/Users/williamcory/zevm/src/tx_processor.zig](/Users/williamcory/zevm/src/tx_processor.zig)).
  - [critical/conformance] Create intrinsic gas undercharged; missing initcode word cost ([/Users/williamcory/zevm/src/tx_processor.zig](/Users/williamcory/zevm/src/tx_processor.zig)).
  - [major/conformance] Initcode-size validity not enforced pre-execution ([/Users/williamcory/zevm/src/tx_processor.zig](/Users/williamcory/zevm/src/tx_processor.zig)).
  - [major/conformance] Create execution environment fields not fully populated (ORIGIN/GASPRICE) ([/Users/williamcory/zevm/src/tx_processor.zig](/Users/williamcory/zevm/src/tx_processor.zig)).
  - [major/test-coverage] No direct contract-creation tests in tx/block suites ([/Users/williamcory/zevm/src/tx_processor_test.zig](/Users/williamcory/zevm/src/tx_processor_test.zig)).
  - [minor/test-coverage] Baseline tests are red ([/Users/williamcory/zevm/src/tx_processor_test.zig](/Users/williamcory/zevm/src/tx_processor_test.zig)).

### Section 8 — Message Call (section-8-message-call)
- Conformance: 20
- Test coverage: 18
- Summary: delegated semantics are wired incorrectly in critical top-level call paths.
- Issues:
  - [critical/conformance] Top-level contract calls do not execute target code ([src/tx_processor.zig](src/tx_processor.zig)).
  - [critical/conformance] Valid 21,000-gas ETH transfer fails due zero-execution-gas handling ([src/tx_processor.zig](src/tx_processor.zig)).
  - [major/conformance] ORIGIN and GASPRICE context not propagated ([src/tx_processor.zig](src/tx_processor.zig)).
  - [major/test-coverage] No tests for contract-code CALL-family semantics ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [major/test-coverage] Baseline tx_processor tests failing ([src/tx_processor_test.zig](src/tx_processor_test.zig)).

### Section 9 — Execution Model (section-9-execution-model)
- Conformance: 36
- Test coverage: 27
- Summary: partial framing and rollback exist, but key execution-model semantics are not proven.
- Issues:
  - [major/conformance] ORIGIN/GASPRICE not wired from tx context ([src/tx_processor.zig:139](src/tx_processor.zig:139)).
  - [major/conformance] Zero execution-gas top-level path can fail when it should halt normally ([src/tx_processor.zig:133](src/tx_processor.zig:133)).
  - [major/test-coverage] Exceptional-halting and cycle semantics not directly tested ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [minor/test-coverage] Baseline includes failing tx_processor cases ([src/tx_processor_test.zig:49](src/tx_processor_test.zig:49)).
  - [minor/conformance] Host adapter panics on state access failures ([src/host_adapter.zig:32](src/host_adapter.zig:32)).

### Appendix H — Virtual Machine Specification (appendix-h-virtual-machine-specification)
- Conformance: 18
- Test coverage: 22
- Summary: low conformance in wrapper integration around delegated VM APIs.
- Issues:
  - [critical/conformance] Top-level CALL/CREATE path does not supply bytecode to EVM ([src/tx_processor.zig:149](src/tx_processor.zig:149)).
  - [major/conformance] Intrinsic-only transfers can fail due zero execution gas ([src/tx_processor.zig:133](src/tx_processor.zig:133)).
  - [major/conformance] Hardfork is implicit default, not selected from chain/block context ([src/tx_processor.zig:139](src/tx_processor.zig:139)).
  - [major/test-coverage] No integration tests proving contract call/create semantics ([src/tx_processor_test.zig](src/tx_processor_test.zig)).
  - [minor/test-coverage] Baseline happy-path tx_processor tests failing ([src/tx_processor_test.zig:49](src/tx_processor_test.zig:49)).
  - [minor/missing-feature] No optional inspector/tracer hook in tx execution API ([src/tx_processor.zig](src/tx_processor.zig)).

### Appendix I — Genesis Block (appendix-i-genesis-block)
- Conformance: 14
- Test coverage: 18
- Summary: Appendix I genesis is not implemented in audited modules; current genesis path is devnet-style and non-conformant.
- Issues:
  - [critical/conformance] Appendix I genesis behavior absent in audited modules ([src/block_builder.zig:28](src/block_builder.zig:28)).
  - [major/conformance] Genesis constructor uses non-Appendix-I constants ([src/genesis.zig:80](src/genesis.zig:80)).
  - [major/conformance] Genesis stateRoot not derived from initialized state ([src/genesis.zig:96](src/genesis.zig:96)).
  - [major/test-coverage] No scoped tests proving Appendix I tuple equivalence ([src/tx_processor_test.zig:43](src/tx_processor_test.zig:43)).
  - [minor/test-coverage] Existing genesis tests assert devnet semantics ([src/genesis_test.zig:95](src/genesis_test.zig:95)).
  - [minor/test-coverage] Suite not fully green ([src/tx_processor_test.zig:79](src/tx_processor_test.zig:79)).

## Missing Tests

### Section 2 — Blockchain & Block Validity
- Header validity V(H): gasUsed<=gasLimit, gasLimit delta bounds, timestamp monotonicity, parent-number increment, extraData length<=32.
- Base-fee function F(H) across parent gas-used scenarios.
- Post-Paris constants checks: empty ommersHash, difficulty=0, nonce=0, PREVRANDAO binding.
- Holistic validity root checks: stateRoot after txs and withdrawals, transactionsRoot, receiptsRoot, withdrawalsRoot.
- Typed tx/receipt trie encoding tests (EIP-2718 envelope handling).
- Block logsBloom derivation from per-receipt blooms and emitted logs.
- Negative tests for invalid headers (bad roots, bad timestamp, bad base fee, non-empty ommers, etc.).
- Withdrawals application-order and withdrawalsRoot correctness tests (post-Shanghai).
- End-to-end block assembly tests that bind execution result to finalized header fields.

### Section 3 — Conventions
- Boundary test where block_ctx.chain_id exceeds u64 range for deterministic tx-hash handling.
- HostAdapter failure-path tests for all vtable methods on backend read/write errors.
- allocateEventLogs topic encoding test for u256 to B_32 big-endian conversion.
- Property/boundary tests for intrinsicGas/processTransaction near max u64/u256 values.

### Section 4 - Blocks, State and Transactions
- Type 1 (EIP-2930) and type 2 (EIP-1559) execution path tests including chainId/accessList/maxFee/maxPriority constraints.
- Base-fee enforcement and fee accounting split tests (priority fee to beneficiary, base fee burned).
- Sender-with-code rejection and signature/decoded-sender validity tests.
- Initcode word-cost charging (EIP-3860) and initcode length<=49152 enforcement tests.
- Per-receipt logs bloom derivation tests.
- Block-level transactionsRoot/receiptsRoot/logsBloom/withdrawalsRoot derivation checks.
- Block header V(H) checks: gas-limit drift bounds, baseFee F(H), extraData length, PoS constants, PREVRANDAO binding.
- Withdrawal list processing and withdrawalsRoot behavior tests.
- Regression test proving 21,000-gas plain ETH transfer succeeds.

### Section 5 — Gas and Payment
- Legacy tx with non-zero base fee where gasPrice<baseFee rejection.
- Legacy tx with non-zero base fee: coinbase gets priority fee only and base fee is burned.
- Type-2 validity: maxFeePerGas>=baseFee and maxPriorityFeePerGas<=maxFeePerGas.
- Type-2 settlement formula tests for effective price, sender debit/refund, and coinbase credit.
- Contract-creation intrinsic gas includes initcode word cost R(len(initcode)).
- Create tx initcode length>49152 rejection.
- Intrinsic gas includes access-list address/storage warm-up charges.
- Refund-cap edge case for refund_counter > floor((Tg-gprime)/5).
- Revert failure path where nonce and upfront gas purchase persist while EVM changes revert.

### Section 6 — Transaction Execution
- Legacy tx with gasPrice<block_base_fee rejected before execution.
- EIP-1559 validation rejects maxPriorityFeePerGas>maxFeePerGas.
- EIP-1559 settlement tests: sender charged effective price, validator gets priority fee only, base fee burned.
- Create intrinsic gas includes R(len(initcode)).
- Create tx with initcode length>49152 rejected.
- Access-list intrinsic gas accounting enforced.
- Sender-with-code (EIP-3607) rejected pre-execution.
- 21,000-gas ETH transfer to EOA succeeds with correct status and balances.
- Failure path where nonce/gas prepayment persists while EVM state changes revert.
- Refund-counter cap edge case for min(floor((Tg-gprime)/5), Ar).

### Section 7 — Contract Creation
- Successful create tx deploys runtime code and sets non-null receipt.contract_address.
- Create intrinsic gas includes EIP-3860 initcode word cost R(len(initcode)).
- Create tx with initcode length>49152 rejected before state transition.
- Init-code REVERT semantics: status=0, remaining gas behavior, no persisted created account/code/value.
- Code-deposit out-of-gas path consumes remaining gas and leaves no deployed code/value transfer.
- Returned runtime code length>24576 rejected (EIP-170).
- Returned runtime code starting with 0xef rejected (EIP-3541).
- Create-address derivation uses sender nonce-at-start-of-operation semantics.
- Init-code environment sets ORIGIN and effective gas price correctly.
- Collision case (target already has nonce/code) fails without persisting created-account effects.

### Section 8 — Message Call
- Top-level tx to non-empty-code account executes callee bytecode and persists state changes on success.
- Top-level ETH transfer with gas_limit==intrinsic (21,000) succeeds for EOA recipient.
- ORIGIN equals transaction sender in top-level and nested contexts.
- GASPRICE equals transaction gas price/effective gas price in execution context.
- End-to-end CALL/CALLCODE/DELEGATECALL/STATICCALL tests for return values, returndata copying, and revert propagation.
- Depth-limit 1024 and insufficient internal-call funds tests return failure flag without parent-state corruption.

### Section 9 — Execution Model
- Top-level message call with execution_gas==0 to empty-code recipient halts normally and transfers value.
- ORIGIN/GASPRICE integration tests with non-zero sender and gas price.
- Exceptional halt tests for invalid opcode and stack underflow with rollback assertions.
- JUMP/JUMPI invalid destination exceptional-halting tests.
- RETURNDATACOPY bounds-violation exceptional-halting tests.
- Static-context write prohibition tests (SSTORE, LOG*, CREATE*, CALL with value under static context).
- REVERT tests for returndata propagation, state rollback, and remaining gas handling.
- Nested call/create depth-limit (1024) behavior tests.

### Appendix H — Virtual Machine Specification
- Top-level CALL executes callee runtime bytecode loaded from state.
- Contract-creation tx executes init code and persists returned runtime code at created address.
- EOA transfer with gas_limit==intrinsic (21000) succeeds via STOP semantics with correct balances/nonce/receipt status.
- Tx-level gas refund tests for SSTORE/SELFDESTRUCT including refund cap through tx_processor integration.
- CALL/DELEGATECALL/STATICCALL integration tests for gas forwarding and nested-call behavior including 63/64 expectations.
- CREATE/CREATE2 integration tests for address derivation and collision behavior.

### Appendix I — Genesis Block
- Appendix I field-by-field genesis header assertions: beneficiary zero, difficulty=2^34, nonce=KEC((42)), mix hash, gas fields, extraData empty.
- Test that genesis stateRoot is computed from initialized premine state and matches trie root.
- Fixture test for exact Appendix I genesis header/body RLP encoding and resulting block hash.
- Integration test proving where genesis construction happens in audited execution path or explicit delegation contract.
- Profile-separation test ensuring devnet genesis defaults cannot silently replace Appendix I constants.
- Negative test for mismatch against Appendix I constants (beneficiary/difficulty/nonce/gas).

---

## Review: execution-specs (forks)

_chunks=13 avgConform=25 avgCov=12 issues=99 crit=20_

# execution-specs Spec Review

## Executive Summary
- Total chunks reviewed: 13.
- Average conformance: 24.69/100.
- Average test coverage: 12.46/100.
- Total issues: 99.
- Severity mix: 20 critical, 68 major, 11 minor, 0 nit.
- Overall: conformance is consistently low-to-moderate across forks, with recurring gaps in hardfork selection, typed transaction support, fee/refund accounting, and consensus-path block transitions.

## Top Risks
- [critical] Fork semantics are not pinned in execution, with EVM often initialized using `hardfork = null` and inheriting PRAGUE/default behavior instead of the target fork (`src/tx_processor.zig:138`, `src/tx_processor.zig:139`).
- [critical] Transaction execution is legacy-centric in audited paths, missing required typed flows and checks for Berlin+ and Prague (`src/tx_processor.zig:10`, `src/tx_processor.zig:120`).
- [critical/major] Fee and refund accounting diverges from fork rules: pre-London refunds should cap at 1/2, while London+ needs base-fee-aware burn/tip split (`src/tx_processor.zig:179`, `src/tx_processor.zig:185`, `src/tx_processor.zig:120`).
- [major] Sender authenticity and inclusion checks are bypassed in favor of externally supplied `caller`, skipping signature recovery/validation and EOA gating (`src/tx_processor.zig:103`, `src/tx_processor.zig:107`, `src/tx_processor.zig:112`).
- [major] Consensus block-transition behavior is incomplete in audited block paths, including invalid-included-tx handling, rewards/difficulty transitions, Paris header constraints, Shanghai withdrawals, Cancun system tx/blob accounting, and Prague requests (`src/block_builder.zig:28`, `src/block_builder.zig:41`, `src/block_builder.zig:43`, `src/block_builder.zig:59`).
- [major] External state-test conformance harness is missing in the active tree (`tests/external/state_tests_runner.zig`), so cross-client fixture proof is largely absent.

## Foreign Feature Gaps
- Explicit hardfork/spec mapping and per-run spec selection are standard in reference implementations but missing from zevm audited execution paths (`lib/foundry/crates/evm/core/src/hardfork.rs`, `lib/foundry/crates/evm/evm/src/executors/builder.rs`, `lib/edr/crates/chain/spec/evm/src/config.rs`).
- Chain-configured hardfork activation schedules and runtime fork resolution are present in EDR/Foundry, but no equivalent active selection surface was found in zevm tx execution (`lib/edr/crates/edr_chain_l1/src/chains.rs`, `lib/edr/crates/edr_provider/src/data.rs`, `lib/foundry/crates/config/src/utils.rs`).
- Hardfork-gated transaction/request validation and user-facing errors are implemented in EDR, while zevm audited path lacks comparable gating (`lib/edr/crates/edr_provider/src/requests/validation.rs`, `lib/edr/crates/edr_provider/src/error.rs`, `lib/edr/crates/edr_provider/src/requests/resolve.rs`).
- Typed transaction support (EIP-2930/1559/4844/7702) is first-class in references and absent or partial in zevm audited tx processor (`lib/foundry/crates/evm/core/src/utils.rs`, `lib/edr/crates/edr_transaction/src/request/eip2930.rs`, `lib/edr/crates/edr_transaction/src/signed/eip7702.rs`).
- Hardfork-aware reward/difficulty/base-fee handling is available in references but not in zevm block paths reviewed (`lib/edr/crates/edr_eth/src/block/reward.rs`, `lib/edr/crates/block/header/src/difficulty.rs`, `lib/edr/crates/block/header/src/lib.rs`, `lib/edr/crates/eips/1559/src/lib.rs`).
- Spec-aware precompile/env switching is exposed in references and not wired through zevm execution selection (`lib/foundry/crates/evm/core/src/evm.rs`, `lib/edr/crates/precompile/src/lib.rs`, `lib/foundry/crates/evm/core/src/backend/mod.rs`).
- Dedicated old-fork fixture projects/integration suites exist in EDR/Foundry ecosystems, while equivalent active zevm fixture harnessing was not found (`lib/edr/hardhat-tests/test/fixture-projects/hardhat-network-fork-tangerine-whistle/hardhat.config.js`, `lib/edr/crates/edr_provider/tests/integration/eip7623/*`, `lib/edr/crates/edr_provider/tests/integration/eip7702/*`).

## Per-Chunk Findings

### Fork - frontier (`fork-frontier`)
- Conformance: 18
- Test coverage: 12
- Summary: Frontier behavior diverges in intrinsic gas/refund/fork selection/receipt/reward/block-invalid semantics.
- Issues:
- [critical/conformance] Frontier intrinsic gas constants not implemented (`src/tx_processor.zig:5`).
- [critical/conformance] Refund cap uses London `/5` instead of Frontier `/2` (`src/tx_processor.zig:179`).
- [critical/conformance] Execution defaults to PRAGUE (`src/tx_processor.zig:139`).
- [major/conformance] Sender recovery/signature validation bypassed (`src/tx_processor.zig:103`).
- [major/conformance] EOA-only sender rule not enforced (`src/tx_processor.zig:112`).
- [major/conformance] Receipt shape is post-Byzantium style (`src/tx_processor.zig:211`).
- [major/conformance] Invalid included tx is skipped instead of invalidating block (`src/block_builder.zig:59`).
- [major/conformance] Miner/ommer reward transition missing (`src/block_builder.zig:28`).
- [minor/conformance] Nonce overflow guard missing (`src/tx_processor.zig:113`).
- [major/test-coverage] External state-test runner missing (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Unit tests encode non-Frontier assumptions (`src/tx_processor_test.zig:43`).

### Fork - homestead (`fork-homestead`)
- Conformance: 28
- Test coverage: 15
- Summary: Partial Homestead support with major gaps in hardfork pinning, calldata cost, refund cap, signature/low-s checks.
- Issues:
- [major/conformance] Non-zero calldata intrinsic gas incorrect (`src/tx_processor.zig:7`).
- [critical/conformance] Hardfork not pinned to Homestead (`src/tx_processor.zig:139`).
- [major/conformance] Refund cap `/5` instead of `/2` (`src/tx_processor.zig:179`).
- [major/conformance] Signature and low-s checks bypassed (`src/tx_processor.zig:103`).
- [major/conformance] Invalid included tx dropped in block path (`src/block_builder.zig:59`).
- [major/test-coverage] External state-test runner missing (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Unit tests encode non-Homestead assumptions (`src/tx_processor_test.zig:46`).
- [minor/test-coverage] Baseline tx_processor tests currently failing.

### Fork - tangerine_whistle (`fork-tangerine_whistle`)
- Conformance: 22
- Test coverage: 9
- Summary: Tangerine Whistle semantics are not enforced due to missing fork pinning, wrong pricing/refund, and host account-existence gap.
- Issues:
- [critical/conformance] Execution path not pinned to Tangerine Whistle (`src/tx_processor.zig`).
- [major/conformance] Non-zero calldata gas 16 instead of 68 (`src/tx_processor.zig`).
- [major/conformance] Refund cap `/5` instead of `/2` (`src/tx_processor.zig`).
- [major/conformance] Host surface cannot represent account-existence semantics (`src/host_adapter.zig`).
- [major/test-coverage] External state-test runner missing (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Unit tests codify wrong Tangerine pricing (`src/tx_processor_test.zig`).

### Fork - spurious_dragon (`fork-spurious_dragon`)
- Conformance: 18
- Test coverage: 12
- Summary: Critical Spurious Dragon rules are missing: fork pinning, intrinsic/refund, signature recovery, EIP-161 cleanup.
- Issues:
- [critical/conformance] Default PRAGUE semantics used (`src/tx_processor.zig:138`).
- [critical/conformance] Non-zero calldata gas underpriced (`src/tx_processor.zig:7`).
- [major/conformance] Refund cap `/5` instead of `/2` (`src/tx_processor.zig:179`).
- [major/conformance] Sender/signature validation bypassed (`src/tx_processor.zig:103`).
- [major/conformance] EIP-161 touched-empty cleanup missing (`src/tx_processor.zig:169`).
- [minor/conformance] Block builder drops invalid txs (`src/block_builder.zig:59`).
- [major/test-coverage] External state-test runner absent (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Unit tests assert non-Spurious constants (`src/tx_processor_test.zig:43`).
- [minor/test-coverage] Baseline tx_processor failures remain (`src/tx_processor_test.zig:49`).
- [major/missing-feature] No zevm hardfork/spec config surface (`src/tx_processor.zig:138`).

### Fork - byzantium (`fork-byzantium`)
- Conformance: 27
- Test coverage: 14
- Summary: Byzantium context is not selected; refund/bloom/block transition logic is not fork-correct.
- Issues:
- [critical/conformance] Byzantium fork never selected (`src/tx_processor.zig:139`).
- [major/conformance] Non-zero calldata gas uses post-Byzantium value (`src/tx_processor.zig:7`).
- [major/conformance] Refund cap `/5` not `/2` (`src/tx_processor.zig:179`).
- [major/conformance] Receipt bloom hardcoded to zero (`src/tx_processor.zig:194`).
- [major/conformance] Byzantium block transition rules missing (`src/block_builder.zig:28`).
- [major/test-coverage] No active external Byzantium runner (`build.zig:82`, `tests/external/state_tests_runner.zig`).
- [major/test-coverage] Unit tests encode post-Byzantium assumptions (`src/tx_processor_test.zig:43`).
- [minor/test-coverage] Test suite not fully green.

### Fork - constantinople (`fork-constantinople`)
- Conformance: 18
- Test coverage: 9
- Summary: Constantinople execution not selected; intrinsic/refund/EIP-1234/EXTCODEHASH semantics diverge.
- Issues:
- [critical/conformance] Hardfork not set to Constantinople (`src/tx_processor.zig:138`).
- [major/conformance] Non-zero calldata gas 16 not 68 (`src/tx_processor.zig:7`).
- [major/conformance] Refund cap `/5` not `/2` (`src/tx_processor.zig:179`).
- [major/conformance] EIP-1234 reward/difficulty behavior missing (`src/block_builder.zig:28`).
- [major/conformance] EXTCODEHASH empty-account semantics diverge (`../guillotine-mini/src/instructions/handlers_context.zig:316`).
- [major/test-coverage] External state-test runner absent (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Tests encode non-Constantinople assumptions and fail (`src/tx_processor_test.zig:46`).

### Fork - istanbul (`fork-istanbul`)
- Conformance: 34
- Test coverage: 18
- Summary: Some Istanbul constants match, but refund quotient and fork selection are wrong; SSTORE dependency path mismatch observed.
- Issues:
- [critical/conformance] Refund cap uses London `/5` not Istanbul `/2` (`src/tx_processor.zig:179`).
- [major/conformance] Hardfork not pinned to Istanbul (`src/tx_processor.zig:138`).
- [major/conformance] Istanbul pre-Berlin SSTORE branch uses 200 instead of 800 (`../voltaire/packages/voltaire-zig/src/primitives/GasConstants/gas_constants.zig:1349`).
- [major/test-coverage] External Istanbul runner missing (`tests/external/state_tests_runner.zig`).
- [minor/test-coverage] No direct Istanbul opcode/gas delta assertions (`src/tx_processor_test.zig`, `src/block_builder_test.zig`, `src/host_adapter_test.zig`).

### Fork - berlin (`fork-berlin`)
- Conformance: 22
- Test coverage: 12
- Summary: Berlin support is not conformant due to missing fork pinning, typed/access-list flow, and refund rule mismatch.
- Issues:
- [critical/conformance] Hardfork not pinned to Berlin (`src/tx_processor.zig:139`).
- [critical/conformance] EIP-2718/2930 typed/access-list flow missing (`src/tx_processor.zig:10`).
- [major/conformance] Refund cap `/5` not `/2` (`src/tx_processor.zig:179`).
- [major/conformance] Sender validation diverges (signature/EOA/nonce bounds) (`src/tx_processor.zig:103`).
- [major/test-coverage] External Berlin runner absent (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Berlin behavior untested and suite not fully green (`src/tx_processor_test.zig`).

### Fork - london (`fork-london`)
- Conformance: 24
- Test coverage: 14
- Summary: London fee-market and header/base-fee transitions are not implemented; executor remains legacy-only.
- Issues:
- [critical/conformance] EIP-1559 fee accounting not implemented (`src/tx_processor.zig:120`).
- [critical/conformance] Hardfork not explicitly set to London (`src/tx_processor.zig:139`).
- [major/conformance] Executor is legacy-only (`src/tx_processor.zig:10`).
- [major/conformance] London header/base-fee validation missing (`src/block_builder.zig:28`).
- [major/conformance] Sender authenticity/EOA checks bypassed (`src/tx_processor.zig:103`).
- [major/test-coverage] No London-specific conformance tests (`src/tx_processor_test.zig:1`).
- [major/test-coverage] External state-test runner absent (`tests/external/state_tests_runner.zig`).
- [minor/test-coverage] Baseline tx_processor tests failing (`src/tx_processor_test.zig:49`).

### Fork - paris (`fork-paris`)
- Conformance: 28
- Test coverage: 18
- Summary: Paris gaps include base-fee economics, typed tx support, sender validation, fork pinning, and PoS header checks.
- Issues:
- [critical/conformance] Base-fee semantics missing from tx processing (`src/tx_processor.zig:120`).
- [major/conformance] Type-1/type-2 tx support missing (`src/tx_processor.zig:10`).
- [major/conformance] Sender trusted input instead of signature recovery (`src/tx_processor.zig:103`).
- [major/conformance] Hardfork not pinned to Paris (`src/tx_processor.zig:139`).
- [major/conformance] Paris header transition checks absent (`src/block_builder.zig:28`).
- [major/test-coverage] External Paris runner missing (`tests/external/state_tests_runner.zig`).
- [minor/test-coverage] Unit tests do not exercise Paris deltas (`src/tx_processor_test.zig:29`).

### Fork - shanghai (`fork-shanghai`)
- Conformance: 36
- Test coverage: 14
- Summary: Partial Shanghai behavior inherited from dependency, but withdrawals and initcode rules are missing in zevm integration.
- Issues:
- [critical/conformance] EIP-4895 withdrawals transition missing (`src/block_builder.zig`).
- [major/conformance] EIP-3860 initcode intrinsic metering not applied (`src/tx_processor.zig`).
- [major/conformance] Oversized initcode not rejected pre-inclusion (`src/tx_processor.zig`).
- [major/conformance] Fork execution not pinned to Shanghai (`src/tx_processor.zig`).
- [major/test-coverage] Shanghai conformance not proven; external runner missing (`tests/external/state_tests_runner.zig`).

### Fork - cancun (`fork-cancun`)
- Conformance: 30
- Test coverage: 8
- Summary: Cancun plumbing is incomplete: no blob tx path, blob-gas accounting, EIP-4788 system tx, or explicit Cancun selection.
- Issues:
- [critical/conformance] Legacy-only execution; EIP-4844 type-3 rules absent (`src/tx_processor.zig:10`).
- [major/conformance] Blob gas accounting missing in block builder (`src/block_builder.zig:41`).
- [major/conformance] EIP-4788 beacon-roots system tx missing (`src/block_builder.zig:43`).
- [major/conformance] Fee settlement lacks base-fee burn split (`src/tx_processor.zig:185`).
- [major/conformance] Hardfork not explicitly set to Cancun (`src/tx_processor.zig:139`).
- [major/conformance] BLOBHASH tx context never populated (`src/tx_processor.zig:144`).
- [major/test-coverage] No Cancun-focused tests in active suite (`src/tx_processor_test.zig`).
- [minor/test-coverage] External state-test runner path missing (`tests/external/state_tests_runner.zig`).
- [minor/test-coverage] Baseline tx_processor tests failing (`src/tx_processor_test.zig:49`).

### Fork - prague (`fork-prague`)
- Conformance: 16
- Test coverage: 7
- Summary: Lowest conformance: no typed transaction completeness, no EIP-7702/EIP-7685, missing EIP-7623 floor and Prague blob semantics.
- Issues:
- [critical/conformance] Legacy-only execution path, not Prague-complete (`src/tx_processor.zig`).
- [major/conformance] EIP-7623 calldata floor behavior missing (`src/tx_processor.zig`).
- [major/conformance] Fee distribution not EIP-1559/Prague compliant (`src/tx_processor.zig`).
- [critical/conformance] No EIP-7702 authorization/delegation transition (`src/tx_processor.zig`).
- [critical/conformance] No EIP-7685 request pipeline/state hooks (`src/block_builder.zig`).
- [major/conformance] No Prague blob gas accounting (`src/tx_processor.zig`).
- [major/test-coverage] External state-test runner missing (`tests/external/state_tests_runner.zig`).
- [major/test-coverage] Tests are legacy-focused and pre-Prague (`src/tx_processor_test.zig`).
- [minor/test-coverage] Baseline tx_processor tests not fully green (`src/tx_processor_test.zig`).

## Missing Tests

### Fork - frontier (`fork-frontier`)
- Frontier intrinsic gas vectors: non-zero calldata byte cost = 68 and no Frontier tx-create intrinsic surcharge.
- Signature recovery/validation tests (`v` in {27,28}, `r/s` bounds) and rejection of unsigned txs in execution path.
- Invalid sender tests for sender accounts with deployed code (EOA-only sender rule).
- Gas refund cap tests verifying Frontier rule `min(gas_used/2, refund_counter)` (not London 1/5).
- Fork-specific opcode/precompile boundary tests (Frontier-only precompile range `0x01..0x04`; post-Frontier opcodes rejected under Frontier).
- Receipt-shape tests for Frontier receipts (post-state root semantics).
- Block finalization tests for Frontier miner + ommer reward accounting.
- Consensus-path tests where invalid tx inside a block invalidates the block instead of being skipped.

### Fork - homestead (`fork-homestead`)
- Homestead intrinsic gas vector tests asserting 68 gas per non-zero calldata byte (plus 32,000 for create tx).
- Homestead signature validation tests for `v in {27,28}`, `r` bounds, and `s <= secp256k1n/2` rejection/acceptance.
- Homestead DELEGATECALL state tests (`msg.sender`/`msg.value` preservation and gas behavior) using `stDelegatecallTestHomestead` fixtures.
- Homestead contract-creation OOG-at-code-deposit tests ensuring no empty account is left (`stHomesteadSpecific/contractCreationOOGdontLeaveEmptyContract*`).
- Homestead refund-cap tests proving `min(refund_counter, gas_used/2)` instead of London’s 1/5 rule.
- Fork-boundary tests around block 1,150,000 showing Frontier->Homestead behavior changes (opcode/gas/validation).

### Fork - tangerine_whistle (`fork-tangerine_whistle`)
- Intrinsic gas test for non-zero calldata bytes at Tangerine Whistle (68 gas/byte).
- Refund-cap test for pre-London behavior: refund <= gas_used/2 (not /5).
- CALL/CALLCODE/DELEGATECALL/CREATE 63/64 forwarding boundary tests (`d64-1`, `d64`, `d64+1`).
- Opcode repricing tests for BALANCE=400, EXTCODESIZE/EXTCODECOPY=700, SLOAD=200 under Tangerine Whistle.
- SELFDESTRUCT gas tests for Tangerine semantics (5000 base, +25000 on dead beneficiary, including zero-balance edge cases pre-Spurious).
- CALL-to-nonexistent-account gas tests that distinguish pre-Spurious account existence rules from later alive semantics.
- Execution of canonical state-test suites: `stEIP150Specific`, `stEIP150singleCodeGasPrices`, `stMemExpandingEIP150Calls`.
- CI coverage for an external state-tests runner at `tests/external/state_tests_runner.zig` (currently absent).

### Fork - spurious_dragon (`fork-spurious_dragon`)
- Spurious Dragon intrinsic gas with non-zero calldata byte priced at 68 (and create intrinsic +32000).
- EIP-155 sender recovery and validation paths (`v/r/s` checks, low-s rule, chain-id encoded `v`).
- Reject tx from sender account that has deployed code (InvalidSender behavior).
- Gas refund cap enforcement at 1/2 of gas used (pre-London), including SSTORE and SELFDESTRUCT refund scenarios.
- EIP-161 touched-empty-account destruction after transaction execution.
- EIP-170 contract code size limit (`0x6000`) with OOG-on-exceed behavior for contract creation.
- Opcode availability under Spurious Dragon: `CHAINID`/`SELFBALANCE`/`BASEFEE`/`BLOB*` and `CREATE2` must be invalid.
- Block processing path asserting that over-gas or otherwise invalid included transactions invalidate the block path (not silently dropped).
- Execution-spec state vectors for Spurious Dragon via an external state-test runner.

### Fork - byzantium (`fork-byzantium`)
- Fork-selection test proving execution runs with Byzantium (and rejects post-Byzantium opcodes such as `CHAINID`/`PUSH0` in this mode).
- Intrinsic gas tests for Byzantium calldata pricing (68 gas per non-zero byte).
- Refund-cap tests for Byzantium 50% rule (`gas_used_before_refund / 2`).
- Byzantium opcode behavior tests for `REVERT`, `RETURNDATASIZE`, `RETURNDATACOPY`, and `STATICCALL` edge cases.
- EIP-196/197/198 precompile correctness and gas-cost tests.
- Receipt bloom construction tests from actual emitted logs.
- Block-level Byzantium tests for difficulty calculation (including bomb delay) and miner/ommer rewards.
- Execution-spec/GeneralStateTests integration for Byzantium fixtures.

### Fork - constantinople (`fork-constantinople`)
- Constantinople intrinsic gas tests: non-zero calldata byte must cost 68 gas (not 16).
- Pre-London refund-cap tests: `tx_gas_refund = min(refund_counter, gas_used/2)`.
- Fork-gating tests that assert post-Constantinople opcodes (for example `PUSH0`) are invalid under Constantinople.
- EXTCODEHASH matrix tests: non-existent account => `0`; existing empty-code account => `keccak256("")`; contract account => `keccak256(code)`.
- CREATE2 tests for deterministic address derivation and hashcost (`GAS_CREATE + GAS_KECCAK256_PER_WORD * ceil(init_code_len/32)`).
- EIP-1234 tests for block reward = 2 ETH and difficulty bomb delay = 5,000,000 blocks.
- Execution-spec Constantinople state fixtures wired through an active `tests/external/state_tests_runner.zig` in this worktree.

### Fork - istanbul (`fork-istanbul`)
- Fork activation test ensuring execution uses ISTANBUL rules at block 9,069,000 (and pre-Istanbul behavior before it).
- Refund quotient test proving `min(refund_counter, gas_used_before_refund/2)` for Istanbul transactions.
- CHAINID opcode boundary tests (invalid pre-Istanbul, valid Istanbul+, gas=2).
- EIP-1884 repricing tests for `SLOAD=800`, `BALANCE=700`, `EXTCODEHASH=700` under Istanbul.
- EIP-2200 SSTORE matrix tests (original/current/new combinations, sentry gas check, refund counter cases).
- EIP-1108 precompile gas tests for BN254 add/mul/pairing costs (`150/6000/45000+34000*n`).
- EIP-152 BLAKE2F tests for address `0x09`, input length=213, gas per round=1.
- Precompile-set boundary test: at Istanbul, `0x09` is precompile and `0x0A` is not.

### Fork - berlin (`fork-berlin`)
- Type-1 (EIP-2930) transaction decoding/encoding and receipt prefix (`0x01`) handling.
- Intrinsic gas calculation for access lists: +2400 per address and +1900 per storage key.
- Access-list prewarming effects on `BALANCE`, `EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`, `SLOAD`, and `CALL*` gas costs.
- Precompile prewarming checks (Berlin set) at transaction start.
- `SELFDESTRUCT` Berlin cold-beneficiary surcharge behavior.
- Berlin refund cap behavior (`min(refund_counter, gas_used/2)`) vs other forks.
- Berlin opcode gating against post-Berlin opcodes (e.g., `BASEFEE`, `PUSH0`, `TLOAD/TSTORE`).
- Sender recovery/signature validation and non-EOA sender rejection path.
- Nonce overflow bound validation (`nonce < 2^64`).
- End-to-end Berlin external state test execution (GeneralStateTests / execution-spec Berlin fixture families).

### Fork - london (`fork-london`)
- Type-2 (EIP-1559) transaction validity across fork boundary (invalid pre-London, valid at/after London).
- Max-fee/priority-fee checks: `max_fee_per_gas >= base_fee_per_gas` and `max_priority_fee_per_gas <= max_fee_per_gas`.
- Effective gas price accounting: sender charge/refund, base-fee burn, and tip-only miner payment.
- Header validation/base-fee transition cases: initial base fee, parent gas target increase/decrease formula, and invalid header rejection.
- BASEFEE opcode behavior under correct hardfork gating and block-context value propagation.
- EIP-3529 refund behavior validation for London (refund cap and storage-clear refund interactions).
- EIP-3541 contract deployment rejection for runtime code starting with `0xEF`.
- EIP-3554 difficulty-bomb delay / difficulty transition checks for London-era blocks.
- Hardfork-gating tests ensuring post-London opcodes/semantics are not active when executing London blocks.
- Automated execution-spec London state test integration in CI (or equivalent runner).

### Fork - paris (`fork-paris`)
- Reject block headers with non-zero `difficulty`, non-zero `nonce`, or non-empty `ommers` under Paris.
- Reject legacy transactions where `gas_price < block_base_fee`.
- Validate EIP-1559 transaction checks (`max_fee_per_gas`, `max_priority_fee_per_gas`, effective gas price) and state transitions.
- Validate EIP-2930 intrinsic gas accounting for access-list addresses/storage keys.
- Assert coinbase receives only priority fee and base fee is not transferred to coinbase.
- Assert opcode `0x44` returns `block_prevrandao` in Paris execution context.
- Assert post-Paris opcodes (for example `PUSH0`) are rejected when executing with Paris hardfork rules.
- End-to-end execution-spec-tests Paris fixtures via `tests/external/state_tests_runner.zig`.

### Fork - shanghai (`fork-shanghai`)
- EIP-3651: warm-coinbase gas differential tests (e.g., `EXTCODESIZE`/`EXTCODECOPY`/`EXTCODEHASH` against `block.coinbase`).
- EIP-3855: PUSH0 execution tests in zevm integration, including fork-gated invalidity before Shanghai.
- EIP-3860: intrinsic gas tests for contract-creation tx including `init_code_cost = 2 * ceil(len(initcode)/32)`.
- EIP-3860: tx-validation tests that reject create txs with initcode length > 49152 before execution/inclusion.
- EIP-4895: withdrawals application tests (balance credits, zero/large amount edge cases, and withdrawals trie root/header validation).
- Fork-selection tests ensuring Shanghai semantics (not Cancun/Prague semantics) for the same block context/timestamp.

### Fork - cancun (`fork-cancun`)
- Run Cancun execution-spec suites for `lib/execution-specs/tests/cancun/{eip1153_tstore,eip5656_mcopy,eip7516_blobgasfee,eip6780_selfdestruct}`.
- Add EIP-4844 type-3 transaction tests: no-blob rejection, invalid versioned hash, `max_fee_per_blob_gas` check, and per-block blob gas limit.
- Add EIP-4788 pre-body system transaction test (beacon roots contract call before user tx execution).
- Add BLOBHASH tests with non-empty blob hash lists plus out-of-bounds behavior.
- Add BLOBBASEFEE tests driven by `excess_blob_gas`/blob base-fee calculation path.
- Add gas-settlement tests verifying base-fee burn vs coinbase priority fee only.
- Add fork-selection tests to enforce Cancun semantics (and reject Prague-only behavior) when replaying Cancun fixtures.
- Restore/relocate `tests/external/state_tests_runner.zig` into the active tree and run it in CI.

### Fork - prague (`fork-prague`)
- Type-4 (EIP-7702) transaction decode/validation/execution and typed receipt encoding.
- Authorization list edge cases: empty list rejection, chain-id=0 handling, invalid signature handling, authority nonce mismatch, and existing-account refund behavior.
- Delegation execution semantics: delegated code lookup, precompile-disable behavior, and delegated cold/warm access gas in `CALL`/`CALLCODE`/`DELEGATECALL`/`STATICCALL`.
- EIP-7623 calldata floor pricing cases where execution gas used is below floor, including zero/nonzero calldata mixes and create-vs-call cases.
- EIP-1559/Prague fee settlement checks: base-fee burn vs priority-fee coinbase payment.
- Prague blob gas constraints (EIP-7691): per-block cap/target behavior and excess blob gas evolution.
- EIP-7685 request processing: deposit log extraction, request ordering, and request-hash computation.
- System transaction hooks for beacon roots/history storage/withdrawal and consolidation request predeploy calls.
- Cross-client Prague state fixtures (external state tests) wired into CI/pass-fail gating.

---

## Review: execution-apis

_chunks=11 avgConform=5 avgCov=13 issues=69 crit=10_

# execution-apis Spec Review

## Executive Summary
- Total chunks: 11
- Average conformance: 4.55 (rounded field value: 5)
- Average test coverage: 12.82 (rounded field value: 13)
- Issue counts: 10 critical, 52 major, 7 minor, 0 nit (69 total)
- Systemic blocker: runtime server starts with an empty handler registry, so known methods fall through to `-32601` (`src/main.zig:20`, `src/rpc/dispatcher.zig:18-20`)

## Top Risks
1. [critical] Production dispatch is disconnected across eth/debug/engine due null `on_method`; known methods return `Method not found` (`src/main.zig:20`, `src/rpc/dispatcher.zig:18-20`).
2. [critical] Required Engine API method `engine_exchangeCapabilities` is missing in runtime behavior (`lib/execution-apis/src/engine/common.md:145`, `src/main.zig:20`, `src/rpc/dispatcher.zig:18`).
3. [major] Engine parser misses declared methods (`engine_forkchoiceUpdatedV4`, `engine_getBlobsV3`, `engine_getClientVersionV1`, `engine_getPayloadBodiesByHashV2`, `engine_getPayloadBodiesByRangeV2`) (`/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/engine/methods.zig:137`).
4. [major] Transaction fidelity risk: `eth_getTransactionByHash` is stubbed null and receipt log `topics`/`data` are dropped (`src/rpc/handlers/block_query_handlers.zig:119`, `src/rpc/handlers/block_query_handlers.zig:242`).
5. [major] State correctness risk: `eth_getCode` always returns `0x`; `eth_getStorageAt` parse/encoding is non-spec (`src/rpc/handlers/eth_read.zig:49`, `src/rpc/handlers/eth_read.zig:60`).
6. [major] Execute methods lack method-specific validation and error mapping, including revert code `3` and simulate error sets (`src/rpc/dispatcher.zig:32`).
7. [major] CI blind spot: key handler tests are outside the default test graph (`src/rpc/root.zig:6`, `src/rpc/root.zig:10`).

## Foreign Feature Gaps
- Snapshot and rollback controls missing: `anvil_snapshot`, `anvil_revert`, `anvil_reorg`, `anvil_rollback` (foundry `crates/anvil/core/src/eth/mod.rs`).
- Mining and automine/time controls missing: `anvil_mine`, `anvil_setAutomine`, `anvil_setIntervalMining`, `hardhat_mine`, `hardhat_getAutomine`, timestamp controls (foundry `.../eth/mod.rs`; edr `crates/edr_provider/src/requests/methods.rs`).
- Impersonation workflows missing: `anvil_impersonateAccount` and stop, `hardhat_impersonateAccount` and stop/auto (foundry `.../eth/mod.rs`; edr `.../methods.rs`).
- State mutation RPC surface largely missing from routed methods: `setBalance`, `setCode`, `setNonce`, `setStorageAt`, `setCoinbase`, `setMinGasPrice`, `setNextBlockBaseFeePerGas`, `setPrevRandao` and aliases; zevm has partial helpers but no public routing (`src/rpc/dev_handlers.zig`, `src/rpc/dispatcher.zig:68`).
- Txpool controls missing: `dropTransaction`, `dropAllTransactions`, `removePoolTransactions` (foundry `crates/anvil/src/eth/api.rs`; edr `.../methods.rs`).
- Metadata/blob/introspection endpoints missing: `anvil_nodeInfo`, `anvil_metadata`, `hardhat_metadata`, `anvil_getBlobByHash`, `anvil_getBlobsByTransactionHash` (foundry `.../eth/mod.rs`; edr `.../methods.rs`).
- Signing parity gaps: `personal_sign` and typed-data family `eth_signTypedData_v4` are absent (foundry `crates/anvil/src/eth/api.rs`; hardhat `v-next/.../local-accounts.ts`; edr `.../methods.rs`).

## Per-Chunk Findings
### eth — block.yaml (eth-block)
- Conformance: 12
- Test coverage: 26
- Summary: all seven block methods are recognized but non-functional in live runtime; helper code is partial and unreachable.
Issues:
- [critical/conformance] server starts with empty RPC handler registry (`src/main.zig:20`).
- [major/conformance] block methods are not wired to runtime dispatch (`src/rpc/dispatcher.zig:18`).
- [major/conformance] `eth_getBlockTransactionCountBy*` and `eth_getUncleCountBy*` RPC implementations are missing (`src/rpc/block_queries.zig:138`).
- [major/conformance] `eth_getBlockReceipts` hash selector not supported (`src/rpc/block_queries.zig:92`).
- [major/conformance] block transaction payloads use placeholder values (`src/rpc/block_queries.zig:229`).
- [major/conformance] pruned-history error code `4444` not implemented.
- [major/test-coverage] no end-to-end success-path tests for block methods (`src/rpc/server_test.zig:30`).
- [major/test-coverage] handler tests miss field-level correctness assertions (`src/rpc/handlers/block_query_handlers_test.zig:58`).
- [major/missing-feature] broad `anvil_*` / `hardhat_*` dev RPC parity gap (`src/rpc/router.zig:60`).

### eth — state.yaml (eth-state)
- Conformance: 10
- Test coverage: 22
- Summary: none of the five state methods are wired in active runtime; helper layer exists for four methods but is incomplete.
Issues:
- [critical/conformance] state methods not wired in active RPC server (`src/main.zig:20`).
- [major/conformance] no `eth_getProof` handler (`src/rpc/handlers/eth_read.zig`).
- [major/conformance] `eth_getCode` returns `0x` unconditionally (`src/rpc/handlers/eth_read.zig:49`).
- [major/conformance] `eth_getStorageAt` parse fallback/encoding is non-spec (`src/rpc/handlers/eth_read.zig:60`).
- [major/conformance] block selector omits hash/object form (`src/rpc/handlers/block_spec.zig:13`).
- [major/test-coverage] no end-to-end success tests for state methods (`src/rpc/server_test.zig`).
- [minor/test-coverage] `eth_read_test` not in default `zig build test` graph (`src/rpc/root.zig:6`).
- [major/missing-feature] Hardhat/Anvil extension routing is minimal (`src/rpc/dispatcher.zig:68`).

### eth — execute.yaml (eth-execute)
- Conformance: 0
- Test coverage: 5
- Summary: `eth_call`, `eth_estimateGas`, `eth_createAccessList`, and `eth_simulateV1` are not implemented end-to-end in active path.
Issues:
- [critical/conformance] all execute methods return `MethodNotFound` in runtime (`src/main.zig:20`).
- [major/conformance] legacy router path is also effectively unimplemented (`src/rpc/handlers.zig:38`).
- [major/conformance] method-specific param/error contracts are not implemented (`src/rpc/dispatcher.zig:32`).
- [major/test-coverage] no tests cover execute methods (`src/rpc/dispatcher_test.zig:35`).
- [major/test-coverage] potential execute handlers/tests are not in default test graph (`src/rpc/root.zig:6`).
- [major/missing-feature] reference hardhat and anvil dev-execution methods are largely missing (`src/rpc/dispatcher.zig:68`).

### eth — transaction.yaml (eth-transaction)
- Conformance: 5
- Test coverage: 7
- Summary: transaction methods are not wired in live runtime; existing handler code is partial and contains stubs/fidelity gaps.
Issues:
- [critical/conformance] transaction methods are not wired into active execution path (`src/main.zig:20`).
- [major/conformance] no implementation for block-hash/index and block-number/index transaction lookups.
- [major/conformance] `eth_getTransactionByHash` is hardcoded stub (`src/rpc/handlers/block_query_handlers.zig:119`).
- [major/conformance] receipt conversion drops log `data` and `topics` (`src/rpc/handlers/block_query_handlers.zig:242`).
- [minor/conformance] spec pruned-history error `4444` not implemented (`src/rpc/handlers/block_query_handlers.zig:63`).
- [major/test-coverage] default RPC test suite excludes transaction handler module tests (`src/rpc/root.zig:6`).
- [major/test-coverage] transaction tests only cover narrow null-path unit cases (`src/rpc/handlers/block_query_handlers_test.zig:158`).
- [minor/missing-feature] tx-pool management RPC parity is missing (`src/rpc/router.zig:60`).

### eth — fee_market.yaml (eth-fee_market)
- Conformance: 5
- Test coverage: 5
- Summary: all four fee-market methods return `-32601` in active runtime; detached fee handlers exist but `eth_feeHistory` is spec-incomplete.
Issues:
- [critical/conformance] fee-market methods are not wired into runtime server (`src/main.zig:20`).
- [major/conformance] `eth_feeHistory` logic is spec-incomplete (`src/rpc/handlers/eth_read.zig:125`).
- [major/test-coverage] fee-market tests are outside default test graph (`src/rpc/root.zig:6`).
- [major/test-coverage] no end-to-end HTTP/dispatcher tests for fee methods (`src/rpc/server_test.zig:30`).
- [major/missing-feature] missing anvil/hardhat fee-control extensions (`src/rpc/dispatcher.zig:68`).

### eth — filter.yaml (eth-filter)
- Conformance: 5
- Test coverage: 20
- Summary: none of the seven filter methods are wired in active runtime; internal `eth_getLogs` exists but is unreachable.
Issues:
- [critical/conformance] filter methods are not wired in active server (`src/main.zig:20`).
- [major/conformance] `eth_getLogs` handler is unreachable and currently swallows query errors (`src/rpc/handlers/block_query_handlers.zig:98`).
- [major/test-coverage] no RPC-level coverage for filter methods (`src/rpc/server_test.zig`).
- [minor/missing-feature] Hardhat/Anvil dev-method compatibility is far behind references (`src/rpc/dispatcher.zig:68`).

### eth - sign.yaml (eth-sign)
- Conformance: 0
- Test coverage: 10
- Summary: `eth_sign` and `eth_signTransaction` are declared but not implemented in active runtime path.
Issues:
- [critical/conformance] sign methods are not implemented/wired (`src/main.zig:20`).
- [major/conformance] dispatcher recognizes names but has no sign-method execution path (`src/rpc/dispatcher.zig:32`).
- [major/test-coverage] no direct tests for sign methods (`src/rpc/dispatcher_test.zig:35`).
- [major/missing-feature] sign-adjacent parity gaps vs references (`src/rpc/dispatcher.zig:68`).

### eth — submit.yaml (eth-submit)
- Conformance: 0
- Test coverage: 12
- Summary: submit methods are recognized but unreachable in active runtime, despite existing handler code.
Issues:
- [critical/conformance] `eth_sendTransaction` and `eth_sendRawTransaction` not wired in active server (`/Users/williamcory/zevm/src/main.zig:20`).
- [major/conformance] submit handlers exist but are unreachable dead code (`/Users/williamcory/zevm/src/rpc/handlers/tx_submission.zig:22`).
- [major/test-coverage] no RPC-level tests for submit methods (`/Users/williamcory/zevm/src/rpc/server_test.zig:30`).
- [major/test-coverage] submit handler tests are not in default graph (`/Users/williamcory/zevm/src/rpc/root.zig:6`).
- [major/missing-feature] Anvil/Hardhat compatibility surface is much smaller than references (`/Users/williamcory/zevm/src/rpc/dispatcher.zig:68`).

### eth — client.yaml (eth-client)
- Conformance: 5
- Test coverage: 12
- Summary: four client methods have detached handlers not used by live server; `eth_syncing` missing and `net_version` unrecognized.
Issues:
- [critical/conformance] production RPC server has no registered method handler (`src/main.zig:20`).
- [major/conformance] existing client handlers are unreachable in live path (`src/rpc/handlers/eth_read.zig:23`).
- [major/conformance] `eth_syncing` missing implementation (`src/rpc/dispatcher.zig:32`).
- [major/conformance] `net_version` not recognized by dispatcher/router (`src/rpc/dispatcher.zig:65`).
- [major/test-coverage] no end-to-end tests for client methods on active wiring (`src/rpc/server_test.zig:30`).
- [minor/test-coverage] detached handler/router tests are outside RPC root imports (`src/rpc/root.zig:6`).
- [major/missing-feature] substantial anvil/hardhat compatibility gap (`src/rpc/router.zig:60`).

### debug (debug-)
- Conformance: 0
- Test coverage: 8
- Summary: all five debug getter methods return `-32601` in active runtime.
Issues:
- [major/conformance] all spec-declared debug methods are effectively unimplemented (`src/rpc/dispatcher.zig:47`).
- [major/conformance] runtime starts with empty handler registry (`src/main.zig:20`).
- [major/conformance] fallback handler layer always returns `MethodNotFound` (`src/rpc/handlers.zig:49`).
- [major/test-coverage] no tests assert debug spec behavior (`src/rpc/dispatcher_test.zig:35`).
- [minor/test-coverage] some RPC tests are not part of default aggregation (`src/rpc/root.zig:6`).
- [major/missing-feature] reference hardhat and anvil developer RPC surface is largely missing (`src/rpc/dispatcher.zig:68`).

### engine (engine-)
- Conformance: 8
- Test coverage: 14
- Summary: recognized engine methods still return `-32601`; required method support is missing and parser coverage is incomplete.
Issues:
- [critical/conformance] `engine_exchangeCapabilities` is required by spec but returns `MethodNotFound` (`lib/execution-apis/src/engine/common.md:145`, `src/main.zig:20`, `src/rpc/dispatcher.zig:18`).
- [major/conformance] all recognized engine methods are stubbed to `MethodNotFound` in active runtime (`src/rpc/dispatcher.zig:51`, `src/main.zig:20`).
- [major/conformance] five spec-declared engine methods are not recognized by parser (`/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/engine/methods.zig:137`).
- [major/test-coverage] no tests validate engine spec semantics (`src/rpc/dispatcher_test.zig:66`, `src/rpc/server_test.zig:118`).
- [minor/test-coverage] router-level engine tests are not in default test graph (`src/rpc/root.zig:10`, `src/rpc/router_test.zig:1`).
- [major/missing-feature] reference anvil/hardhat compatibility surface is largely missing (`src/rpc/dispatcher.zig:68`, `src/rpc/router.zig:59`).
- [major/missing-feature] `dev_handlers` implementations are unreachable from active runtime (`src/rpc/dev_handlers.zig:31`, `src/main.zig:20`).

## Missing Tests
### eth — block.yaml (eth-block)
- End-to-end HTTP JSON-RPC tests for each block method: `eth_getBlockByHash`, `eth_getBlockByNumber`, `eth_getBlockTransactionCountByHash`, `eth_getBlockTransactionCountByNumber`, `eth_getUncleCountByBlockHash`, `eth_getUncleCountByBlockNumber`, `eth_getBlockReceipts` returning success responses.
- Production wiring test proving `src/main.zig` registers an `on_method` dispatcher instead of booting with empty handlers.
- RPC-layer tests for `eth_getBlockTransactionCountByHash` and `eth_getBlockTransactionCountByNumber` including not-found to `null`.
- RPC-layer tests for `eth_getUncleCountByBlockHash` and `eth_getUncleCountByBlockNumber`.
- `eth_getBlockReceipts` test with block-hash selector and not-found hash behavior.
- Field-accuracy tests for hydrated and non-hydrated block transactions, ensuring real tx hashes/objects and no placeholders.
- Pruned-history error-path test asserting code `4444` where applicable.

### eth — state.yaml (eth-state)
- HTTP-level success-path tests for `eth_getBalance`, `eth_getStorageAt`, `eth_getTransactionCount`, `eth_getCode`, `eth_getProof` through active server wiring.
- `eth_getProof` correctness tests for account proof and storage proofs, empty/non-empty key arrays, and missing account behavior.
- `eth_getCode` tests asserting non-empty bytecode is returned as DATA hex, not always `0x`.
- `eth_getStorageAt` tests for 32-byte DATA formatting and invalid-slot param rejection.
- Block selector tests for `BlockNumberOrTagOrHash` object/hash form, not only tags/quantities.
- Build-integrated import path so `src/rpc/handlers/eth_read_test.zig` runs under `zig build test`.

### eth — execute.yaml (eth-execute)
- `eth_call` success path returns bytes with explicit block and default block.
- `eth_call` revert path returns code `3` with raw revert bytes in `error.data`.
- `eth_estimateGas` success path returns quantity and handles revert with code `3`.
- `eth_createAccessList` returns object shape `{accessList,error?,gasUsed}`.
- `eth_simulateV1` success path over multi-call payload, including default block tag behavior.
- `eth_simulateV1` documented error-code mapping: `-32000`, `-32602`, `-32005`, `-32015`, `-32016`, `-32603`, `-38010..-38026`.
- End-to-end test through `main -> server -> dispatcher` proving execute methods are wired to real handlers.
- Invalid-params tests (`-32602`) for each execute method required parameters.

### eth — transaction.yaml (eth-transaction)
- End-to-end server/dispatcher test proving `eth_getTransactionByHash` returns `TransactionInfo` for a mined transaction.
- End-to-end server/dispatcher test proving `eth_getTransactionByHash` returns `null`, not `-32601`, for unknown hash.
- End-to-end tests for `eth_getTransactionByBlockHashAndIndex` success and not-found behavior.
- End-to-end tests for `eth_getTransactionByBlockNumberAndIndex` success and not-found behavior for hex number and tags.
- Receipt tests validating full log payload mapping, including `topics` and `data`, for `eth_getTransactionReceipt`.
- Tests for spec-defined `4444 Pruned history unavailable` behavior on applicable methods.
- Wiring test that production startup registers non-null RPC dispatcher callbacks for eth methods.

### eth — fee_market.yaml (eth-fee_market)
- Integration wiring test with real server path proving `eth_gasPrice`, `eth_blobBaseFee`, `eth_maxPriorityFeePerGas`, `eth_feeHistory` are not `-32601`.
- HTTP JSON-RPC success test for `eth_gasPrice` with empty params and omitted params.
- HTTP JSON-RPC success test for `eth_blobBaseFee` with empty params and omitted params.
- HTTP JSON-RPC success test for `eth_maxPriorityFeePerGas` with empty params and omitted params.
- HTTP JSON-RPC success test for `eth_feeHistory` with full three-arg input and schema-shaped response.
- Validation tests for malformed `blockCount`, malformed `newestBlock`, malformed or non-monotonic `rewardPercentiles`, returning `-32602`.
- Test-harness inclusion check ensuring `src/rpc/handlers/eth_read_test.zig` is imported by root test tree or equivalent CI entrypoint.

### eth — filter.yaml (eth-filter)
- End-to-end JSON-RPC test for `eth_newFilter` returning a valid filter ID.
- End-to-end JSON-RPC test for `eth_newBlockFilter` plus `eth_getFilterChanges` returning new block hashes.
- End-to-end JSON-RPC test for `eth_newPendingTransactionFilter` plus `eth_getFilterChanges` returning pending tx hashes.
- End-to-end JSON-RPC test for `eth_getFilterLogs` returning full matched history for an existing filter ID.
- End-to-end JSON-RPC test for `eth_uninstallFilter` true/false semantics for existing vs unknown filter ID.
- End-to-end JSON-RPC tests for `eth_getLogs` covering block range, `blockHash`, address array, topic OR, and wildcard semantics.
- Error-path test for `eth_getLogs` pruned history unavailable with spec code `4444`.
- Unknown and expired filter-ID tests for `eth_getFilterChanges` and `eth_getFilterLogs` semantics.

### eth - sign.yaml (eth-sign)
- `eth_sign` returns a 65-byte EIP-191 signature for managed account and valid message bytes.
- `eth_sign` rejects unmanaged or unknown signer accounts with deterministic JSON-RPC error mapping.
- `eth_sign` validates param shape and types (`address`, `bytes`) and rejects malformed payloads.
- `eth_signTransaction` signs a valid `GenericTransaction` and returns RLP-encoded bytes.
- `eth_signTransaction` covers missing or invalid `from` and tx-field edge cases across legacy and typed forms.
- Integration test through `server.handleHttpRequestForTest` and startup wiring proving methods do not return `-32601` once implemented.

### eth — submit.yaml (eth-submit)
- HTTP JSON-RPC test: `eth_sendRawTransaction` valid signed tx returns tx hash and enqueues or mines transaction.
- HTTP JSON-RPC test: `eth_sendRawTransaction` error mapping for nonce mismatch, insufficient balance, intrinsic gas, and chain-id mismatch.
- HTTP JSON-RPC test: `eth_sendTransaction` signs managed account tx and returns hash.
- HTTP JSON-RPC test: `eth_sendTransaction` from unmanaged account returns expected JSON-RPC error.
- Wire `src/rpc/handlers/tx_submission_test.zig` into default test entrypoint so submit logic runs in CI.
- Spec-behavior tests for EIP-4844 and EIP-7594 raw submission handling described in `submit.yaml`.

### eth — client.yaml (eth-client)
- HTTP integration test proving `eth_chainId` returns configured chain ID via production handler registry.
- HTTP integration test proving `eth_blockNumber` returns canonical head via production handler registry.
- HTTP integration tests for `eth_coinbase` and `eth_accounts` through live dispatch path.
- `eth_syncing` tests for both schema variants: `false` and syncing progress object.
- `net_version` test proving decimal network ID string output and method recognition.
- Startup and wiring test ensuring `main` registers non-null RPC handler callback for server dispatch.

### debug (debug-)
- End-to-end test for `debug_getRawHeader` returning RLP bytes for valid block inputs, including genesis, explicit number, and tags.
- End-to-end test for `debug_getRawBlock` returning full block RLP bytes.
- End-to-end test for `debug_getRawTransaction` returning EIP-2718 raw transaction bytes by tx hash.
- End-to-end test for `debug_getRawReceipts` returning array of raw receipt bytes.
- Success-shape test for `debug_getBadBlocks` returning expected bad block object fields.
- Negative tests for spec-defined pruned-history behavior with code `4444` where applicable.
- Invalid-params tests for all five debug methods in active server and dispatcher path.

### engine (engine-)
- `engine_exchangeCapabilities` success behavior, returning supported method set and excluding itself.
- Success-path tests for every engine method version: `newPayload*`, `forkchoiceUpdated*`, `getPayload*`, `getBlobs*`, `getPayloadBodies*`, `getClientVersionV1`, `exchangeTransitionConfigurationV1`.
- Engine-specific invalid-params and fork-gating error tests: `-32602`, `-38002`, `-38003`, `-38004`, `-38005` per spec version.
- Coverage verifying all declared engine methods are recognized or intentionally rejected, including V4/V2/V3 additions and identification API.
- Ensure router and dev handler tests are included in default test target or provide an equivalent integrated RPC test target.

---

## Review: consensus-specs

_chunks=6 avgConform=37 avgCov=19 issues=37 crit=4_

# consensus-specs Spec Review

## Executive Summary
- Total chunks: 6
- Average conformance: 37/100 (raw: 36.83)
- Average test coverage: 19/100 (raw: 18.50)
- Issues: 37 total
- Severity split: critical 4, major 29, minor 4, nit 0
- Overall: Core light-client pieces exist, but fork-aware header/proof correctness, Electra support, liveness mechanics, and protocol-level tests are materially incomplete.

## Top Risks
1. [critical] Fork-incompatible execution header hashing/validation (missing `extra_data`, fixed field set) can reject valid proofs across Bellatrix/Capella/Deneb/Electra (`src/consensus_verifier.zig`, `src/consensus_verifier.zig:405`).
2. [critical] Electra committee/finality proof verification is pinned to pre-Electra gindices/depths, so valid Electra payloads can fail (`src/consensus_verifier.zig:95`, `src/beacon_api.zig:297`).
3. [major] No `best_valid_update` ranking plus timeout force-update fallback, weakening liveness during prolonged non-finality (`src/consensus_verifier.zig:266`, `../voltaire/packages/voltaire-zig/src/primitives/LightClientUpdate/LightClientUpdate.zig:216`).
4. [major] Near-head sync path does not process optimistic updates, diverging from sync-protocol behavior (`src/consensus_sync.zig:107`).
5. [major] Beacon API parsing is not fork-aware for Bellatrix/Capella/Deneb/Electra payload shapes and branch depths (`src/beacon_api.zig:342`, `src/beacon_api.zig:360`, `src/beacon_api.zig:297`).
6. [major] Critical verifier/sync/parser protocol paths are largely untested (`src/consensus_verifier_test.zig`, `src/consensus_sync_test.zig`, `src/beacon_api_test.zig`).

## Foreign Feature Gaps
- Per-chunk inputs did not provide concrete foundry, hardhat, and edr (or other foreign implementation) deltas.
- Consolidated foreign feature gaps reported in this review: none.

## Per-Chunk Findings

### Altair — sync committees (cl-altair)
- Conformance: 42
- Test coverage: 22
- Summary: Core sync-committee checks are present, but key Altair sync-protocol behavior is missing (best-update/force-update, optimistic updates, known-next-committee consistency), and header handling is stricter than Altair wire semantics.
- Issues:
- [major/conformance] Missing best-update ranking and force-update semantics (`src/consensus_verifier.zig:266`)
- [major/conformance] No equality check against known next sync committee (`src/consensus_verifier.zig:174`)
- [major/conformance] Header validation is stricter than Altair and not Altair-wire compatible (`src/beacon_api.zig:342`)
- [minor/conformance] Genesis finality zero-root special case is not modeled (`src/consensus_verifier.zig:156`)
- [major/conformance] Sync loop does not process optimistic updates (`src/consensus_sync.zig:107`)
- [major/test-coverage] Validation state machine is untested (`src/consensus_verifier_test.zig`)
- [major/test-coverage] Consensus sync engine behavior is barely tested (`src/consensus_sync_test.zig`)
- [minor/test-coverage] Beacon API parser coverage is partial (`src/beacon_api_test.zig`)

### Bellatrix — beacon-chain merge (cl-bellatrix)
- Conformance: 55
- Test coverage: 25
- Summary: Direct merge-era light-client surface is limited, but execution payload parsing/hashing is not Bellatrix-compatible.
- Issues:
- [critical/conformance] Execution payload header root construction is not Bellatrix-compatible (`src/consensus_verifier.zig`)
- [major/conformance] Beacon API parser requires post-Bellatrix execution fields and cannot parse Bellatrix headers (`src/beacon_api.zig`)
- [major/test-coverage] Cryptographic update verification paths are untested (`src/consensus_verifier_test.zig`)
- [major/test-coverage] No tests prove bootstrap/updates/finality parsing and sync-engine network flow (`src/beacon_api_test.zig`)

### Capella — withdrawals (cl-capella)
- Conformance: 32
- Test coverage: 18
- Summary: `withdrawals_root` is propagated, but execution-header hashing/parsing and pre-Capella compatibility behavior diverge from spec.
- Issues:
- [critical/conformance] Execution header root computation omits `extra_data` (`src/consensus_verifier.zig:405`)
- [major/conformance] Capella parsing is mixed with Deneb-only fields (`src/beacon_api.zig:360`)
- [major/conformance] Pre-Capella light-client header rules are not implemented (`src/consensus_verifier.zig:75`)
- [major/test-coverage] Verification path for execution proof is untested (`src/consensus_verifier_test.zig`)
- [major/test-coverage] Beacon API parser coverage is too narrow for Capella correctness (`src/beacon_api_test.zig`)

### Deneb — blob transactions (cl-deneb)
- Conformance: 32
- Test coverage: 18
- Summary: Blob fields are partially implemented, but header validity/hashing is not fork-accurate.
- Issues:
- [major/conformance] Execution payload header root omits `extra_data` in proof hashing path (`src/consensus_verifier.zig:405`)
- [major/conformance] Missing fork-aware light-client header validity logic for Deneb blob fields (`src/consensus_verifier.zig:85`)
- [major/conformance] Beacon API execution header parsing is Deneb-only and not full header shape (`src/beacon_api.zig:360`)
- [major/test-coverage] No verifier tests for fork-boundary execution-header validity (`src/consensus_verifier_test.zig`)
- [minor/test-coverage] Parser tests do not assert blob field semantics (`src/beacon_api_test.zig:79`)

### Electra — operations / committees (cl-electra)
- Conformance: 25
- Test coverage: 10
- Summary: Full beacon-node operations are out of scope, but Electra light-client committee/finality proof semantics are not correctly implemented.
- Issues:
- [critical/conformance] Committee/finality proof checks are pinned to pre-Electra generalized indices (`src/consensus_verifier.zig:95`)
- [major/conformance] JSON parsing enforces pre-Electra branch lengths (`src/beacon_api.zig:297`)
- [major/conformance] No pre-Electra-to-Electra branch normalization path (`src/consensus_sync.zig:271`)
- [major/test-coverage] Verifier proof paths are untested (`src/consensus_verifier_test.zig`)
- [major/test-coverage] API parser tests do not cover bootstrap/update/finality branch depth rules (`src/beacon_api_test.zig`)

### Light client (across phases) (cl-light-client)
- Conformance: 35
- Test coverage: 18
- Summary: zevm has a light-client subset, but diverges on liveness/state-machine behavior and cross-phase compatibility.
- Issues:
- [critical/conformance] Execution header validation/hash is not fork-aware and omits required data (`src/consensus_verifier.zig:405`)
- [major/conformance] Optimistic update flow is not integrated (`src/consensus_sync.zig:107`)
- [major/conformance] No best-valid-update tracking or force-update fallback (`../voltaire/packages/voltaire-zig/src/primitives/LightClientUpdate/LightClientUpdate.zig:216`)
- [major/conformance] Electra generalized-index/depth changes are unsupported (`src/beacon_api.zig:297`)
- [major/conformance] Update range fetch behavior deviates from spec sync-process windows (`src/consensus_sync.zig:209`)
- [minor/conformance] Known next sync committee consistency check is missing (`src/consensus_verifier.zig:174`)
- [major/conformance] Update decoding cannot represent spec absent fields via zero-branch sentinels (`src/beacon_api.zig:301`)
- [major/test-coverage] Verifier validation paths are untested (`src/consensus_verifier_test.zig:98`)
- [major/test-coverage] Sync-engine protocol behavior is untested (`src/consensus_sync_test.zig:24`)
- [major/test-coverage] Beacon API parser coverage misses core objects and edge cases (`src/beacon_api_test.zig:39`)

## Missing Tests

### Altair — sync committees (cl-altair)
- Positive `verifyUpdate` case for a valid in-period update signed by the current sync committee (including merkle branches and signature).
- Positive `verifyUpdate` case for period+1 signatures when `store.next_sync_committee` is known.
- Negative `verifyUpdate` case where `update_attested_period == store_period` and provided `next_sync_committee` differs from `store.next_sync_committee`.
- Genesis finality edge case: `finalized_header` empty at `GENESIS_SLOT` with zero finalized root proof.
- Negative-path matrix for `verifyBootstrap`/`verifyUpdate` (invalid current/next committee proofs, invalid finality proof, invalid timestamp/period/relevance, invalid signature).
- State-machine tests for best-update ranking (`is_better_update`) and timeout-driven `process_light_client_store_force_update` behavior.
- `ConsensusSyncEngine` integration tests with mocked Beacon API covering bootstrap, per-period updates, finality updates, optimistic updates, and checkpoint advancement.
- Beacon API parser tests for bootstrap, updates-by-range, and finality-update payloads (including malformed response shapes).

### Bellatrix — beacon-chain merge (cl-bellatrix)
- `verifyBootstrap` with known-good Bellatrix vectors (execution payload proof + current sync committee proof).
- `verifyBootstrap` negative cases: invalid execution payload proof, invalid committee branch, checkpoint hash mismatch.
- `verifyUpdate` with Bellatrix-formatted execution headers (includes `extra_data`, excludes withdrawals/blob gas fields).
- `verifyUpdate` signature and fork-domain boundary tests around Bellatrix fork epoch/version.
- Beacon API parsing tests for bootstrap/updates/finality responses using Bellatrix-shaped headers.
- `ConsensusSyncEngine` integration tests with mocked Beacon API for bootstrap/sync/advance paths and checkpoint updates.

### Capella — withdrawals (cl-capella)
- `verifyBootstrap`/`verifyUpdate` success tests using spec-shaped Capella headers where execution root includes `extra_data` and `withdrawals_root`.
- Negative proof tests that mutate `withdrawals_root` and `execution_branch` and assert `InvalidExecutionPayloadProof`.
- Beacon API parser tests for bootstrap/finality/updates using canonical Capella execution headers (`extra_data` present, no Deneb blob fields).
- Fork-compatibility tests for pre-Capella headers (zero execution header + zero execution branch) as required by Capella light-client transition rules.
- Transition tests for processing upgraded pre-Capella light-client objects in a Capella store.

### Deneb — blob transactions (cl-deneb)
- Fork-aware light-client header validation tests for pre-Capella, Capella, and Deneb slots.
- Negative tests that reject pre-Deneb headers with non-zero `blob_gas_used`/`excess_blob_gas`.
- Execution payload proof tests using canonical SSZ roots including `extra_data` and blob fields.
- Beacon API parsing tests asserting `blob_gas_used`/`excess_blob_gas` values are preserved.
- Compatibility tests for pre-Deneb (Capella-format) headers upgraded into Deneb local format.

### Electra — operations / committees (cl-electra)
- Parse Electra bootstrap responses with `current_sync_committee_branch` depth 6 (and reject wrong depths).
- Parse Electra light-client updates with `next_sync_committee_branch` depth 6 and `finality_branch` depth 7.
- Verify proof validation switches generalized indices at `ELECTRA_FORK_EPOCH` (pre-fork and post-fork cases).
- Verify bootstrap/update acceptance against valid Electra vectors and rejection against invalid committee/finality proofs.
- Exercise pre-Electra-to-Electra branch normalization (`normalize_merkle_branch`) when an Electra store processes pre-Electra data.
- End-to-end `ConsensusSyncEngine` flow using Electra-shaped bootstrap/update/finality payloads.

### Light client (across phases) (cl-light-client)
- `verifyBootstrap` success/failure cases for header root and current sync committee proof validation.
- `verifyUpdate` negative/positive tests for timestamp/period/relevance checks and BLS signature verification.
- `verifyUpdate` test for required equality with known `next_sync_committee` when attested period matches store period.
- `sync`/`advance` integration tests proving both finality and optimistic update processing near head.
- Timeout/liveness tests for best-valid-update ranking plus force-update fallback behavior.
- Parsing tests for `LightClientUpdate`/`LightClientFinalityUpdate`/`LightClientBootstrap` including zero-branch sentinel handling.
- Cross-phase tests for execution-header root validation across Capella/Deneb/Electra (including `extra_data`, blob fields).
- Electra branch-depth/generalized-index tests for finalized/current/next committee proofs.

---

## Aggregate Summary

- **54** total chunks reviewed across 5 specs
- **341** total issues, **58** critical

- **Review: EIPs** — chunks=14 avgConform=40 avgCov=14 issues=64 crit=12
- **Review: Yellow Paper** — chunks=10 avgConform=30 avgCov=24 issues=72 crit=12
- **Review: execution-specs (forks)** — chunks=13 avgConform=25 avgCov=12 issues=99 crit=20
- **Review: execution-apis** — chunks=11 avgConform=5 avgCov=13 issues=69 crit=10
- **Review: consensus-specs** — chunks=6 avgConform=37 avgCov=19 issues=37 crit=4
