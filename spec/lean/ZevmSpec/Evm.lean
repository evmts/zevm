/-
  ZevmSpec.Evm: pure-math reference specification for

    * CLZ (EIP-7939),
    * the MODEXP precompile (EIP-198, EIP-2565, EIP-7823, EIP-7883),
    * a single-frame 256-bit EVM interpreter (Yellow Paper, Appendix H).

  Every value is an unbounded `Nat`; 256-bit wrapping is explicit (`% 2^256`).
  There are no machine-width caps, so the definitions follow the specs and not
  any implementation limit (u32 offsets, 16 MiB memory caps, u64 saturation).

  Result conventions of `execEvm`:
    * normal halt (STOP, RETURN, running off the code): `success = true`,
      `gasUsed = gasLimit - gasLeft`.
    * REVERT: `success = false`, `gasUsed = gasLimit - gasLeft`, output = revert data.
    * exceptional halt (out of gas, stack under/overflow, invalid jump,
      invalid or unsupported opcode): `success = false`, `gasUsed = gasLimit`,
      empty output.
-/
import ZevmSpec.ConsensusMath

namespace ZevmSpec

/-! ## CLZ (EIP-7939) -/

/-- Number of leading zero bits of `x` in its 256-bit representation. -/
def clz256 (x : Nat) : Nat :=
  if x = 0 then 256 else 255 - Nat.log2 x

theorem clz256_zero : clz256 0 = 256 := by
  simp [clz256]

theorem clz256_le_256 (x : Nat) : clz256 x ≤ 256 := by
  unfold clz256
  split <;> omega

/-- Exactness: for a nonzero 256-bit `x`, the top set bit is bit `255 - clz256 x`. -/
theorem clz256_spec (x : Nat) (h0 : x ≠ 0) (h : x < 2 ^ 256) :
    2 ^ (255 - clz256 x) ≤ x ∧ x < 2 ^ (256 - clz256 x) := by
  have hl : x.log2 < 256 := (Nat.log2_lt h0).2 h
  have e1 : 255 - (255 - x.log2) = x.log2 := by omega
  have e2 : 256 - (255 - x.log2) = x.log2 + 1 := by omega
  simp only [clz256, h0, if_false, e1, e2]
  exact ⟨Nat.log2_self_le h0, Nat.lt_log2_self⟩

/-- A nonzero 256-bit value has fewer than 256 leading zeros. -/
theorem clz256_lt_256 (x : Nat) (h0 : x ≠ 0) : clz256 x < 256 := by
  simp only [clz256, h0, if_false]
  omega

namespace Evm

/-! ## Byte helpers -/

/-- 2^256. -/
def WORD : Nat := 2 ^ 256

/-- Byte `i` of `b` as a `Nat`; 0 past the end. -/
def byteAt (b : ByteArray) (i : Nat) : Nat :=
  if h : i < b.size then b[i].toNat else 0

/-- `n` zero bytes. -/
def zeros (n : Nat) : ByteArray :=
  Nat.repeat (fun b => b.push 0) n ByteArray.empty

/-- Big-endian value of `b[start .. start+len)`, reading 0 past the end. -/
def beNatAux (b : ByteArray) : Nat → Nat → Nat → Nat
  | 0, _, acc => acc
  | n + 1, i, acc => beNatAux b n (i + 1) (acc * 256 + byteAt b i)

/-- Big-endian value of `b[start .. start+len)` with the input right-padded
    with zeros. Only the available bytes are folded, so `len` may be huge. -/
def beNat (b : ByteArray) (start len : Nat) : Nat :=
  let avail := if start < b.size then min len (b.size - start) else 0
  beNatAux b avail start 0 <<< (8 * (len - avail))

/-- Big-endian encoding of `v % 256^len` in exactly `len` bytes. -/
def natToBE : Nat → Nat → ByteArray → ByteArray
  | 0, _, acc => acc
  | n + 1, v, acc => natToBE n v (acc.push (UInt8.ofNat ((v >>> (8 * n)) % 256)))

