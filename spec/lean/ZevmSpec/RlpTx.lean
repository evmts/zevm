/-
ZevmSpec.RlpTx: executable reference spec for

* hex helpers,
* canonical RLP (Yellow Paper, Appendix B),
* transaction envelope classification (EIP-2718, EIP-2930, EIP-1559,
  EIP-4844 bare + v0 network wrapper, EIP-7594 v1 cell-proof wrapper, EIP-7702),
* the Merkle-Patricia-Trie hex-prefix encoding (Yellow Paper, Appendix C).

Pure Lean 4 core. No `sorry`, no `axiom`, no `partial`, no `native_decide`.
Mirrors `src/transaction_encoding.zig` and voltaire `trie.zig` `encodePath`.
-/

namespace ZevmSpec

/-! ## Byte helpers -/

/-- Total byte read. Out-of-range reads return 0; every caller bounds-checks first. -/
def byteAt (b : ByteArray) (i : Nat) : UInt8 :=
  if h : i < b.size then b[i] else 0

def bytesEq (a b : ByteArray) : Bool :=
  a.data == b.data

/-- Big-endian natural number stored in `len` bytes starting at `start`. -/
def beNat (b : ByteArray) (start len : Nat) : Nat :=
  (List.range len).foldl (fun acc i => acc * 256 + (byteAt b (start + i)).toNat) 0

def natToBEList (n : Nat) (acc : List UInt8) : List UInt8 :=
  if h : n = 0 then acc else natToBEList (n / 256) (UInt8.ofNat (n % 256) :: acc)
termination_by n
decreasing_by omega

/-- Minimal big-endian encoding. `natToBE 0` is the empty byte string. -/
def natToBE (n : Nat) : ByteArray :=
  ByteArray.mk (natToBEList n []).toArray

/-! ## Hex -/

def hexDigit? (c : Char) : Option UInt8 :=
  let n := c.toNat
  if 48 ≤ n ∧ n ≤ 57 then some (UInt8.ofNat (n - 48))
  else if 97 ≤ n ∧ n ≤ 102 then some (UInt8.ofNat (n - 87))
  else if 65 ≤ n ∧ n ≤ 70 then some (UInt8.ofNat (n - 55))
  else none

def hexToBytesAux : List Char → ByteArray → Except String ByteArray
  | [], acc => .ok acc
  | [_], _ => .error "hex: odd number of digits"
  | a :: b :: rest, acc =>
    match hexDigit? a, hexDigit? b with
    | some hi, some lo => hexToBytesAux rest (acc.push (hi * 16 + lo))
    | _, _ => .error "hex: invalid digit"

/-- Parses hex, upper or lower case, with an optional `0x` prefix.
The empty string, `-`, and `0x` all denote the empty byte string. -/
def hexToBytes (s : String) : Except String ByteArray :=
  if s == "-" then .ok ByteArray.empty
  else
    match s.toList with
    | '0' :: 'x' :: rest => hexToBytesAux rest ByteArray.empty
    | '0' :: 'X' :: rest => hexToBytesAux rest ByteArray.empty
    | cs => hexToBytesAux cs ByteArray.empty

def hexChar (n : UInt8) : Char :=
  let v := n.toNat % 16
  Char.ofNat (if v < 10 then 48 + v else 87 + v)

/-- Lowercase hex without a prefix. The empty byte string maps to `""`. -/
def bytesToHex (b : ByteArray) : String :=
  String.ofList (b.data.toList.flatMap fun x => [hexChar (x / 16), hexChar x])

/-! ## RLP -/

inductive RlpItem where
  | bytes (data : ByteArray)
  | list (items : Array RlpItem)

instance : Inhabited RlpItem := ⟨.bytes ByteArray.empty⟩

def rlpLengthPrefix (len : Nat) (offset : Nat) : ByteArray :=
  if len < 56 then
    ByteArray.mk #[UInt8.ofNat (offset + len)]
  else
    let lb := natToBE len
    ByteArray.mk #[UInt8.ofNat (offset + 55 + lb.size)] ++ lb

/-- Canonical RLP encoding (Yellow Paper, Appendix B). -/
def rlpEncode : RlpItem → ByteArray
  | .bytes d =>
    if d.size = 1 ∧ (byteAt d 0).toNat < 128 then d
    else rlpLengthPrefix d.size 128 ++ d
  | .list items =>
    let payload := items.attach.foldl (fun acc it => acc ++ rlpEncode it.val) ByteArray.empty
    rlpLengthPrefix payload.size 192 ++ payload
termination_by item => item
decreasing_by
  have := Array.sizeOf_lt_of_mem it.property
  simp only [RlpItem.list.sizeOf_spec]
  omega

