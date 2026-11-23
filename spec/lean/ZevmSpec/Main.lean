import ZevmSpec.ConsensusMath
import ZevmSpec.RlpTx
import ZevmSpec.Evm

/-!
# `zevm-spec` batch CLI

Line protocol used by `tools/lean_diff_fuzz.zig`. The process reads one request
per stdin line, writes exactly one response line, flushes stdout, and exits 0
on EOF.

```
BLOB_FEE <fork> <target> <max> <fraction> <parentExcess> <parentUsed> <parentBaseFee>
    -> OK <blobBaseFee> <nextExcess>
BASE_FEE <parentBaseFee> <parentGasUsed> <parentGasLimit>
    -> OK <nextBaseFee> | ERR
EFFECTIVE_GAS <fork> <execGas> <refund> <zeroBytes> <nonZeroBytes>
    -> OK <gas>
RLP_DECODE <hex>
    -> OK bytes <len> | OK list <count> | ERR
TX_DECODE <hex>
    -> OK <txType> <nonce> <gasLimit> <wrapperTag> | ERR
MODEXP <fork> <gasLimit> <hex>
    -> OK <gasUsed> <outHex> | ERR
EVM_EXEC <fork> <gasLimit> <codeHex> <calldataHex>
    -> OK <0|1> <gasUsed> <outHex>
```

Numbers are decimal. Hex is unprefixed lowercase; the empty byte string is `-`.
A malformed request (unknown command, wrong arity, bad number, bad hex, unknown
fork) answers `ERR`, so the request and response streams never lose alignment.
-/

namespace ZevmSpec.Cli

open ZevmSpec

/-- Splits a request line into its non-empty whitespace-separated tokens. -/
def tokenize (line : String) : List String :=
  let step (acc : List String × List Char) (c : Char) : List String × List Char :=
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' then
      if acc.2.isEmpty then acc else (String.ofList acc.2.reverse :: acc.1, [])
    else
      (acc.1, c :: acc.2)
  let (toks, cur) := line.toList.foldl step ([], [])
  let toks := if cur.isEmpty then toks else String.ofList cur.reverse :: toks
  toks.reverse

/-- Parses a hex argument. `-` is the empty byte string; a `0x` prefix is tolerated. -/
def parseHex (tok : String) : Option ByteArray :=
  if tok == "-" then
    some ByteArray.empty
  else
    let chars := tok.toList
    let body :=
      match chars with
      | '0' :: 'x' :: rest => String.ofList rest
      | '0' :: 'X' :: rest => String.ofList rest
      | _ => tok
    match hexToBytes body with
    | .ok bytes => some bytes
    | .error _ => none

/-- Renders bytes as unprefixed hex, with `-` for the empty byte string. -/
def renderHex (bytes : ByteArray) : String :=
  if bytes.size == 0 then
    "-"
  else
    match (bytesToHex bytes).toList with
    | '0' :: 'x' :: rest => String.ofList rest
    | chars => String.ofList chars

def handleBlobFee (args : List String) : Option String := do
  let [fork, target, max, fraction, parentExcess, parentUsed, parentBaseFee] := args | none
  let fork ← Hardfork.ofString? fork
  let target ← target.toNat?
  let max ← max.toNat?
  let fraction ← fraction.toNat?
  let parentExcess ← parentExcess.toNat?
  let parentUsed ← parentUsed.toNat?
  let parentBaseFee ← parentBaseFee.toNat?
  let blobBaseFee := fakeExponentialU256 1 parentExcess fraction
  let nextExcess := calcExcessBlobGas fork target max fraction parentExcess parentUsed parentBaseFee
  pure s!"OK {blobBaseFee} {nextExcess}"

def handleBaseFee (args : List String) : Option String := do
  let [parentBaseFee, parentGasUsed, parentGasLimit] := args | none
  let parentBaseFee ← parentBaseFee.toNat?
  let parentGasUsed ← parentGasUsed.toNat?
  let parentGasLimit ← parentGasLimit.toNat?
  let next ← expectedBaseFeePerGas parentBaseFee parentGasUsed parentGasLimit
  pure s!"OK {next}"

def handleEffectiveGas (args : List String) : Option String := do
  let [fork, execGas, refund, zeroBytes, nonZeroBytes] := args | none
  let fork ← Hardfork.ofString? fork
  let execGas ← execGas.toNat?
  let refund ← refund.toNat?
  let zeroBytes ← zeroBytes.toNat?
  let nonZeroBytes ← nonZeroBytes.toNat?
  pure s!"OK {effectiveGasUsed fork execGas refund zeroBytes nonZeroBytes}"

def handleRlpDecode (args : List String) : Option String := do
  let [hex] := args | none
  let input ← parseHex hex
  match rlpDecode input with
  | .ok (RlpItem.bytes data) => pure s!"OK bytes {data.size}"
  | .ok (RlpItem.list items) => pure s!"OK list {items.size}"
  | .error _ => none

def handleTxDecode (args : List String) : Option String := do
  let [hex] := args | none
  let raw ← parseHex hex
  match decodeTxSummary raw with
  | .ok tx => pure s!"OK {tx.txType} {tx.nonce} {tx.gasLimit} {tx.wrapperTag}"
  | .error _ => none

def handleModexp (args : List String) : Option String := do
  let [fork, gasLimit, hex] := args | none
  let fork ← Hardfork.ofString? fork
  let gasLimit ← gasLimit.toNat?
  let input ← parseHex hex
  match modexpSpec fork input gasLimit with
  | .ok result => pure s!"OK {result.gasUsed} {renderHex result.output}"
  | .error _ => none

def handleEvmExec (args : List String) : Option String := do
  let [fork, gasLimit, codeHex, calldataHex] := args | none
  let fork ← Hardfork.ofString? fork
  let gasLimit ← gasLimit.toNat?
  let code ← parseHex codeHex
  let calldata ← parseHex calldataHex
  let result := execEvm fork code calldata gasLimit
  let flag := if result.success then "1" else "0"
  pure s!"OK {flag} {result.gasUsed} {renderHex result.output}"

/-- Maps one request line to its response line (without the trailing newline). -/
def respond (line : String) : String :=
  let answer : Option String :=
    match tokenize line with
    | "BLOB_FEE" :: args => handleBlobFee args
    | "BASE_FEE" :: args => handleBaseFee args
    | "EFFECTIVE_GAS" :: args => handleEffectiveGas args
    | "RLP_DECODE" :: args => handleRlpDecode args
    | "TX_DECODE" :: args => handleTxDecode args
    | "MODEXP" :: args => handleModexp args
    | "EVM_EXEC" :: args => handleEvmExec args
    | _ => none
  answer.getD "ERR"

end ZevmSpec.Cli

def main : IO UInt32 := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  repeat
    let line ← stdin.getLine
    -- `getLine` returns the empty string only at EOF; a blank line is "\n".
    if line.isEmpty then break
    stdout.putStrLn (ZevmSpec.Cli.respond line)
    stdout.flush
  return 0