/-- `src[off .. off+len)` right-padded with zeros to exactly `len` bytes. -/
def slicePadded (src : ByteArray) (off len : Nat) : ByteArray :=
  let avail := if off < src.size then min len (src.size - off) else 0
  if avail = 0 then zeros len
  else src.extract off (off + avail) ++ zeros (len - avail)

/-- Exact modular exponentiation by square-and-multiply. `fuel` = bit length of `e`. -/
def powModAux (m : Nat) : Nat → Nat → Nat → Nat → Nat
  | 0, _, _, acc => acc
  | f + 1, b, e, acc =>
    if e = 0 then acc
    else powModAux m f (b * b % m) (e / 2) (if e % 2 = 1 then acc * b % m else acc)

/-- `b^e mod m`, with `powMod _ _ 0 = 0` and `powMod _ 0 1 = 0`. -/
def powMod (b e m : Nat) : Nat :=
  if m = 0 then 0 else powModAux m (Nat.log2 e + 1) (b % m) e (1 % m)

/-! ## MODEXP gas -/

/-- EIP-198 multiplication complexity (Byzantium through Istanbul). -/
def modexpComplexity198 (x : Nat) : Nat :=
  if x ≤ 64 then x * x
  else if x ≤ 1024 then x * x / 4 + 96 * x - 3072
  else x * x / 16 + 480 * x - 199680

/-- Iteration count. `expHead` is the value of the first `min expLen 32`
    exponent bytes; `mult` is 8 (EIP-198/2565) or 16 (EIP-7883). -/
def modexpIterations (expLen expHead mult : Nat) : Nat :=
  let headBits := if expHead = 0 then 0 else Nat.log2 expHead + 1
  let headIter := headBits - 1
  let adjusted := if expLen ≤ 32 then headIter else mult * (expLen - 32) + headIter
  max adjusted 1

/-- Gas required by MODEXP for the given fork. -/
def modexpGas (fork : Hardfork) (baseLen expLen modLen expHead : Nat) : Nat :=
  let maxLen := max baseLen modLen
  let words := (maxLen + 7) / 8
  if fork.isAtLeast .osaka then
    -- EIP-7883: minimum 500, no /3 divisor, 16x long-exponent multiplier,
    -- complexity 16 up to 32 bytes and 2*words^2 above.
    let complexity := if maxLen ≤ 32 then 16 else 2 * words * words
    max 500 (complexity * modexpIterations expLen expHead 16)
  else if fork.isAtLeast .berlin then
    -- EIP-2565
    max 200 (words * words * modexpIterations expLen expHead 8 / 3)
  else
    -- EIP-198
    modexpComplexity198 maxLen * modexpIterations expLen expHead 8 / 20

end Evm

/-- `ByteArray` has no core `Repr`; this one is local so it cannot clash with
    an instance from another module. -/
local instance Evm.instReprByteArray : Repr ByteArray := ⟨fun b _ => repr b.toList⟩

/-! ## MODEXP precompile (address 0x05) -/

structure ModExpResult where
  gasUsed : Nat
  output : ByteArray
  deriving Repr, BEq

/-- MODEXP. Input is right-padded with zeros. `Except.error` is an exceptional
    halt of the precompile call (all forwarded gas is consumed):
    `"InvalidInput"` for an EIP-7823 length violation, `"OutOfGas"` otherwise. -/