/-- Parses one RLP header at `pos` inside the window `[pos, stop)`.
Returns `(isList, payloadStart, payloadEnd)`. Requires `pos < stop ≤ input.size`. -/
def rlpHeader (input : ByteArray) (pos stop : Nat) : Except String (Bool × Nat × Nat) :=
  let p := (byteAt input pos).toNat
  if p < 128 then
    .ok (false, pos, pos + 1)
  else if p ≤ 183 then
    let len := p - 128
    let start := pos + 1
    if start + len > stop then .error "rlp: truncated string"
    else if len = 1 ∧ (byteAt input start).toNat < 128 then
      .error "rlp: non-canonical single byte"
    else .ok (false, start, start + len)
  else
    let isList := decide (p ≥ 192)
    if isList ∧ p ≤ 247 then
      let len := p - 192
      let start := pos + 1
      if start + len > stop then .error "rlp: truncated list" else .ok (true, start, start + len)
    else
      let lenOfLen := if isList then p - 247 else p - 183
      let lenStart := pos + 1
      if lenStart + lenOfLen > stop then .error "rlp: truncated length"
      else if (byteAt input lenStart).toNat = 0 then .error "rlp: length has leading zero"
      else
        let len := beNat input lenStart lenOfLen
        let start := lenStart + lenOfLen
        if len < 56 then .error "rlp: long form used for short payload"
        else if start + len > stop then .error "rlp: truncated payload"
        else .ok (isList, start, start + len)

/-- Iterative decoder with an explicit stack, so nesting depth never grows the
native stack. `acc` collects the items of the list being read, which ends at
`stop`. Every step consumes a header or closes a list, so `2 * size + 2`
steps of fuel always suffice. -/
def rlpDecodeLoop : Nat → ByteArray → Nat → Nat → Array RlpItem →
    List (Nat × Array RlpItem) → Except String (Array RlpItem)
  | 0, _, _, _, _, _ => .error "rlp: out of fuel"
  | fuel + 1, input, pos, stop, acc, stack =>
    if pos ≥ stop then
      match stack with
      | [] => .ok acc
      | (parentStop, parentAcc) :: rest =>
        rlpDecodeLoop fuel input pos parentStop (parentAcc.push (.list acc)) rest
    else
      match rlpHeader input pos stop with
      | .error e => .error e
      | .ok (isList, s, e) =>
        if isList then rlpDecodeLoop fuel input s e #[] ((stop, acc) :: stack)
        else rlpDecodeLoop fuel input e stop (acc.push (.bytes (input.extract s e))) stack

/-- Strict RLP decoding of exactly one item. Rejects the empty input, a single
byte below 0x80 wrapped behind 0x81, length fields with a leading zero, long-form
lengths below 56, truncated payloads, and trailing bytes. -/
def rlpDecode (input : ByteArray) : Except String RlpItem :=
  if input.size = 0 then .error "rlp: empty input"
  else
    match rlpDecodeLoop (2 * input.size + 2) input 0 input.size #[] [] with
    | .error e => .error e
    | .ok items =>
      if h : items.size = 1 then .ok items[0] else .error "rlp: trailing bytes"

/-- Decodes an RLP scalar: big-endian, no leading zero byte. The empty string is 0. -/
def rlpDecodeCanonicalNat (b : ByteArray) : Except String Nat :=
  if b.size = 0 then .ok 0
  else if (byteAt b 0).toNat = 0 then .error "rlp: integer has leading zero"
  else .ok (beNat b 0 b.size)

/-! ### `Repr` and `BEq` for `RlpItem` -/

def RlpItem.beq : RlpItem → RlpItem → Bool
  | .bytes a, .bytes b => bytesEq a b
  | .list a, .list b =>
    a.size == b.size &&
      (a.attach.zip b).all (fun p => RlpItem.beq p.1.val p.2)
  | _, _ => false
termination_by item => item
decreasing_by
  have := Array.sizeOf_lt_of_mem p.1.property
  simp only [RlpItem.list.sizeOf_spec]
  omega

instance : BEq RlpItem := ⟨RlpItem.beq⟩

def RlpItem.toStr : RlpItem → String
  | .bytes d => "0x" ++ bytesToHex d
  | .list items =>
    "[" ++ ", ".intercalate (items.attach.map (fun it => RlpItem.toStr it.val)).toList ++ "]"
termination_by item => item
decreasing_by
  have := Array.sizeOf_lt_of_mem it.property
  simp only [RlpItem.list.sizeOf_spec]
  omega

instance : Repr RlpItem := ⟨fun item _ => Std.Format.text item.toStr⟩
instance : ToString RlpItem := ⟨RlpItem.toStr⟩

