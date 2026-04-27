# Agent J — `src/rpc/handlers/tx_submission.zig`

## Scope
Replaced the legacy-only submission path with a full typed-envelope decoder, EIP-3860 initcode cap, and a complete intrinsic-gas formula (calldata + initcode words + access list + auth list). Wired the `.eip2930` branch into all helpers. Automine now forwards the decoded typed envelope intact for the matching pool entry rather than re-encoding it as a degenerate legacy.

## What landed

### Typed envelope decoding
- New `DecodedEnvelope` union with `.legacy` / `.eip2930` / `.eip1559` / `.eip4844` / `.eip7702`.
- Inline `Eip2930Transaction` struct (voltaire's `Transaction` module is missing this type — a follow-up should add it upstream).
- First-byte dispatch: `>= 0xc0` → legacy, `0x01..0x04` → typed.
- All decoders implemented inline using `primitives.Rlp.decode`. Helpers: `rlpAsList`, `rlpAsString`, `rlpToU64/U256/Fixed32`, `rlpToOptionalAddress`, `rlpToAddress`, `rlpToHash32`, `decodeAccessList`, `decodeAuthorizationList`.
- For EIP-4844 we accept either canonical envelope (14-field RLP list) or the network form (`[tx_payload, blobs, commitments, proofs]`) and silently strip the sidecar — only canonical fields are validated.

### Signing-hash + sender recovery
- Per-type signing payloads, hashed with `keccak256(type_byte || rlp(body))` for typed and `keccak256(rlp(body))` for legacy (the legacy payload uses the EIP-155 trailer via `encodeLegacyForSigning(tx, chain_id)` with v=r=s=0).
- I had to inline 1559/4844/7702 signing encoders because voltaire's `encodeEip4844ForSigning` and `encodeEip7702ForSigning` reference `tx.v` on structs whose signature field is named `y_parity` — that's broken upstream and would not compile if invoked. Logged below.
- Sender recovery via `crypto.Crypto.unaudited_recoverAddress` after rebuilding `Signature{ r, s, v = recovery_id + 27 }`. Legacy `v` is normalized through `legacyRecoveryId` (handles EIP-155, 27/28, and 0/1).

### EIP-3860 initcode cap
- `MAX_INITCODE_SIZE = 49152`. Create-tx (`to == null`) with `data.len > 49152` → `TxSubmissionError.InitcodeTooLarge` (mapped to `-32000` upstream).

### Intrinsic gas
- 21000 base, +32000 if create, +4/zero +16/nonzero calldata byte, +2 per ceil(initcode/32) words on create, +2400 per access-list address, +1900 per access-list slot, +25000 per authorization tuple. Implemented in `computeIntrinsicGas`.

### Balance check
- `value + max_fee * gas_limit` (saturating) plus, for EIP-4844, `max_fee_per_blob_gas * 131072 * blob_count`.

### Automine path
- `automine` now takes the freshly-decoded envelope and the recovered sender. It forwards the typed envelope intact for the matching `(sender, nonce)` pool entry via `legacyShapeFromEnvelope` (which preserves to/value/data/gas semantics). Other pool entries fall back to the prior placeholder shape — that's a separate gap (the pool itself doesn't store the original envelope; see "skipped" below).

### `eth_sendTransaction`
- Per task spec, returns `TxSubmissionError.UnmanagedAccount` immediately. The dispatcher should surface this as `-32601` and the previous managed-signing implementation has been deleted.

## Skipped / known gaps

- **KZG sidecar verification (EIP-4844):** decoder strips the sidecar if present and only validates the canonical envelope. No proof / commitment math.
- **Voltaire upstream bugs:** `encodeEip4844ForSigning` (line 570) and `encodeEip7702ForSigning` (line 674) of `voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig` reference `tx.v` on structs with a `y_parity` field. They will not compile if invoked. Filed inline encoders here as a workaround; voltaire should be patched. Voltaire also lacks an `Eip2930Transaction` struct entirely and any `decodeRawTransaction` / `recoverSender` / `validateChainId` helpers — the existing handler was referencing nonexistent identifiers.
- **Pool/runtime wiring:** the file still calls `rt.pool.{setNonce, add, getReady, removeMined}` and `rt.mining_mode`. Neither field exists on `runtime.NodeRuntime` today; per the task brief, other agents are landing those in disjoint files. Once they do, the typed envelope wiring here will light up. Until then this file remains uncompilable (it already was — `primitives.Transaction.decodeRawTransaction` and friends were all stubs that never existed).
- **Pool envelope retention:** because the pool entry shape is `{sender, nonce, gas_limit, max_fee_per_gas, max_priority_fee_per_gas, hash}`, the typed envelope is only preserved for the most-recent submission inside `automine`. A real fix needs the pool to store the raw bytes or the decoded envelope; flagged as a follow-up.
- **Hardfork awareness:** EIP-3860 cap and initcode-word gas are applied unconditionally. Per task brief that's acceptable for current mainnet (Shanghai+). Pre-Shanghai semantics will need a hardfork gate when historical fixtures are exercised.
- **No tests written / no `zig build` run** per task constraints.

## Files touched
- `/Users/williamcory/zevm/src/rpc/handlers/tx_submission.zig` (rewritten)
