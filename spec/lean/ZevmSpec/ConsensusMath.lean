/-!
# ZevmSpec.ConsensusMath

Executable Lean 4 reference specification of the consensus arithmetic that
zevm implements in `src/blob_fee.zig`, `src/hardfork_schedule.zig`,
`src/block_builder.zig`, and `src/tx_processor.zig`:

* EIP-4844 `fake_exponential` and blob base fee
* EIP-7691 / EIP-7892 mainnet blob parameters (Cancun, Prague, Osaka, BPO1, BPO2)
* EIP-7918 blob reserve price and `calc_excess_blob_gas`
* EIP-1559 base fee update
* EIP-7623 calldata floor and refund ordering
* EIP-7825 transaction gas limit cap
* EIP-7934 RLP block size cap

All arithmetic is on unbounded `Nat`. Fixed-width behavior of the Zig
implementation (u64 / u256 saturation and overflow errors) is modeled
explicitly where the Zig code defines it.
-/

namespace ZevmSpec

/-! ## Hardforks -/

inductive Hardfork where
  | frontier | homestead | dao | tangerineWhistle | spuriousDragon
  | byzantium | constantinople | petersburg | istanbul | muirGlacier
  | berlin | london | arrowGlacier | grayGlacier | merge
  | shanghai | cancun | prague | osaka
  deriving Repr, BEq, DecidableEq

/-- Activation order of the hardforks, `frontier = 0` through `osaka = 18`. -/
def Hardfork.rank : Hardfork → Nat
  | .frontier => 0
  | .homestead => 1
  | .dao => 2
  | .tangerineWhistle => 3
  | .spuriousDragon => 4
  | .byzantium => 5
  | .constantinople => 6
  | .petersburg => 7
  | .istanbul => 8
  | .muirGlacier => 9
  | .berlin => 10
  | .london => 11
  | .arrowGlacier => 12
  | .grayGlacier => 13
  | .merge => 14
  | .shanghai => 15
  | .cancun => 16
  | .prague => 17
  | .osaka => 18

/-- `a.isAtLeast b` is true when fork `a` is `b` or a later fork. -/
def Hardfork.isAtLeast (a b : Hardfork) : Bool := a.rank >= b.rank

/-- Parses a fork name. Matching ignores case, `_`, and `-`, so `"osaka"`,
`"OSAKA"`, `"tangerine_whistle"`, and `"TangerineWhistle"` all parse.
`"paris"` is accepted as an alias of `merge`. -/
def Hardfork.ofString? (s : String) : Option Hardfork :=
  match ((s.toLower.replace "_" "").replace "-" "") with
  | "frontier" => some .frontier
  | "homestead" => some .homestead
  | "dao" => some .dao
  | "tangerinewhistle" => some .tangerineWhistle
  | "spuriousdragon" => some .spuriousDragon
  | "byzantium" => some .byzantium
  | "constantinople" => some .constantinople
  | "petersburg" => some .petersburg
  | "istanbul" => some .istanbul
  | "muirglacier" => some .muirGlacier
  | "berlin" => some .berlin
  | "london" => some .london
  | "arrowglacier" => some .arrowGlacier
  | "grayglacier" => some .grayGlacier
  | "merge" => some .merge
  | "paris" => some .merge
  | "shanghai" => some .shanghai
  | "cancun" => some .cancun
  | "prague" => some .prague
  | "osaka" => some .osaka
  | _ => none

/-! ## Constants -/

/-- EIP-4844 blob gas consumed by one blob (2^17). -/
def GAS_PER_BLOB : Nat := 131072
/-- EIP-7918 execution-cost floor per blob, in units of base fee (2^13). -/
def BLOB_BASE_COST : Nat := 8192
/-- EIP-7825 maximum declared transaction gas limit from Osaka (2^24). -/
def MAX_TX_GAS_OSAKA : Nat := 16777216
/-- EIP-7934 maximum RLP block size from Osaka: 10 MiB - 2 MiB safety margin. -/
def MAX_RLP_BLOCK_SIZE_OSAKA : Nat := 8388608
def U256_MAX : Nat := (1 <<< 256) - 1
def U64_MAX : Nat := (1 <<< 64) - 1