/-! ## SHA-256 (FIPS 180-4)

Needed for the EIP-4844 rule `versioned_hash = 0x01 ++ sha256(commitment)[1:]`,
which `transaction_encoding.zig` enforces while decoding a network wrapper. -/

def sha256K : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

def sha256Init : Array UInt32 := #[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

def rotr32 (x : UInt32) (n : UInt32) : UInt32 :=
  (x >>> n) ||| (x <<< (32 - n))

def sha256Pad (msg : ByteArray) : ByteArray :=
  let zeros := (119 - msg.size % 64) % 64
  let lenBytes := (List.range 8).map fun i => UInt8.ofNat ((msg.size * 8) >>> (8 * (7 - i)))
  msg ++ ByteArray.mk (#[0x80] ++ Array.replicate zeros 0 ++ lenBytes.toArray)

def sha256Block (h : Array UInt32) (data : ByteArray) (off : Nat) : Array UInt32 := Id.run do
  let mut w : Array UInt32 := Array.replicate 64 0
  for i in [0:16] do
    w := w.set! i (UInt32.ofNat (beNat data (off + 4 * i) 4))
  for i in [16:64] do
    let x := w[i - 15]!
    let y := w[i - 2]!
    let s0 := rotr32 x 7 ^^^ rotr32 x 18 ^^^ (x >>> 3)
    let s1 := rotr32 y 17 ^^^ rotr32 y 19 ^^^ (y >>> 10)
    w := w.set! i (w[i - 16]! + s0 + w[i - 7]! + s1)
  let mut a := h[0]!
  let mut b := h[1]!
  let mut c := h[2]!
  let mut d := h[3]!
  let mut e := h[4]!
  let mut f := h[5]!
  let mut g := h[6]!
  let mut hh := h[7]!
  for i in [0:64] do
    let s1 := rotr32 e 6 ^^^ rotr32 e 11 ^^^ rotr32 e 25
    let ch := (e &&& f) ^^^ ((~~~e) &&& g)
    let t1 := hh + s1 + ch + sha256K[i]! + w[i]!
    let s0 := rotr32 a 2 ^^^ rotr32 a 13 ^^^ rotr32 a 22
    let maj := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)
    let t2 := s0 + maj
    hh := g
    g := f
    f := e
    e := d + t1
    d := c
    c := b
    b := a
    a := t1 + t2
  return #[h[0]! + a, h[1]! + b, h[2]! + c, h[3]! + d, h[4]! + e, h[5]! + f, h[6]! + g, h[7]! + hh]

def sha256 (msg : ByteArray) : ByteArray := Id.run do
  let padded := sha256Pad msg
  let mut h := sha256Init
  for blk in [0:padded.size / 64] do
    h := sha256Block h padded (64 * blk)
  let mut out := ByteArray.empty
  for word in h do
    out := out.push (word >>> 24).toUInt8
    out := out.push (word >>> 16).toUInt8
    out := out.push (word >>> 8).toUInt8
    out := out.push word.toUInt8
  return out

/-- EIP-4844 `kzg_to_versioned_hash`: `0x01 ++ sha256(commitment)[1:]`. -/
def kzgToVersionedHash (commitment : ByteArray) : ByteArray :=
  (sha256 commitment).set! 0 0x01

/-! ## Transaction envelopes -/

structure TxSummary where
  txType : Nat          -- 0, 1, 2, 3, 4
  nonce : Nat
  gasLimit : Nat
  wrapperVersion : Nat  -- 0 = bare, 1 = v0 blob wrapper, 2 = v1 PeerDAS cell wrapper
  wrapperTag : String   -- "bare" | "v0" | "v1"
  deriving Repr, BEq

def BYTES_PER_BLOB : Nat := 131072
def BYTES_PER_COMMITMENT : Nat := 48
def BYTES_PER_PROOF : Nat := 48
def CELLS_PER_EXT_BLOB : Nat := 128

def rlpAsBytes : RlpItem → Except String ByteArray
  | .bytes d => .ok d
  | .list _ => .error "tx: expected byte string, found list"

def rlpAsList : RlpItem → Except String (Array RlpItem)
  | .list items => .ok items
  | .bytes _ => .error "tx: expected list, found byte string"

/-- Canonical unsigned integer that fits in `maxBytes` bytes. -/
def rlpUInt (maxBytes : Nat) (item : RlpItem) : Except String Nat := do
  let b ← rlpAsBytes item
  if b.size > maxBytes then throw "tx: integer too wide"
  rlpDecodeCanonicalNat b

def rlpFixedBytes (len : Nat) (item : RlpItem) : Except String ByteArray := do
  let b ← rlpAsBytes item
  if b.size ≠ len then throw "tx: wrong fixed-width length"
  return b