def modexpSpec (fork : Hardfork) (input : ByteArray) (gasLimit : Nat) : Except String ModExpResult :=
  let baseLen := Evm.beNat input 0 32
  let expLen := Evm.beNat input 32 32
  let modLen := Evm.beNat input 64 32
  -- EIP-7823: checked before gas and before every empty-output shortcut.
  if fork.isAtLeast .osaka && (baseLen > 1024 || expLen > 1024 || modLen > 1024) then
    .error "InvalidInput"
  else
    let expStart := 96 + baseLen
    let expHead := Evm.beNat input expStart (min expLen 32)
    let gas := Evm.modexpGas fork baseLen expLen modLen expHead
    if gasLimit < gas then .error "OutOfGas"
    else if modLen = 0 then .ok { gasUsed := gas, output := ByteArray.empty }
    else
      let m := Evm.beNat input (expStart + expLen) modLen
      if m = 0 then .ok { gasUsed := gas, output := Evm.zeros modLen }
      else
        let b := Evm.beNat input 96 baseLen
        let e := Evm.beNat input expStart expLen
        .ok { gasUsed := gas, output := Evm.natToBE modLen (Evm.powMod b e m) ByteArray.empty }

/-! ## EVM interpreter -/

structure EvmExecResult where
  success : Bool
  gasUsed : Nat
  output : ByteArray
  deriving Repr, BEq

namespace Evm

/-- Interpreter state. `stack` has its top at the head. `mem.size` is always a
    multiple of 32 and equals the active memory size in bytes (MSIZE). -/
structure State where
  pc : Nat
  gas : Nat
  stack : List Nat
  mem : ByteArray

/-- Outcome of one instruction. Exceptional halts are `none` at the call site. -/
inductive StepOut where
  | next (s : State)
  | halt (success : Bool) (gasLeft : Nat) (output : ByteArray)

/-- Outcome of a whole execution. -/
inductive RunOut where
  | exceptional
  | halted (success : Bool) (gasLeft : Nat) (output : ByteArray)

/-- Valid JUMPDEST positions: 0x5b bytes that are not PUSH immediates. -/
def jumpdestsAux (code : ByteArray) : Nat → Nat → Array Bool → Array Bool
  | 0, _, acc => acc
  | fuel + 1, pc, acc =>
    if pc ≥ code.size then acc
    else
      let op := byteAt code pc
      if op = 0x5b then jumpdestsAux code fuel (pc + 1) (acc.setIfInBounds pc true)
      else if 0x60 ≤ op ∧ op ≤ 0x7f then jumpdestsAux code fuel (pc + 1 + (op - 0x5f)) acc
      else jumpdestsAux code fuel (pc + 1) acc

def jumpdests (code : ByteArray) : Array Bool :=
  jumpdestsAux code code.size 0 (Array.replicate code.size false)

/-- Total memory cost for `words` 32-byte words: `3w + w^2 / 512`. -/
def memCost (words : Nat) : Nat := 3 * words + words * words / 512

/-- Gas to grow active memory from `curSize` bytes to cover `endByte`. -/
def expansionCost (curSize endByte : Nat) : Nat :=
  let newWords := (endByte + 31) / 32
  let curWords := curSize / 32
  if newWords ≤ curWords then 0 else memCost newWords - memCost curWords

/-- Grow memory with zeros to the word boundary covering `endByte`. -/
def expandMem (mem : ByteArray) (endByte : Nat) : ByteArray :=
  let need := (endByte + 31) / 32 * 32
  if need ≤ mem.size then mem else mem ++ zeros (need - mem.size)

/-- Overwrite `mem[off .. off+data.size)`. The range must already be active. -/
def writeMem (mem : ByteArray) (off : Nat) (data : ByteArray) : ByteArray :=
  if data.size = 0 then mem else data.copySlice 0 mem off data.size

/-- Deduct gas; `none` is out of gas. -/
def charge (s : State) (cost : Nat) : Option State :=
  if cost ≤ s.gas then some { s with gas := s.gas - cost } else none

/-- Charge `cost` plus memory expansion for `[off, off+len)` and grow memory.
    A zero-length range never expands memory, whatever `off` is. -/