/-- EIP-4844 minimum blob base fee in wei. -/
def MIN_BASE_FEE_PER_BLOB_GAS : Nat := 1
/-- EIP-1559 elasticity multiplier: gas target = gas limit / 2. -/
def ELASTICITY_MULTIPLIER : Nat := 2
/-- EIP-1559 base fee max change denominator. -/
def BASE_FEE_MAX_CHANGE_DENOMINATOR : Nat := 8
/-- Base transaction gas (21000). -/
def TX_BASE_GAS : Nat := 21000
/-- EIP-7623 tokens per zero calldata byte. -/
def CALLDATA_ZERO_TOKENS : Nat := 1
/-- EIP-7623 tokens per nonzero calldata byte. -/
def CALLDATA_NONZERO_TOKENS : Nat := 4
/-- EIP-7623 floor gas per calldata token. -/
def CALLDATA_FLOOR_GAS_PER_TOKEN : Nat := 10

/-! ## EIP-4844 `fake_exponential` -/

/-- Loop body of EIP-4844 `fake_exponential`:

```
while numerator_accum > 0:
    output += numerator_accum
    numerator_accum = (numerator_accum * numerator) // (denominator * i)
    i += 1
```

`limit = some l` adds an early exit as soon as `output >= l`. The running sum
only grows, so the early exit never changes a result that is below `l`.