/-- A list whose items are all byte strings of exactly `len` bytes. -/
def rlpFixedBytesList (len : Nat) (item : RlpItem) : Except String (Array ByteArray) := do
  let items ← rlpAsList item
  let mut out : Array ByteArray := #[]
  for it in items do
    out := out.push (← rlpFixedBytes len it)
  return out

/-- EIP-2930 access list: `[[address20, [key32, ...]], ...]`. -/
def checkAccessList (item : RlpItem) : Except String Unit := do
  for entry in (← rlpAsList item) do
    let pair ← rlpAsList entry
    if pair.size ≠ 2 then throw "tx: access list entry must have 2 items"
    let _ ← rlpFixedBytes 20 pair[0]!
    let _ ← rlpFixedBytesList 32 pair[1]!

/-- EIP-7702 authorization list: `[[chain_id, address, nonce, y_parity, r, s], ...]`
with `chain_id < 2^256`, `nonce < 2^64`, `y_parity < 2^8`, `r, s < 2^256`. -/
def checkAuthorizationList (item : RlpItem) : Except String Unit := do
  for entry in (← rlpAsList item) do
    let f ← rlpAsList entry
    if f.size ≠ 6 then throw "tx: authorization tuple must have 6 items"
    let _ ← rlpUInt 32 f[0]!
    let _ ← rlpFixedBytes 20 f[1]!
    let _ ← rlpUInt 8 f[2]!
    let _ ← rlpUInt 1 f[3]!
    let _ ← rlpUInt 32 f[4]!
    let _ ← rlpUInt 32 f[5]!

inductive FieldKind where
  | u64            -- canonical integer < 2^64
  | u256           -- canonical integer < 2^256
  | toOptional     -- empty (contract creation) or 20-byte address
  | toAddress      -- 20-byte address, creation not allowed
  | data           -- arbitrary byte string
  | accessList
  | blobHashes     -- list of 32-byte versioned hashes
  | authList
  | yParity        -- 0 or 1
  | legacyV        -- 27, 28, or >= 35 (EIP-155), < 2^64

def checkField (kind : FieldKind) (item : RlpItem) : Except String Unit := do
  match kind with
  | .u64 => let _ ← rlpUInt 8 item
  | .u256 => let _ ← rlpUInt 32 item
  | .toOptional =>
    let b ← rlpAsBytes item
    if b.size ≠ 0 ∧ b.size ≠ 20 then throw "tx: bad `to` length"
  | .toAddress => let _ ← rlpFixedBytes 20 item
  | .data => let _ ← rlpAsBytes item
  | .accessList => checkAccessList item
  | .blobHashes => let _ ← rlpFixedBytesList 32 item
  | .authList => checkAuthorizationList item
  | .yParity =>
    let v ← rlpUInt 8 item
    if v > 1 then throw "tx: y_parity must be 0 or 1"
  | .legacyV =>
    let v ← rlpUInt 8 item
    if ¬(v = 27 ∨ v = 28 ∨ v ≥ 35) then throw "tx: invalid legacy v"

def checkFields : List FieldKind → List RlpItem → Except String Unit
  | [], [] => .ok ()
  | k :: ks, it :: its =>
    match checkField k it with
    | .error e => .error e
    | .ok () => checkFields ks its
  | _, _ => .error "tx: wrong field count"

def legacyLayout : List FieldKind :=
  [.u64, .u256, .u64, .toOptional, .u256, .data, .legacyV, .u256, .u256]

def eip2930Layout : List FieldKind :=
  [.u64, .u64, .u256, .u64, .toOptional, .u256, .data, .accessList, .yParity, .u256, .u256]

def eip1559Layout : List FieldKind :=
  [.u64, .u64, .u256, .u256, .u64, .toOptional, .u256, .data, .accessList,
   .yParity, .u256, .u256]

def eip4844Layout : List FieldKind :=
  [.u64, .u64, .u256, .u256, .u64, .toAddress, .u256, .data, .accessList,
   .u256, .blobHashes, .yParity, .u256, .u256]

def eip7702Layout : List FieldKind :=
  [.u64, .u64, .u256, .u256, .u64, .toAddress, .u256, .data, .accessList,
   .authList, .yParity, .u256, .u256]

/-- Validates `fields` against `layout`, then reads the nonce and gas limit. -/
def summarize (txType : Nat) (layout : List FieldKind) (nonceIdx gasIdx : Nat)
    (wrapperVersion : Nat) (wrapperTag : String) (fields : Array RlpItem) :
    Except String TxSummary := do
  checkFields layout fields.toList
  let nonce ← rlpUInt 8 fields[nonceIdx]!
  let gasLimit ← rlpUInt 8 fields[gasIdx]!
  return { txType, nonce, gasLimit, wrapperVersion, wrapperTag }