def touchMem (s : State) (cost off len : Nat) : Option State :=
  if len = 0 then charge s cost
  else do
    let s ← charge s (cost + expansionCost s.mem.size (off + len))
    pure { s with mem := expandMem s.mem (off + len) }

/-- Push with the 1024-item limit, then advance `pc` by `width`. -/
def pushAdv (s : State) (v width : Nat) : Option StepOut :=
  if s.stack.length < 1024 then
    some (.next { s with stack := v :: s.stack, pc := s.pc + width })
  else none

def op1 (s : State) (cost : Nat) (f : Nat → Nat) : Option StepOut := do
  let s ← charge s cost
  match s.stack with
  | a :: rest => pure (.next { s with stack := f a :: rest, pc := s.pc + 1 })
  | _ => none

def op2 (s : State) (cost : Nat) (f : Nat → Nat → Nat) : Option StepOut := do
  let s ← charge s cost
  match s.stack with
  | a :: b :: rest => pure (.next { s with stack := f a b :: rest, pc := s.pc + 1 })
  | _ => none

def op3 (s : State) (cost : Nat) (f : Nat → Nat → Nat → Nat) : Option StepOut := do
  let s ← charge s cost
  match s.stack with
  | a :: b :: c :: rest => pure (.next { s with stack := f a b c :: rest, pc := s.pc + 1 })
  | _ => none

/-- Charge and push a value that needs no operands. -/
def op0 (s : State) (cost : Nat) (f : State → Nat) : Option StepOut := do
  let s ← charge s cost
  pushAdv s (f s) 1

/-! ### Word arithmetic -/

def b2n (b : Bool) : Nat := if b then 1 else 0

/-- Two's-complement interpretation of a 256-bit word. -/
def toSigned (x : Nat) : Int :=
  if x < 2 ^ 255 then (x : Int) else (x : Int) - (WORD : Int)

/-- Two's-complement encoding of an integer as a 256-bit word. -/
def ofSigned (i : Int) : Nat := (i % (WORD : Int)).toNat

/-- SDIV: truncated signed division; x / 0 = 0; MIN / -1 = MIN by wrapping. -/
def sdiv (a b : Nat) : Nat :=
  if b = 0 then 0 else ofSigned (Int.tdiv (toSigned a) (toSigned b))

/-- SMOD: remainder with the sign of the dividend; x % 0 = 0. -/
def smod (a b : Nat) : Nat :=
  if b = 0 then 0 else ofSigned (Int.tmod (toSigned a) (toSigned b))

/-- SIGNEXTEND: extend the sign bit of byte `b` (0 = least significant) of `x`. -/
def signextend (b x : Nat) : Nat :=
  if b ≥ 31 then x
  else
    let bit := 8 * b + 7
    let low := x % 2 ^ (bit + 1)
    if low ≥ 2 ^ bit then low + (WORD - 2 ^ (bit + 1)) else low

/-- BYTE: byte `i` of `x`, 0 = most significant. -/
def byteOp (i x : Nat) : Nat :=
  if i ≥ 32 then 0 else (x >>> (8 * (31 - i))) % 256

def shl (shift v : Nat) : Nat := if shift ≥ 256 then 0 else (v <<< shift) % WORD

def shr (shift v : Nat) : Nat := if shift ≥ 256 then 0 else v >>> shift

/-- SAR: arithmetic shift right. For negative `v` this is NOT (NOT v >> shift). -/
def sar (shift v : Nat) : Nat :=
  if v < 2 ^ 255 then shr shift v
  else if shift ≥ 256 then WORD - 1
  else WORD - 1 - ((WORD - 1 - v) >>> shift)

/-- Byte length of the EXP exponent. -/
def expByteLen (e : Nat) : Nat := if e = 0 then 0 else Nat.log2 e / 8 + 1

/-! ### Instruction semantics -/

