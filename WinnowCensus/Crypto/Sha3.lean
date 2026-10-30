/-! # SHA3-256 (FIPS 202), for the v3 onion address checksum

Keccak-f[1600], rate 1088 bits (136 bytes), SHA3's domain suffix 0x06. Not a wallet key hash: the census
uses it only to check a `.onion` host's checksum (`WinnowCensus.Overlay`). The Swift tool's `OnionChecksum`. -/

namespace WinnowCensus.Sha3

def roundConstants : Array UInt64 := #[
  0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
  0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
  0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
  0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
  0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
  0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]

/-- ρ's rotation for lane (x, y), at index x + 5y. -/
def rotations : Array UInt64 := #[0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
  41, 45, 15, 21, 8, 18, 2, 61, 56, 14]

@[inline] def rotl (x n : UInt64) : UInt64 := if n == 0 then x else (x <<< n) ||| (x >>> (64 - n))

def permute (a : Array UInt64) : Array UInt64 := Id.run do
  let mut a := a
  for rc in roundConstants do
    -- θ
    let mut c := Array.replicate 5 (0 : UInt64)
    for x in [0:5] do
      for y in [0:5] do c := c.set! x (c[x]! ^^^ a[x + 5 * y]!)
    for x in [0:5] do
      let d := c[(x + 4) % 5]! ^^^ rotl c[(x + 1) % 5]! 1
      for y in [0:5] do a := a.set! (x + 5 * y) (a[x + 5 * y]! ^^^ d)
    -- ρ and π
    let mut b := Array.replicate 25 (0 : UInt64)
    for x in [0:5] do
      for y in [0:5] do b := b.set! (y + 5 * ((2 * x + 3 * y) % 5)) (rotl a[x + 5 * y]! rotations[x + 5 * y]!)
    -- χ
    for x in [0:5] do
      for y in [0:5] do
        a := a.set! (x + 5 * y) (b[x + 5 * y]! ^^^ ((~~~ b[(x + 1) % 5 + 5 * y]!) &&& b[(x + 2) % 5 + 5 * y]!))
    -- ι
    a := a.set! 0 (a[0]! ^^^ rc)
  return a

def rate : Nat := 136

/-- SHA3-256 of `input`: 32 bytes. -/
def sha3_256 (input : ByteArray) : ByteArray := Id.run do
  let padLen := rate - input.size % rate
  let mut padded := input ++ ByteArray.mk (Array.replicate padLen 0)
  padded := padded.set! input.size 0x06
  padded := padded.set! (padded.size - 1) (padded.get! (padded.size - 1) ||| 0x80)
  let mut state := Array.replicate 25 (0 : UInt64)
  for block in [0:padded.size / rate] do
    for i in [0:rate] do
      let lane := i / 8
      state := state.set! lane (state[lane]! ^^^ ((padded.get! (block * rate + i)).toUInt64 <<< (8 * (i % 8)).toUInt64))
    state := permute state
  let mut out := ByteArray.emptyWithCapacity 32
  for i in [0:32] do out := out.push (state[i / 8]! >>> (8 * (i % 8)).toUInt64).toUInt8
  return out

end WinnowCensus.Sha3