/-- Type-3 network wrapper. `sections = [blobs, commitments, proofs]`. -/
def decodeBlobWrapper (txItem : RlpItem) (sections : Array RlpItem) (proofsPerBlob : Nat)
    (wrapperVersion : Nat) (wrapperTag : String) : Except String TxSummary := do
  let blobs ← rlpFixedBytesList BYTES_PER_BLOB sections[0]!
  let commitments ← rlpFixedBytesList BYTES_PER_COMMITMENT sections[1]!
  let proofs ← rlpFixedBytesList BYTES_PER_PROOF sections[2]!
  if blobs.size = 0 then throw "tx: wrapper carries no blobs"
  if commitments.size ≠ blobs.size then throw "tx: commitment count mismatch"
  if proofs.size ≠ blobs.size * proofsPerBlob then throw "tx: proof count mismatch"
  let fields ← rlpAsList txItem
  let summary ← summarize 3 eip4844Layout 1 4 wrapperVersion wrapperTag fields
  let hashes ← rlpFixedBytesList 32 fields[10]!
  if hashes.size ≠ blobs.size then throw "tx: versioned hash count mismatch"
  for i in [0:hashes.size] do
    if !bytesEq hashes[i]! (kzgToVersionedHash commitments[i]!) then
      throw "tx: commitment does not match versioned hash"
  return summary

/-- Classifies and structurally validates a raw transaction envelope.

* first byte `>= 0xc0`: legacy, an RLP list of 9 byte strings
* `0x01`: EIP-2930, 11 fields
* `0x02`: EIP-1559, 12 fields
* `0x03`: EIP-4844. The payload list starts with a byte string for a bare
  14-field transaction, or with a list for a network wrapper:
  `[tx, blobs, commitments, proofs]` (v0) or
  `[tx, 0x01, blobs, commitments, cell_proofs]` (EIP-7594 v1)
* `0x04`: EIP-7702, 13 fields
-/
def decodeTxSummary (raw : ByteArray) : Except String TxSummary := do
  if raw.size = 0 then throw "tx: empty input"
  let t := (byteAt raw 0).toNat
  if t ≥ 192 then
    let fields ← rlpAsList (← rlpDecode raw)
    summarize 0 legacyLayout 0 2 0 "bare" fields
  else if t = 1 ∨ t = 2 ∨ t = 3 ∨ t = 4 then
    let fields ← rlpAsList (← rlpDecode (raw.extract 1 raw.size))
    if t = 1 then summarize 1 eip2930Layout 1 3 0 "bare" fields
    else if t = 2 then summarize 2 eip1559Layout 1 4 0 "bare" fields
    else if t = 4 then summarize 4 eip7702Layout 1 4 0 "bare" fields
    else
      match (fields[0]? : Option RlpItem) with
      | none => throw "tx: empty type-3 payload"
      | some (RlpItem.bytes _) => summarize 3 eip4844Layout 1 4 0 "bare" fields
      | some txItem =>
        if fields.size = 4 then
          decodeBlobWrapper txItem (fields.extract 1 4) 1 1 "v0"
        else if fields.size = 5 then
          let version ← rlpAsBytes fields[1]!
          if ¬(version.size = 1 ∧ (byteAt version 0).toNat = 1) then
            throw "tx: unsupported blob wrapper version"
          decodeBlobWrapper txItem (fields.extract 2 5) CELLS_PER_EXT_BLOB 2 "v1"
        else throw "tx: wrong wrapper item count"
  else throw "tx: invalid transaction type"

/-! ## MPT hex-prefix encoding (Yellow Paper, Appendix C) -/

/-- Low 4 bits of nibble `i`. Callers pass nibbles below 16, where this is the identity. -/
def nibbleAt (nibbles : Array UInt8) (i : Nat) : Nat :=
  (nibbles.getD i 0).toNat % 16

/-- Flag nibble: bit 1 (0x2) marks a leaf, bit 0 (0x1) marks an odd nibble count. -/
def hpFlag (odd isLeaf : Bool) : Nat :=
  (if isLeaf then 2 else 0) + (if odd then 1 else 0)

def hpFirstByte (nibbles : Array UInt8) (isLeaf : Bool) : UInt8 :=
  let odd := nibbles.size % 2 == 1
  UInt8.ofNat (16 * hpFlag odd isLeaf + (if odd then nibbleAt nibbles 0 else 0))