/-- CALLDATACOPY / CODECOPY: `dest, offset, len`. -/
def copyOp (s : State) (src : ByteArray) : Option StepOut :=
  match s.stack with
  | dest :: off :: len :: rest => do
    let s ← touchMem { s with stack := rest } (3 + 3 * ((len + 31) / 32)) dest len
    pure (.next { s with mem := writeMem s.mem dest (slicePadded src off len), pc := s.pc + 1 })
  | _ => none

/-- RETURN / REVERT: `offset, len`. -/
def haltOp (s : State) (success : Bool) : Option StepOut :=
  match s.stack with
  | off :: len :: _ => do
    let s ← touchMem s 0 off len
    pure (.halt success s.gas (if len = 0 then ByteArray.empty else s.mem.extract off (off + len)))
  | _ => none

/-- Execute the instruction at `s.pc` (requires `s.pc < code.size`).
    `none` is an exceptional halt. Opcodes that need state, environment, calls,
    logs or hashing are outside this spec and halt exceptionally. -/
def step (fork : Hardfork) (code calldata : ByteArray) (jd : Array Bool) (s : State) :
    Option StepOut :=
  let op := byteAt code s.pc
  if 0x60 ≤ op ∧ op ≤ 0x7f then do
    -- PUSH1..PUSH32; immediates past the end of code read as zero.
    let n := op - 0x5f
    let s ← charge s 3
    pushAdv s (beNat code (s.pc + 1) n) (1 + n)
  else if 0x80 ≤ op ∧ op ≤ 0x8f then do
    -- DUP1..DUP16
    let s ← charge s 3
    match s.stack[op - 0x80]? with
    | some v => pushAdv s v 1
    | none => none
  else if 0x90 ≤ op ∧ op ≤ 0x9f then do
    -- SWAP1..SWAP16
    let s ← charge s 3
    let n := op - 0x8f
    match s.stack with
    | top :: rest =>
      match rest[n - 1]? with
      | some v => pure (.next { s with stack := v :: rest.set (n - 1) top, pc := s.pc + 1 })
      | none => none
    | [] => none
  else
    match op with
    | 0x00 => some (.halt true s.gas ByteArray.empty)                    -- STOP
    | 0x01 => op2 s 3 fun a b => (a + b) % WORD                          -- ADD
    | 0x02 => op2 s 5 fun a b => (a * b) % WORD                          -- MUL
    | 0x03 => op2 s 3 fun a b => (a + WORD - b) % WORD                   -- SUB
    | 0x04 => op2 s 5 fun a b => if b = 0 then 0 else a / b              -- DIV
    | 0x05 => op2 s 5 sdiv                                               -- SDIV
    | 0x06 => op2 s 5 fun a b => if b = 0 then 0 else a % b              -- MOD
    | 0x07 => op2 s 5 smod                                               -- SMOD
    | 0x08 => op3 s 8 fun a b n => if n = 0 then 0 else (a + b) % n      -- ADDMOD
    | 0x09 => op3 s 8 fun a b n => if n = 0 then 0 else (a * b) % n      -- MULMOD
    | 0x0a =>                                                            -- EXP
      match s.stack with
      | base :: e :: rest => do
        -- EIP-160 (Spurious Dragon): 50 gas per exponent byte, 10 before.
        let perByte := if fork.isAtLeast .spuriousDragon then 50 else 10
        let s ← charge s (10 + perByte * expByteLen e)
        pure (.next { s with stack := powMod base e WORD :: rest, pc := s.pc + 1 })
      | _ => none
    | 0x0b => op2 s 5 signextend                                         -- SIGNEXTEND
    | 0x10 => op2 s 3 fun a b => b2n (a < b)                             -- LT
    | 0x11 => op2 s 3 fun a b => b2n (a > b)                             -- GT
    | 0x12 => op2 s 3 fun a b => b2n (toSigned a < toSigned b)           -- SLT
    | 0x13 => op2 s 3 fun a b => b2n (toSigned a > toSigned b)           -- SGT
    | 0x14 => op2 s 3 fun a b => b2n (a == b)                            -- EQ
    | 0x15 => op1 s 3 fun a => b2n (a == 0)                              -- ISZERO
    | 0x16 => op2 s 3 fun a b => a &&& b                                 -- AND
    | 0x17 => op2 s 3 fun a b => a ||| b                                 -- OR
    | 0x18 => op2 s 3 fun a b => a ^^^ b                                 -- XOR
    | 0x19 => op1 s 3 fun a => WORD - 1 - a                              -- NOT
    | 0x1a => op2 s 3 byteOp                                             -- BYTE
    | 0x1b => if fork.isAtLeast .constantinople then op2 s 3 shl else none   -- SHL (EIP-145)
    | 0x1c => if fork.isAtLeast .constantinople then op2 s 3 shr else none   -- SHR
    | 0x1d => if fork.isAtLeast .constantinople then op2 s 3 sar else none   -- SAR
    | 0x1e => if fork.isAtLeast .osaka then op1 s 5 clz256 else none         -- CLZ (EIP-7939)
    | 0x35 => op1 s 3 fun off => beNat calldata off 32                   -- CALLDATALOAD
    | 0x36 => op0 s 2 fun _ => calldata.size                             -- CALLDATASIZE
    | 0x37 => copyOp s calldata                                          -- CALLDATACOPY
    | 0x38 => op0 s 2 fun _ => code.size                                 -- CODESIZE
    | 0x39 => copyOp s code                                              -- CODECOPY
    | 0x50 => do                                                         -- POP
      let s ← charge s 2
      match s.stack with
      | _ :: rest => pure (.next { s with stack := rest, pc := s.pc + 1 })
      | [] => none
    | 0x51 =>                                                            -- MLOAD
      match s.stack with
      | off :: rest => do
        let s ← touchMem s 3 off 32
        pure (.next { s with stack := beNat s.mem off 32 :: rest, pc := s.pc + 1 })
      | [] => none
    | 0x52 =>                                                            -- MSTORE
      match s.stack with
      | off :: v :: rest => do
        let s ← touchMem { s with stack := rest } 3 off 32
        pure (.next { s with mem := writeMem s.mem off (natToBE 32 v ByteArray.empty),
                             pc := s.pc + 1 })
      | _ => none
    | 0x53 =>                                                            -- MSTORE8
      match s.stack with
      | off :: v :: rest => do
        let s ← touchMem { s with stack := rest } 3 off 1
        pure (.next { s with mem := writeMem s.mem off (natToBE 1 v ByteArray.empty),
                             pc := s.pc + 1 })
      | _ => none
    | 0x56 => do                                                         -- JUMP
      let s ← charge s 8
      match s.stack with
      | dest :: rest =>
        if jd.getD dest false then pure (.next { s with stack := rest, pc := dest }) else none
      | [] => none
    | 0x57 => do                                                         -- JUMPI
      let s ← charge s 10
      match s.stack with
      | dest :: cond :: rest =>
        if cond = 0 then pure (.next { s with stack := rest, pc := s.pc + 1 })
        else if jd.getD dest false then pure (.next { s with stack := rest, pc := dest })
        else none
      | _ => none
    | 0x58 => op0 s 2 fun s => s.pc                                      -- PC
    | 0x59 => op0 s 2 fun s => s.mem.size                                -- MSIZE
    | 0x5a => op0 s 2 fun s => s.gas                                     -- GAS (after its own 2)
    | 0x5b => do                                                         -- JUMPDEST
      let s ← charge s 1
      pure (.next { s with pc := s.pc + 1 })
    | 0x5e =>                                                            -- MCOPY (EIP-5656)
      if fork.isAtLeast .cancun then
        match s.stack with
        | dest :: src :: len :: rest => do
          let s ← touchMem { s with stack := rest } (3 + 3 * ((len + 31) / 32)) (max dest src) len
          let data := if len = 0 then ByteArray.empty else s.mem.extract src (src + len)
          pure (.next { s with mem := writeMem s.mem dest data, pc := s.pc + 1 })
        | _ => none
      else none
    | 0x5f =>                                                            -- PUSH0 (EIP-3855)
      if fork.isAtLeast .shanghai then op0 s 2 fun _ => 0 else none
    | 0xf3 => haltOp s true                                              -- RETURN
    | 0xfd => if fork.isAtLeast .byzantium then haltOp s false else none -- REVERT (EIP-140)
    | _ => none                                                          -- INVALID (0xfe) and the rest