Termination is by the lexicographic measure `(numerator + 1 - i, acc)`: while
`i <= numerator` the first component drops; once `i > numerator` the first
component stays 0 and `acc * numerator / (denominator * i) < acc`. -/
def fakeExpLoop (numerator denominator : Nat) (limit : Option Nat)
    (i output acc : Nat) : Nat :=
  if acc = 0 then output
  else
    let output' := output + acc
    if limit.any (fun l => decide (l ≤ output')) then output'
    else fakeExpLoop numerator denominator limit (i + 1) output'
      (acc * numerator / (denominator * i))
termination_by (numerator + 1 - i, acc)
decreasing_by
  rename_i hacc _
  rw [Prod.lex_def]
  by_cases hi : i ≤ numerator
  · left
    show numerator + 1 - (i + 1) < numerator + 1 - i
    omega
  · right
    refine ⟨?_, ?_⟩
    · show numerator + 1 - (i + 1) = numerator + 1 - i
      omega
    · show acc * numerator / (denominator * i) < acc
      have hlt : numerator < i := Nat.lt_of_not_le hi
      have hacc' : 0 < acc := Nat.pos_of_ne_zero hacc
      by_cases hd : denominator * i = 0
      · rw [hd, Nat.div_zero]
        exact hacc'
      · have hpos : 0 < denominator * i := Nat.pos_of_ne_zero hd
        have hden : 0 < denominator := by
          apply Nat.pos_of_ne_zero
          intro h0
          apply hd
          rw [h0, Nat.zero_mul]
        have hle : i ≤ denominator * i := Nat.le_mul_of_pos_left i hden
        have hni : numerator < denominator * i := Nat.lt_of_lt_of_le hlt hle
        rw [Nat.div_lt_iff_lt_mul hpos]
        exact Nat.mul_lt_mul_of_pos_left hni hacc'

/-- EIP-4844 `fake_exponential(factor, numerator, denominator)`, exact on
unbounded naturals. Approximates `factor * e ** (numerator / denominator)`.
With `denominator = 0` Lean's total division gives 0; the EIP never calls it
that way. -/
def fakeExponential (factor numerator denominator : Nat) : Nat :=
  fakeExpLoop numerator denominator none 1 0 (factor * denominator) / denominator

/-- `fakeExponential` saturated at `U256_MAX`, matching
`blob_fee.fakeExponential` in zevm. The loop exits as soon as the running sum
proves the true result is at least `2^256`, which bounds the iteration count
for adversarial numerators. A zero `denominator` returns `U256_MAX`. -/
def fakeExponentialU256 (factor numerator denominator : Nat) : Nat :=
  if denominator = 0 then U256_MAX
  else
    min U256_MAX
      (fakeExpLoop numerator denominator (some ((U256_MAX + 1) * denominator)) 1 0
        (factor * denominator) / denominator)

/-- EIP-4844 `get_base_fee_per_blob_gas`, saturated at `U256_MAX`. Returns 0
when the update fraction is 0 (pre-Cancun "no blob fee"), matching
`blob_fee.calcBlobBaseFee`. -/
def calcBlobBaseFee (excessBlobGas fraction : Nat) : Nat :=
  if fraction = 0 then 0
  else fakeExponentialU256 MIN_BASE_FEE_PER_BLOB_GAS excessBlobGas fraction

/-! ## Mainnet blob parameters (EIP-4844, EIP-7691, EIP-7892) -/

/-- Blob parameters of one fork: target blobs, max blobs, and base fee update
fraction. All zero means "no blobs". -/
structure BlobParams where
  target : Nat
  max : Nat
  fraction : Nat
  deriving Repr, BEq, DecidableEq

def BlobParams.none : BlobParams := ⟨0, 0, 0⟩
def MAINNET_CANCUN_BLOB_PARAMS : BlobParams := ⟨3, 6, 3338477⟩
def MAINNET_PRAGUE_BLOB_PARAMS : BlobParams := ⟨6, 9, 5007716⟩
def MAINNET_OSAKA_BLOB_PARAMS : BlobParams := ⟨6, 9, 5007716⟩
def MAINNET_BPO1_BLOB_PARAMS : BlobParams := ⟨10, 15, 8346193⟩
def MAINNET_BPO2_BLOB_PARAMS : BlobParams := ⟨14, 21, 11684671⟩
/-- Mainnet BPO1 activation timestamp (2025-12-09). -/
def MAINNET_BPO1_TIMESTAMP : Nat := 1765290071
/-- Mainnet BPO2 activation timestamp (2026-01-07). -/
def MAINNET_BPO2_TIMESTAMP : Nat := 1767747671

/-- Mainnet blob parameters for a block of `fork` at `timestamp`, matching
`blob_fee.blobParamsForFork` with `MAINNET_CHAIN_CONFIG`. BPO entries apply
only once Osaka is active. -/
def mainnetBlobParams (fork : Hardfork) (timestamp : Nat) : BlobParams :=
  if !fork.isAtLeast .cancun then BlobParams.none
  else if !fork.isAtLeast .prague then MAINNET_CANCUN_BLOB_PARAMS
  else if !fork.isAtLeast .osaka then MAINNET_PRAGUE_BLOB_PARAMS
  else if timestamp ≥ MAINNET_BPO2_TIMESTAMP then MAINNET_BPO2_BLOB_PARAMS
  else if timestamp ≥ MAINNET_BPO1_TIMESTAMP then MAINNET_BPO1_BLOB_PARAMS
  else MAINNET_OSAKA_BLOB_PARAMS

/-! ## EIP-7918 excess blob gas -/

/-- EIP-7918 reserve check: the execution-cost floor
`BLOB_BASE_COST * baseFee` strictly exceeds `GAS_PER_BLOB * blobFee`. -/
def isBlobReserveActive (baseFee blobFee : Nat) : Bool :=
  decide (BLOB_BASE_COST * baseFee > GAS_PER_BLOB * blobFee)

/-- Saturates a natural at `U64_MAX`. -/
def saturateU64 (n : Nat) : Nat := min n U64_MAX

/-- Header `excess_blob_gas` of a child block. `fork`, `target`, `max`, and
`fraction` belong to the child. `target` and `max` are blob counts.

Order of checks, matching `blob_fee.calcExcessBlobGas`:
1. Before Cancun the result is 0.
2. Target floor: `parentExcess + parentUsed < target * GAS_PER_BLOB` gives 0.
3. From Osaka with `max != 0`, when the EIP-7918 reserve is active the result
   is `parentExcess + parentUsed * (max - target) / max`.
4. Otherwise the EIP-4844 result `parentExcess + parentUsed - target * GAS_PER_BLOB`.

Results saturate at `U64_MAX`. -/
def calcExcessBlobGas (fork : Hardfork)
    (target max fraction parentExcess parentUsed parentBaseFee : Nat) : Nat :=
  if !fork.isAtLeast .cancun then 0
  else if parentExcess + parentUsed < target * GAS_PER_BLOB then 0
  else if fork.isAtLeast .osaka && max != 0
      && isBlobReserveActive parentBaseFee (calcBlobBaseFee parentExcess fraction) then
    saturateU64 (parentExcess + parentUsed * (max - target) / max)
  else
    saturateU64 (parentExcess + parentUsed - target * GAS_PER_BLOB)

/-! ## EIP-1559 base fee -/

/-- EIP-1559 base fee of the child of a block with `parentBaseFee`,
`parentGasUsed`, and `parentGasLimit`. Returns `none` when the parent gas
target `parentGasLimit / 2` is 0 (`parentGasLimit < 2`), when `parentBaseFee`
exceeds `U256_MAX`, or when the result exceeds `U256_MAX`. -/
def expectedBaseFeePerGas (parentBaseFee parentGasUsed parentGasLimit : Nat) : Option Nat :=
  if parentGasLimit / ELASTICITY_MULTIPLIER = 0 then none
  else if parentBaseFee > U256_MAX then none
  else if parentGasUsed = parentGasLimit / ELASTICITY_MULTIPLIER then some parentBaseFee
  else if parentGasUsed > parentGasLimit / ELASTICITY_MULTIPLIER then
    -- Increase by max(1, parentBaseFee * gasDelta / target / 8).
    if parentBaseFee + Nat.max 1 (parentBaseFee
        * (parentGasUsed - parentGasLimit / ELASTICITY_MULTIPLIER)
        / (parentGasLimit / ELASTICITY_MULTIPLIER) / BASE_FEE_MAX_CHANGE_DENOMINATOR) > U256_MAX then none
    else some (parentBaseFee + Nat.max 1 (parentBaseFee
        * (parentGasUsed - parentGasLimit / ELASTICITY_MULTIPLIER)
        / (parentGasLimit / ELASTICITY_MULTIPLIER) / BASE_FEE_MAX_CHANGE_DENOMINATOR))
  else
    -- Decrease by parentBaseFee * gasDelta / target / 8, floored at 0.
    some (parentBaseFee - parentBaseFee
      * (parentGasLimit / ELASTICITY_MULTIPLIER - parentGasUsed)
      / (parentGasLimit / ELASTICITY_MULTIPLIER) / BASE_FEE_MAX_CHANGE_DENOMINATOR)

/-! ## EIP-7623 effective gas -/

/-- EIP-7623 calldata tokens: `zeroBytes + 4 * nonZeroBytes`. -/
def calldataTokens (zeroBytes nonZeroBytes : Nat) : Nat :=
  CALLDATA_ZERO_TOKENS * zeroBytes + CALLDATA_NONZERO_TOKENS * nonZeroBytes

/-- EIP-7623 transaction gas floor: `21000 + 10 * tokens` from Prague, 0 before. -/
def calldataFloor (fork : Hardfork) (zeroBytes nonZeroBytes : Nat) : Nat :=
  if fork.isAtLeast .prague then
    TX_BASE_GAS + CALLDATA_FLOOR_GAS_PER_TOKEN * calldataTokens zeroBytes nonZeroBytes
  else 0

/-- Refund cap: `gasUsed / 5` from London (EIP-3529), `gasUsed / 2` before. -/
def maxRefund (fork : Hardfork) (gasUsed : Nat) : Nat :=
  if fork.isAtLeast .london then gasUsed / 5 else gasUsed / 2

/-- Final gas billed for a transaction. `execGas` is the gas used before the
floor (intrinsic gas plus execution gas consumed). The refund cap is computed
on `execGas`, the capped refund is subtracted, and only then is the EIP-7623
calldata floor applied as a lower bound. -/
def effectiveGasUsed (fork : Hardfork) (execGas refund zeroBytes nonZeroBytes : Nat) : Nat :=
  Nat.max (execGas - Nat.min refund (maxRefund fork execGas))
    (calldataFloor fork zeroBytes nonZeroBytes)

/-! ## EIP-7825 and EIP-7934 caps -/

/-- EIP-7825: from Osaka a transaction's declared gas limit is at most 2^24. -/
def validateTxGasLimit (fork : Hardfork) (gasLimit : Nat) : Bool :=
  !(fork.isAtLeast .osaka && decide (gasLimit > MAX_TX_GAS_OSAKA))

/-- EIP-7934: from Osaka an RLP-encoded block is at most `MAX_RLP_BLOCK_SIZE_OSAKA` bytes. -/
def validateBlockRlpSize (fork : Hardfork) (size : Nat) : Bool :=
  !(fork.isAtLeast .osaka && decide (size > MAX_RLP_BLOCK_SIZE_OSAKA))

/-! ## Theorems -/

/-- The EIP-7918 reserve comparison reduces to `baseFee > 16 * blobFee`. -/
theorem reserve_equiv (baseFee blobFee : Nat) :
    (8192 * baseFee > 131072 * blobFee) ↔ (baseFee > 16 * blobFee) := by
  omega

/-- `isBlobReserveActive` is exactly `baseFee > 16 * blobFee`. -/
theorem isBlobReserveActive_iff (baseFee blobFee : Nat) :
    isBlobReserveActive baseFee blobFee = true ↔ baseFee > 16 * blobFee := by
  unfold isBlobReserveActive BLOB_BASE_COST GAS_PER_BLOB
  rw [decide_eq_true_iff]
  exact reserve_equiv baseFee blobFee

/-- Target floor first: below the blob gas target the excess is 0 on every
fork, for every base fee, even when the EIP-7918 reserve would be active. -/
theorem calcExcessBlobGas_floor_zero (fork : Hardfork)
    (target max fraction parentExcess parentUsed parentBaseFee : Nat)
    (h : parentExcess + parentUsed < target * GAS_PER_BLOB) :
    calcExcessBlobGas fork target max fraction parentExcess parentUsed parentBaseFee = 0 := by
  unfold calcExcessBlobGas
  split
  all_goals first
    | rfl
    | rw [if_pos h]

/-- `calcExcessBlobGas` never exceeds `U64_MAX`. -/
theorem calcExcessBlobGas_le_u64 (fork : Hardfork)
    (target max fraction parentExcess parentUsed parentBaseFee : Nat) :
    calcExcessBlobGas fork target max fraction parentExcess parentUsed parentBaseFee ≤ U64_MAX := by
  unfold calcExcessBlobGas saturateU64
  repeat' split
  all_goals first
    | exact Nat.zero_le _
    | exact Nat.min_le_right _ _

/-- At the gas target the base fee is unchanged. -/
theorem expectedBaseFee_at_target (parentBaseFee parentGasUsed parentGasLimit : Nat)
    (hLimit : parentGasLimit ≥ 2)
    (hUsed : parentGasUsed = parentGasLimit / 2)
    (hFee : parentBaseFee ≤ U256_MAX) :
    expectedBaseFeePerGas parentBaseFee parentGasUsed parentGasLimit = some parentBaseFee := by
  have hTarget : ¬ (parentGasLimit / 2 = 0) := by omega
  have hNotOver : ¬ (parentBaseFee > U256_MAX) := Nat.not_lt.mpr hFee
  unfold expectedBaseFeePerGas ELASTICITY_MULTIPLIER
  rw [if_neg hTarget, if_neg hNotOver, if_pos hUsed]

/-- A defined base fee always fits in a u256. -/
theorem expectedBaseFee_le_u256 (parentBaseFee parentGasUsed parentGasLimit next : Nat)
    (h : expectedBaseFeePerGas parentBaseFee parentGasUsed parentGasLimit = some next) :
    next ≤ U256_MAX := by
  unfold expectedBaseFeePerGas at h
  repeat' split at h
  all_goals first
    | (simp at h; done)
    | (have h' := Option.some.inj h; omega)
    | (have h' := Option.some.inj h
       have hFee : parentBaseFee ≤ U256_MAX := by omega
       exact h' ▸ Nat.le_trans (Nat.sub_le _ _) hFee)

/-- EIP-7623: the billed gas is never below the calldata floor, on any fork
and for any refund. -/
theorem effectiveGasUsed_ge_floor (fork : Hardfork)
    (execGas refund zeroBytes nonZeroBytes : Nat) :
    effectiveGasUsed fork execGas refund zeroBytes nonZeroBytes
      ≥ calldataFloor fork zeroBytes nonZeroBytes := by
  unfold effectiveGasUsed
  exact Nat.le_max_right _ _

/-- Prague instance with the floor written out. -/
theorem effectiveGasUsed_ge_floor_prague (execGas refund zeroBytes nonZeroBytes : Nat) :
    effectiveGasUsed .prague execGas refund zeroBytes nonZeroBytes
      ≥ 21000 + 10 * (zeroBytes + 4 * nonZeroBytes) := by
  have h := effectiveGasUsed_ge_floor .prague execGas refund zeroBytes nonZeroBytes
  have hf : calldataFloor .prague zeroBytes nonZeroBytes
      = 21000 + 10 * (zeroBytes + 4 * nonZeroBytes) := by
    simp [calldataFloor, calldataTokens, Hardfork.isAtLeast, Hardfork.rank, TX_BASE_GAS,
      CALLDATA_FLOOR_GAS_PER_TOKEN, CALLDATA_ZERO_TOKENS, CALLDATA_NONZERO_TOKENS]
  rw [hf] at h
  exact h

/-- Osaka instance with the floor written out. -/
theorem effectiveGasUsed_ge_floor_osaka (execGas refund zeroBytes nonZeroBytes : Nat) :
    effectiveGasUsed .osaka execGas refund zeroBytes nonZeroBytes
      ≥ 21000 + 10 * (zeroBytes + 4 * nonZeroBytes) := by
  have h := effectiveGasUsed_ge_floor .osaka execGas refund zeroBytes nonZeroBytes
  have hf : calldataFloor .osaka zeroBytes nonZeroBytes
      = 21000 + 10 * (zeroBytes + 4 * nonZeroBytes) := by
    simp [calldataFloor, calldataTokens, Hardfork.isAtLeast, Hardfork.rank, TX_BASE_GAS,
      CALLDATA_FLOOR_GAS_PER_TOKEN, CALLDATA_ZERO_TOKENS, CALLDATA_NONZERO_TOKENS]
  rw [hf] at h
  exact h

/-- The billed gas never exceeds the larger of pre-floor gas and the floor. -/
theorem effectiveGasUsed_le (fork : Hardfork) (execGas refund zeroBytes nonZeroBytes : Nat) :
    effectiveGasUsed fork execGas refund zeroBytes nonZeroBytes
      ≤ Nat.max execGas (calldataFloor fork zeroBytes nonZeroBytes) := by
  unfold effectiveGasUsed
  have h1 : execGas - Nat.min refund (maxRefund fork execGas) ≤ execGas := Nat.sub_le _ _
  simp only [Nat.max_def]
  repeat' split
  all_goals omega

/-! ## Executable checks

Vectors from go-ethereum `TestFakeExponential` and the zevm unit tests in
`src/blob_fee.zig`, `src/block_builder.zig`, and `src/tx_processor.zig`. -/

#guard fakeExponential 1 0 1 == 1
#guard fakeExponential 38493 0 1000 == 38493
#guard fakeExponential 0 1234 2345 == 0
#guard fakeExponential 1 2 1 == 6
#guard fakeExponential 1 4 2 == 6
#guard fakeExponential 1 3 1 == 16
#guard fakeExponential 1 6 2 == 18
#guard fakeExponential 1 4 1 == 49
#guard fakeExponential 1 8 2 == 50
#guard fakeExponential 10 8 2 == 542
#guard fakeExponential 11 8 2 == 596
#guard fakeExponential 1 5 1 == 136
#guard fakeExponential 1 5 2 == 11
#guard fakeExponential 2 5 2 == 23
#guard fakeExponential 1 50000000 2225652 == 5709098764
#guard fakeExponential 1 380928 3338477 == 1
#guard fakeExponential 1 1000 100 == 22025

-- Saturation and adversarial inputs.
#guard fakeExponentialU256 1 U64_MAX 1 == U256_MAX
#guard fakeExponentialU256 1 U64_MAX 3338477 == U256_MAX
#guard fakeExponentialU256 U256_MAX 1 1 == U256_MAX
#guard fakeExponentialU256 1 1 0 == U256_MAX
#guard fakeExponentialU256 U256_MAX 0 U64_MAX == U256_MAX
#guard fakeExponentialU256 (U256_MAX - 1) 0 U64_MAX == U256_MAX - 1
#guard fakeExponentialU256 1 (177 * 3338477) 3338477 < U256_MAX
#guard fakeExponentialU256 1 (177 * 3338477) 3338477 == fakeExponential 1 (177 * 3338477) 3338477
#guard fakeExponentialU256 1 (178 * 3338477) 3338477 == U256_MAX
#guard fakeExponential 1 (178 * 3338477) 3338477 > U256_MAX
#guard calcBlobBaseFee 20000000 0 == 0

-- Hardforks.
#guard Hardfork.ofString? "osaka" == some .osaka
#guard Hardfork.ofString? "PRAGUE" == some .prague
#guard Hardfork.ofString? "TANGERINE_WHISTLE" == some .tangerineWhistle
#guard Hardfork.ofString? "arrowGlacier" == some .arrowGlacier
#guard Hardfork.ofString? "nope" == none
#guard Hardfork.osaka.isAtLeast .cancun
#guard !Hardfork.cancun.isAtLeast .prague

-- Mainnet blob schedule.
#guard mainnetBlobParams .shanghai 0 == BlobParams.none
#guard mainnetBlobParams .cancun 0 == ⟨3, 6, 3338477⟩
#guard mainnetBlobParams .prague MAINNET_BPO2_TIMESTAMP == ⟨6, 9, 5007716⟩
#guard mainnetBlobParams .osaka 1765290070 == ⟨6, 9, 5007716⟩
#guard mainnetBlobParams .osaka 1765290071 == ⟨10, 15, 8346193⟩
#guard mainnetBlobParams .osaka 1767747670 == ⟨10, 15, 8346193⟩
#guard mainnetBlobParams .osaka 1767747671 == ⟨14, 21, 11684671⟩

-- calcExcessBlobGas: vectors from `src/blob_fee.zig` (Osaka 6/9, Cancun 3/6).
#guard calcExcessBlobGas .shanghai 3 6 3338477 999 999 U256_MAX == 0
#guard calcExcessBlobGas .prague 6 9 5007716 0 (6 * GAS_PER_BLOB) 17 == 0
#guard calcExcessBlobGas .prague 6 9 5007716 0 (6 * GAS_PER_BLOB + 1) U256_MAX == 1
#guard calcExcessBlobGas .osaka 6 9 5007716 0 (6 * GAS_PER_BLOB - 1) U256_MAX == 0
#guard calcExcessBlobGas .osaka 6 9 5007716 0 (6 * GAS_PER_BLOB) 16 == 0
#guard calcExcessBlobGas .osaka 6 9 5007716 0 (6 * GAS_PER_BLOB) 17 == 2 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 6 9 5007716 0 (9 * GAS_PER_BLOB) 16 == 3 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 6 9 5007716 0 (9 * GAS_PER_BLOB) 17 == 3 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 6 9 5007716 (6 * GAS_PER_BLOB) 0 U256_MAX == 6 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 6 9 5007716 (6 * GAS_PER_BLOB) 0 0 == 0
#guard calcExcessBlobGas .osaka 6 9 5007716 (6 * GAS_PER_BLOB) 1 U256_MAX == 6 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 6 9 5007716 (6 * GAS_PER_BLOB) 5 U256_MAX == 6 * GAS_PER_BLOB + 1
#guard calcExcessBlobGas .osaka 6 9 5007716 850000000 0
    (16 * calcBlobBaseFee 850000000 5007716) == 850000000 - 6 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 6 9 5007716 850000000 0
    (16 * calcBlobBaseFee 850000000 5007716 + 1) == 850000000
#guard calcExcessBlobGas .osaka 6 9 5007716 (U64_MAX - 6 * GAS_PER_BLOB) (6 * GAS_PER_BLOB) U256_MAX
    == U64_MAX - 6 * GAS_PER_BLOB
#guard calcExcessBlobGas .cancun 3 6 3338477 U64_MAX (3 * GAS_PER_BLOB - 1) 0 == U64_MAX - 1
#guard calcExcessBlobGas .osaka 6 9 5007716 U64_MAX (9 * GAS_PER_BLOB) U256_MAX == U64_MAX
-- BPO2 transition: 15 blobs used, reserve active at 1 gwei base fee.
#guard calcExcessBlobGas .osaka 14 21 11684671 0 (15 * GAS_PER_BLOB) 0 == 1 * GAS_PER_BLOB
#guard calcExcessBlobGas .osaka 14 21 11684671 0 (15 * GAS_PER_BLOB) 1000000000
    == 15 * GAS_PER_BLOB * 7 / 21

-- EIP-1559.
#guard expectedBaseFeePerGas 1000000000 15000000 30000000 == some 1000000000
#guard expectedBaseFeePerGas 1000000000 30000000 30000000 == some 1125000000
#guard expectedBaseFeePerGas 1000000000 0 30000000 == some 875000000
#guard expectedBaseFeePerGas 7 15000001 30000000 == some 8
#guard expectedBaseFeePerGas 7 14999999 30000000 == some 7
#guard expectedBaseFeePerGas 0 30000000 30000000 == some 1
#guard expectedBaseFeePerGas 1000000000 0 1 == none
#guard expectedBaseFeePerGas 1000000000 0 0 == none
#guard expectedBaseFeePerGas U256_MAX 30000000 30000000 == none
#guard expectedBaseFeePerGas U256_MAX 15000000 30000000 == some U256_MAX
#guard expectedBaseFeePerGas (U256_MAX + 1) 15000000 30000000 == none

-- EIP-7623.
#guard effectiveGasUsed .prague 21000 0 0 0 == 21000
#guard effectiveGasUsed .prague 100000 50000 0 0 == 80000
#guard effectiveGasUsed .prague 100000 50000 0 1000 == 80000
#guard effectiveGasUsed .prague 37000 0 0 1000 == 61000
#guard effectiveGasUsed .prague 60000 100000 0 1000 == 61000
#guard effectiveGasUsed .cancun 60000 100000 0 1000 == 48000
#guard effectiveGasUsed .berlin 60000 100000 0 1000 == 30000

-- EIP-7825 and EIP-7934.
#guard validateTxGasLimit .osaka 16777216
#guard !validateTxGasLimit .osaka 16777217
#guard validateTxGasLimit .prague 16777217
#guard validateBlockRlpSize .osaka 8388608
#guard !validateBlockRlpSize .osaka 8388609
#guard validateBlockRlpSize .prague 8388609
#guard U256_MAX == 2 ^ 256 - 1
#guard U64_MAX == 18446744073709551615

end ZevmSpec