def hpTail (nibbles : Array UInt8) : List UInt8 :=
  let start := nibbles.size % 2
  (List.range ((nibbles.size - start) / 2)).map fun i =>
    UInt8.ofNat (16 * nibbleAt nibbles (start + 2 * i) + nibbleAt nibbles (start + 2 * i + 1))

/-- Hex-prefix encoding. First byte is `0x00`/`0x20` (even extension/leaf) or
`0x1n`/`0x3n` (odd extension/leaf, `n` the first nibble); the rest packs two
nibbles per byte. -/
def encodePath (nibbles : Array UInt8) (isLeaf : Bool) : ByteArray :=
  ByteArray.mk (hpFirstByte nibbles isLeaf :: hpTail nibbles).toArray

/-! ## Theorems -/

theorem rlpDecodeCanonicalNat_empty : rlpDecodeCanonicalNat ByteArray.empty = Except.ok 0 := by
  rfl

theorem hpFlagBit :
    ∀ (f : Fin 4) (m : Fin 16),
      (UInt8.ofNat (16 * f.val + m.val) &&& 0x20 = 0x20) ↔ 2 ≤ f.val := by
  decide

theorem encodePath_first (nibbles : Array UInt8) (isLeaf : Bool) :
    byteAt (encodePath nibbles isLeaf) 0 = hpFirstByte nibbles isLeaf := by
  unfold byteAt encodePath
  rw [dif_pos (by show 0 < (List.toArray _).size; simp)]
  rfl

/-- The first byte of a hex-prefix path has bit `0x20` set iff the node is a leaf. -/
theorem encodePath_leaf_flag (nibbles : Array UInt8) (isLeaf : Bool) :
    (byteAt (encodePath nibbles isLeaf) 0 &&& 0x20 = 0x20) ↔ isLeaf = true := by
  rw [encodePath_first]
  unfold hpFirstByte
  cases isLeaf <;> cases h : (nibbles.size % 2 == 1)
  · exact (hpFlagBit ⟨0, by omega⟩ ⟨0, by omega⟩).trans (by simp)
  · exact (hpFlagBit ⟨1, by omega⟩ ⟨nibbleAt nibbles 0, Nat.mod_lt _ (by omega)⟩).trans (by simp)
  · exact (hpFlagBit ⟨2, by omega⟩ ⟨0, by omega⟩).trans (by simp)
  · exact (hpFlagBit ⟨3, by omega⟩ ⟨nibbleAt nibbles 0, Nat.mod_lt _ (by omega)⟩).trans (by simp)

theorem encodePath_size (nibbles : Array UInt8) (isLeaf : Bool) :
    (encodePath nibbles isLeaf).size = nibbles.size / 2 + 1 := by
  show (List.toArray _).size = _
  simp [hpTail]
  omega

/-! ## Elaboration-time test vectors -/

def hexOk (s : String) : ByteArray :=
  match hexToBytes s with
  | .ok b => b
  | .error _ => ByteArray.empty

def rlpOkHex (s : String) : Bool :=
  match rlpDecode (hexOk s) with
  | .ok item => bytesEq (rlpEncode item) (hexOk s)
  | .error _ => false

def rlpErrHex (s : String) : Bool :=
  match rlpDecode (hexOk s) with
  | .ok _ => false
  | .error _ => true

def txOk (s : String) (txType nonce gasLimit : Nat) (tag : String) : Bool :=
  match decodeTxSummary (hexOk s) with
  | .ok t => t.txType == txType && t.nonce == nonce && t.gasLimit == gasLimit && t.wrapperTag == tag
  | .error _ => false

def txErr (b : ByteArray) : Bool :=
  match decodeTxSummary b with
  | .ok _ => false
  | .error _ => true

-- hex
#guard bytesToHex (hexOk "0x00FFa1") == "00ffa1"
#guard (hexOk "-").size == 0 && (hexOk "").size == 0
#guard (match hexToBytes "abc" with | .error _ => true | .ok _ => false)
#guard (match hexToBytes "zz" with | .error _ => true | .ok _ => false)

-- SHA-256 (FIPS 180-4 vectors)
#guard bytesToHex (sha256 ByteArray.empty) ==
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
#guard bytesToHex (sha256 "abc".toUTF8) ==
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
#guard bytesToHex (sha256 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toUTF8) ==
  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

-- RLP round trips (Yellow Paper / ethereum wiki vectors)
#guard rlpOkHex "80" && rlpOkHex "00" && rlpOkHex "7f" && rlpOkHex "8180" && rlpOkHex "c0"
#guard rlpOkHex "83646f67" && rlpOkHex "c88363617483646f67" && rlpOkHex "c7c0c1c0c3c0c1c0"
#guard bytesEq (rlpEncode (.bytes (ByteArray.mk (Array.replicate 56 7))))
  (hexOk "b838" ++ ByteArray.mk (Array.replicate 56 7))