/-- Run until halt. Every continuing instruction costs at least 1 gas, so
    `fuel = gasLimit + 1` is never exhausted before the machine halts. -/
def run (fork : Hardfork) (code calldata : ByteArray) (jd : Array Bool) : Nat → State → RunOut
  | 0, _ => .exceptional
  | fuel + 1, s =>
    if s.pc ≥ code.size then .halted true s.gas ByteArray.empty
    else
      match step fork code calldata jd s with
      | none => .exceptional
      | some (.halt ok gasLeft out) => .halted ok gasLeft out
      | some (.next s') => run fork code calldata jd fuel s'

end Evm

/-- Execute `code` in one frame with `calldata` and `gasLimit`. -/
def execEvm (fork : Hardfork) (code calldata : ByteArray) (gasLimit : Nat) : EvmExecResult :=
  match Evm.run fork code calldata (Evm.jumpdests code) (gasLimit + 1)
      { pc := 0, gas := gasLimit, stack := [], mem := ByteArray.empty } with
  | .exceptional => { success := false, gasUsed := gasLimit, output := ByteArray.empty }
  | .halted ok gasLeft out => { success := ok, gasUsed := gasLimit - gasLeft, output := out }

/-- Execution never reports more gas than it was given. -/
theorem execEvm_gasUsed_le (fork : Hardfork) (code calldata : ByteArray) (gasLimit : Nat) :
    (execEvm fork code calldata gasLimit).gasUsed ≤ gasLimit := by
  unfold execEvm
  split <;> simp

/-- `clz256 1 = 255` (only the least-significant bit is set). -/
theorem clz256_one : clz256 1 = 255 := by
  decide

/-- `clz256 (2^255) = 0` (the most-significant bit of a 256-bit word is set). -/
theorem clz256_top_bit : clz256 (2 ^ 255) = 0 := by
  unfold clz256
  have h0 : (2 ^ 255 : Nat) ≠ 0 := Nat.ne_of_gt (Nat.pow_pos (by decide))
  have hlog : Nat.log2 (2 ^ 255) = 255 := by
    have h1 : 2 ^ 255 ≤ 2 ^ 255 := Nat.le_refl _
    have h2 : 2 ^ 255 < 2 ^ (255 + 1) := by
      have : 2 ^ (255 + 1) = 2 ^ 255 * 2 := Nat.pow_succ 2 255
      omega
    have hge : 255 ≤ Nat.log2 (2 ^ 255) := (Nat.le_log2 h0).2 h1
    have hlt : Nat.log2 (2 ^ 255) < 256 := (Nat.log2_lt h0).2 h2
    omega
  simp [h0, hlog]

/-- Reading a byte at or past the end of a `ByteArray` always returns 0. -/
theorem byteAt_out_of_bounds (b : ByteArray) (i : Nat) (h : i ≥ b.size) :
    Evm.byteAt b i = 0 := by
  unfold Evm.byteAt
  have hnot : ¬ (i < b.size) := Nat.not_lt.mpr h
  simp [hnot]

/-- Every byte read via `Evm.byteAt` is strictly less than 256. -/
theorem byteAt_lt_256 (b : ByteArray) (i : Nat) :
    Evm.byteAt b i < 256 := by
  unfold Evm.byteAt
  split
  · exact UInt8.toNat_lt _
  · omega

/-- Modular exponentiation modulo 0 always yields 0. -/
theorem powMod_zero_mod (b e : Nat) : Evm.powMod b e 0 = 0 := by
  simp [Evm.powMod]

/-- `Evm.modexpIterations` is always at least 1 (preventing zero-iteration undercharge). -/
theorem modexpIterations_pos (expLen expHead mult : Nat) :
    Evm.modexpIterations expLen expHead mult ≥ 1 := by
  unfold Evm.modexpIterations
  exact Nat.le_max_right _ _

/-- EIP-7883 (Osaka): MODEXP always charges at least 500 gas. -/
theorem modexpGas_osaka_ge_500 (fork : Hardfork) (baseLen expLen modLen expHead : Nat)
    (h : fork.isAtLeast .osaka = true) :
    Evm.modexpGas fork baseLen expLen modLen expHead ≥ 500 := by
  unfold Evm.modexpGas
  simp only [h, ↓reduceIte]
  exact Nat.le_max_left _ _

/-- EIP-2565 / EIP-7883 (Berlin+): MODEXP always charges at least 200 gas. -/
theorem modexpGas_berlin_ge_200 (fork : Hardfork) (baseLen expLen modLen expHead : Nat)
    (h : fork.isAtLeast .berlin = true) :
    Evm.modexpGas fork baseLen expLen modLen expHead ≥ 200 := by
  unfold Evm.modexpGas
  by_cases ho : fork.isAtLeast .osaka = true
  · simp only [ho, ↓reduceIte]
    have h500 : 500 ≤ max 500 ((if max baseLen modLen ≤ 32 then 16 else 2 * ((max baseLen modLen + 7) / 8) * ((max baseLen modLen + 7) / 8)) * Evm.modexpIterations expLen expHead 16) := Nat.le_max_left _ _
    omega
  · simp only [ho, Bool.false_eq_true, ↓reduceIte, h]
    exact Nat.le_max_left _ _

/-- EIP-7883 (Osaka): above 32 bytes, MODEXP uses the exact `2 * words^2` complexity
    with 16x long-exponent multiplier and 500-gas minimum floor. -/
theorem modexpGas_osaka_gt32 (fork : Hardfork) (baseLen expLen modLen expHead : Nat)
    (hfork : fork.isAtLeast .osaka = true)
    (hgt : max baseLen modLen > 32) :
    Evm.modexpGas fork baseLen expLen modLen expHead =
      max 500 (2 * ((max baseLen modLen + 7) / 8) * ((max baseLen modLen + 7) / 8)
        * Evm.modexpIterations expLen expHead 16) := by
  unfold Evm.modexpGas
  have hnotle : ¬ (max baseLen modLen ≤ 32) := Nat.not_le.mpr hgt
  simp [hfork, hnotle]

/-- Executing empty bytecode always succeeds cleanly. -/
theorem execEvm_empty_code_success (fork : Hardfork) (calldata : ByteArray) (gasLimit : Nat) :
    (execEvm fork ByteArray.empty calldata gasLimit).success = true := by
  simp [execEvm, Evm.run, ByteArray.size]

/-- Executing empty bytecode consumes 0 gas. -/
theorem execEvm_empty_code_zero_gas (fork : Hardfork) (calldata : ByteArray) (gasLimit : Nat) :
    (execEvm fork ByteArray.empty calldata gasLimit).gasUsed = 0 := by
  simp [execEvm, Evm.run, ByteArray.size]

/-- Executing empty bytecode returns empty output. -/
theorem execEvm_empty_code_empty_output (fork : Hardfork) (calldata : ByteArray) (gasLimit : Nat) :
    (execEvm fork ByteArray.empty calldata gasLimit).output = ByteArray.empty := by
  simp [execEvm, Evm.run, ByteArray.size]

end ZevmSpec
