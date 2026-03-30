# Context: Implement Voltaire Raw Transaction Decoding

## Ticket Summary
**Title:** Add raw signed transaction decode and sender recovery
**Description:** Implement raw envelope decoding for legacy, EIP-2930, EIP-1559, EIP-4844, and EIP-7702 in Voltaire primitives, including signature recovery and chain-id validation, plus execution-apis vector tests.

## Reference Paths and Summaries

### 1. `../voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig`
**Summary:** Currently defines transaction structs (`LegacyTransaction`, `Eip1559Transaction`, `Eip4844Transaction`, `Eip7702Transaction`) and basic methods like type detection (`detectTransactionType`), hashing, and encoding for signing (`encode*ForSigning`). However, it completely lacks the `decode` functions necessary to take an RLP-encoded raw transaction payload, parse the envelope, extract signature components (`v`, `r`, `s` / `y_parity`, `r`, `s`), recover the sender address via ECDSA (secp256k1), and validate the `chain_id`. These need to be implemented here.

### 2. `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/sendRawTransaction/eth_sendRawTransaction.zig`
**Summary:** Defines the JSON-RPC interface and parameter structure for the `eth_sendRawTransaction` method. Once decoding is implemented in `Transaction.zig`, this handler will need to be updated to parse the `types.Quantity` (hex encoded bytes) into a fully typed transaction structure.

### 3. EIP Specifications (`EIPs/EIPS/`)
- `https://eips.ethereum.org/EIPS/eip-1559`, `https://eips.ethereum.org/EIPS/eip-2930`, `https://eips.ethereum.org/EIPS/eip-4844`, `https://eips.ethereum.org/EIPS/eip-7702`
**Summary:** Provide the definitive specifications for the typed transaction envelopes. We must rigorously implement envelope type prefixes (`0x01`, `0x02`, `0x03`, `0x04`) and standard RLP parsing for each type.

### 4. `ethereum-tests/TransactionTests/`
**Summary:** Contains a massive suite of JSON vector tests (200+ files) categorized by transaction aspects (`ttWrongRLP`, `ttValue`, `ttSignature`, etc.). We will use these to validate our decoding and signature recovery robustness against edge cases.

### 5. `execution-apis/docs-api/api/methods/eth_sendRawTransaction.mdx`
**Summary:** Contains execution-apis behavioral definitions for `eth_sendRawTransaction` and RPC expectations.