#guard (match rlpDecode (hexOk "b838" ++ ByteArray.mk (Array.replicate 56 7)) with
  | .ok (.bytes d) => d.size == 56 | _ => false)
#guard (match rlpDecode (hexOk "f838" ++ ByteArray.mk (Array.replicate 56 7)) with
  | .ok (.list items) => items.size == 56 | _ => false)
-- strictness
#guard rlpErrHex "" && rlpErrHex "8100" && rlpErrHex "817f"   -- empty, non-minimal single byte
#guard rlpErrHex "b800" && rlpErrHex "f800"                   -- leading-zero length
#guard rlpErrHex "b90001" && rlpErrHex "b801aa"               -- leading zero, long form < 56
#guard rlpErrHex "f801c0"                                     -- long-form list < 56
#guard rlpErrHex "83646f" && rlpErrHex "c283" && rlpErrHex "b838aa" -- truncated
#guard rlpErrHex "8080" && rlpErrHex "c000" && rlpErrHex "c2c0"     -- trailing / short
#guard rlpErrHex "c382aa"                                     -- child overruns parent list
-- canonical integers
#guard (match rlpDecodeCanonicalNat (hexOk "0400") with | .ok 1024 => true | _ => false)
#guard (match rlpDecodeCanonicalNat (hexOk "00") with | .error _ => true | _ => false)
#guard (match rlpDecodeCanonicalNat (hexOk "0001") with | .error _ => true | _ => false)

-- hex-prefix (voltaire trie.zig tests + Yellow Paper Appendix C)
#guard bytesToHex (encodePath #[1, 2, 3, 4] false) == "001234"
#guard bytesToHex (encodePath #[1, 2, 3] true) == "3123"
#guard bytesToHex (encodePath #[] false) == "00" && bytesToHex (encodePath #[] true) == "20"
#guard bytesToHex (encodePath #[1, 2, 3, 4, 5] false) == "112345"
#guard bytesToHex (encodePath #[0, 15, 1, 12, 11, 8] true) == "200f1cb8"

/-! ### Transaction vectors -/

def bStr (n : Nat) : RlpItem := .bytes (natToBE n)
def addr20 : RlpItem := .bytes (ByteArray.mk (Array.replicate 20 0xaa))
def emptyList : RlpItem := .list #[]

def typed (t : UInt8) (item : RlpItem) : ByteArray :=
  ByteArray.mk #[t] ++ rlpEncode item

def legacyItems : Array RlpItem :=
  #[bStr 9, bStr 20000000000, bStr 21000, addr20, bStr 1000000000000000000, .bytes .empty,
    bStr 37, bStr 1, bStr 1]

def eip2930Items : Array RlpItem :=
  #[bStr 1, bStr 7, bStr 5, bStr 21000, addr20, bStr 0, .bytes .empty, emptyList,
    bStr 1, bStr 1, bStr 1]

def eip1559Items : Array RlpItem :=
  #[bStr 1, bStr 8, bStr 2, bStr 5, bStr 30000, .bytes .empty, bStr 0, .bytes .empty,
    .list #[.list #[addr20, .list #[.bytes (ByteArray.mk (Array.replicate 32 1))]]],
    bStr 0, bStr 1, bStr 1]

def testCommitment (i : Nat) : ByteArray :=
  ByteArray.mk (Array.replicate 48 (UInt8.ofNat (0xc0 + i)))

def eip4844Items (blobCount : Nat) : Array RlpItem :=
  #[bStr 1, bStr 11, bStr 2, bStr 5, bStr 50000, addr20, bStr 0, .bytes .empty, emptyList,
    bStr 3,
    .list ((Array.range blobCount).map fun i => .bytes (kzgToVersionedHash (testCommitment i))),
    bStr 1, bStr 1, bStr 1]

def eip7702Items : Array RlpItem :=
  #[bStr 1, bStr 12, bStr 2, bStr 5, bStr 60000, addr20, bStr 0, .bytes .empty, emptyList,
    .list #[.list #[bStr 1, addr20, bStr 4, bStr 1, bStr 5, bStr 6]],
    bStr 0, bStr 1, bStr 1]

def blobList (n : Nat) (size : Nat := 131072) : RlpItem :=
  .list (Array.replicate n (.bytes (ByteArray.mk (Array.replicate size 0))))
def commitmentList (n : Nat) : RlpItem :=
  .list ((Array.range n).map fun i => .bytes (testCommitment i))
def proofList (n : Nat) (size : Nat := 48) : RlpItem :=
  .list (Array.replicate n (.bytes (ByteArray.mk (Array.replicate size 0xbb))))

def wrapV0 (blobCount : Nat) : ByteArray :=
  typed 3 (.list #[.list (eip4844Items blobCount), blobList blobCount, commitmentList blobCount,
    proofList blobCount])

def wrapV1 (blobCount proofCount : Nat) (version : RlpItem := bStr 1) : ByteArray :=
  typed 3 (.list #[.list (eip4844Items blobCount), version, blobList blobCount,
    commitmentList blobCount, proofList proofCount])

def txIs (b : ByteArray) (txType nonce gasLimit : Nat) (tag : String) : Bool :=
  match decodeTxSummary b with
  | .ok t => t.txType == txType && t.nonce == nonce && t.gasLimit == gasLimit && t.wrapperTag == tag
  | .error _ => false

-- EIP-155-shaped legacy transaction (chain id 1, v = 37); signature values are not checked
#guard txOk ("f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a7640000" ++
  "8025a028ef61340bd939bc2169f2ff0f0d8e0e9d0a5e0f5e6f5d4a2c8a5d0e5f6a7b8ca0" ++
  "67cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83") 0 9 21000 "bare"
-- same vector as transaction_encoding.zig's legacy test
#guard txOk "e201028252089400000000000000000000000000000000000000000382aabb25018180" 0 1 21000 "bare"

#guard txIs (rlpEncode (.list legacyItems)) 0 9 21000 "bare"
#guard txIs (typed 1 (.list eip2930Items)) 1 7 21000 "bare"
#guard txIs (typed 2 (.list eip1559Items)) 2 8 30000 "bare"
#guard txIs (typed 3 (.list (eip4844Items 2))) 3 11 50000 "bare"
#guard txIs (typed 4 (.list eip7702Items)) 4 12 60000 "bare"
#guard txIs (wrapV0 1) 3 11 50000 "v0"
#guard txIs (wrapV0 2) 3 11 50000 "v0"
#guard txIs (wrapV1 1 128) 3 11 50000 "v1"
#guard (match decodeTxSummary (wrapV1 1 128) with | .ok t => t.wrapperVersion == 2 | _ => false)

-- rejections
#guard txErr ByteArray.empty && txErr (hexOk "00") && txErr (hexOk "05c0") && txErr (hexOk "80")
#guard txErr (hexOk "01") && txErr (hexOk "0380") && txErr (hexOk "03c0")
#guard txErr (rlpEncode (.list (legacyItems.push (bStr 1))))            -- 10 fields
#guard txErr (rlpEncode (.list (legacyItems.set! 6 (bStr 29))))         -- bad v
#guard txErr (rlpEncode (.list (legacyItems.set! 0 (.bytes (hexOk "00")))))   -- nonce 0x00
#guard txErr (rlpEncode (.list (legacyItems.set! 0 (bStr (2 ^ 64)))))   -- nonce >= 2^64
#guard txErr (rlpEncode (.list (legacyItems.set! 5 emptyList)))         -- data is a list
#guard txErr (rlpEncode (.list legacyItems) ++ hexOk "00")              -- trailing byte
#guard txErr (typed 2 (.list eip2930Items))                             -- 11 fields under 0x02
#guard txErr (typed 1 (.list (eip2930Items.set! 8 (bStr 2))))           -- y_parity 2
#guard txErr (typed 3 (.list ((eip4844Items 1).set! 5 (.bytes .empty)))) -- blob tx cannot create
#guard txErr (typed 4 (.list (eip7702Items.set! 5 (.bytes .empty))))    -- set-code tx cannot create
#guard txErr (wrapV0 0)                                                 -- zero blobs
#guard txErr (wrapV1 1 127) && txErr (wrapV1 1 1)                       -- cell proof count
#guard txErr (wrapV1 1 128 (bStr 2)) && txErr (wrapV1 1 128 (bStr 0))   -- version byte
#guard txErr (typed 3 (.list #[.list (eip4844Items 1), blobList 1 131071, commitmentList 1,
  proofList 1]))                                                        -- short blob
#guard txErr (typed 3 (.list #[.list (eip4844Items 1), blobList 1, commitmentList 1,
  proofList 1 47]))                                                     -- short proof
#guard txErr (typed 3 (.list #[.list (eip4844Items 1), blobList 1,
  .list #[.bytes (testCommitment 5)], proofList 1]))                    -- hash mismatch
#guard txErr (typed 3 (.list #[.list (eip4844Items 2), blobList 1, commitmentList 1,
  proofList 1]))                                                        -- hash count mismatch
#guard txErr (typed 3 (.list #[.list (eip4844Items 1), blobList 1, commitmentList 1]))

end ZevmSpec
