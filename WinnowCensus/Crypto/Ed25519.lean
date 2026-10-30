import Winnow.Crypto.Sha2

/-! # Ed25519 (RFC 8032, section 5.1)

The census signs `census/peers.json` with Ed25519 over a domain tag and the file's bytes (`WinnowCensus.Signing`),
and the wallet verifies it. This is RFC 8032's algorithm as written, over `Nat` (Lean's GMP-backed
integers) in extended coordinates: key generation from a 32-byte seed, deterministic signing, and the
cofactored verification `[8][S]B = [8]R + [8][k]A`. It signs one file a day and checks it, so it favours
being plainly the RFC's arithmetic over speed, and it is not constant time: the secret is a CI secret on a
runner that runs nothing else while it signs. Checked against RFC 8032's test vectors and the Swift tool's
(CryptoKit's) known answer (`CensusTest`). -/

namespace WinnowCensus.Ed25519
open Winnow

def p : Nat := 2 ^ 255 - 19
/-- The order of the base point. -/
def L : Nat := 2 ^ 252 + 27742317777372353535851937790883648493

def powMod (b e m : Nat) : Nat := Id.run do
  let mut result := 1
  let mut base := b % m
  let mut e := e
  while e > 0 do
    if e % 2 == 1 then result := result * base % m
    base := base * base % m
    e := e / 2
  return result

def inv (x : Nat) : Nat := powMod x (p - 2) p

def d : Nat := (p - 121665) * inv 121666 % p
/-- A square root of -1 mod p. -/
def sqrtM1 : Nat := powMod 2 ((p - 1) / 4) p

/-- A point in extended coordinates (X, Y, Z, T) with x = X/Z, y = Y/Z, x·y = T/Z. -/
structure Point where
  X : Nat
  Y : Nat
  Z : Nat
  T : Nat

@[inline] def sub (a b : Nat) : Nat := (a + p - b % p) % p

def Point.add (P Q : Point) : Point :=
  let A := sub P.Y P.X * sub Q.Y Q.X % p
  let B := (P.Y + P.X) * (Q.Y + Q.X) % p
  let C := 2 * P.T * Q.T % p * d % p
  let D := 2 * P.Z * Q.Z % p
  let E := sub B A
  let F := sub D C
  let G := (D + C) % p
  let H := (B + A) % p
  { X := E * F % p, Y := G * H % p, Z := F * G % p, T := E * H % p }

def identity : Point := { X := 0, Y := 1, Z := 1, T := 0 }

def Point.mul (s : Nat) (P : Point) : Point := Id.run do
  let mut acc := identity
  let mut q := P
  let mut s := s
  while s > 0 do
    if s % 2 == 1 then acc := acc.add q
    q := q.add q
    s := s / 2
  return acc

/-- Projective equality: x₁/z₁ = x₂/z₂ and y₁/z₁ = y₂/z₂. -/
def Point.equal (P Q : Point) : Bool :=
  P.X * Q.Z % p == Q.X * P.Z % p && P.Y * Q.Z % p == Q.Y * P.Z % p

/-- The x with x² = (y² - 1)/(d·y² + 1) whose low bit is `sign` (RFC 8032, 5.1.3). -/
def recoverX (y : Nat) (sign : Bool) : Option Nat := do
  guard (y < p)
  let x2 := sub (y * y) 1 * inv ((d * y * y + 1) % p) % p
  if x2 == 0 then
    if sign then none else return 0
  let mut x := powMod x2 ((p + 3) / 8) p
  if sub (x * x) x2 != 0 then x := x * sqrtM1 % p
  guard (sub (x * x) x2 == 0)
  if (x % 2 == 1) != sign then x := p - x
  return x

def base : Point :=
  let y := 4 * inv 5 % p
  let x := (recoverX y false).getD 0
  { X := x, Y := y, Z := 1, T := x * y % p }

def natLE (b : ByteArray) : Nat := b.toList.foldr (fun byte acc => acc * 256 + byte.toNat) 0

def leBytes (n : Nat) (size : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.emptyWithCapacity size
  let mut n := n
  for _ in [0:size] do
    out := out.push (n % 256).toUInt8
    n := n / 256
  return out

def Point.encode (P : Point) : ByteArray :=
  let zi := inv P.Z
  let x := P.X * zi % p
  let y := P.Y * zi % p
  leBytes (y + (x % 2) * 2 ^ 255) 32

def decode (b : ByteArray) : Option Point := do
  guard (b.size == 32)
  let n := natLE b
  let y := n % 2 ^ 255
  let x ← recoverX y (n / 2 ^ 255 == 1)
  return { X := x, Y := y, Z := 1, T := x * y % p }

/-- The secret scalar (clamped) and the signing prefix from a 32-byte seed. -/
def expand (seed : ByteArray) : Nat × ByteArray :=
  let h := sha512 seed
  let a := natLE (h.extract 0 32)
  let a := a % 2 ^ 254 - a % 8 + 2 ^ 254
  (a, h.extract 32 64)

/-- The 32-byte public key of a 32-byte seed. -/
def publicKey (seed : ByteArray) : ByteArray := (Point.mul (expand seed).1 base).encode

/-- The 64-byte signature of `msg` under the 32-byte seed. -/
def sign (seed msg : ByteArray) : ByteArray :=
  let (a, pre) := expand seed
  let A := (Point.mul a base).encode
  let r := natLE (sha512 (pre ++ msg)) % L
  let R := (Point.mul r base).encode
  let k := natLE (sha512 (R ++ A ++ msg)) % L
  R ++ leBytes ((r + k * a) % L) 32

/-- Whether `sig` is a valid signature of `msg` under the 32-byte public key `pk`. -/
def verify (pk msg sig : ByteArray) : Bool := Id.run do
  if pk.size != 32 || sig.size != 64 then return false
  let some A := decode pk | return false
  let Rb := sig.extract 0 32
  let some R := decode Rb | return false
  let s := natLE (sig.extract 32 64)
  if s ≥ L then return false
  let k := natLE (sha512 (Rb ++ pk ++ msg)) % L
  let lhs := Point.mul 8 (Point.mul s base)
  let rhs := Point.mul 8 (R.add (Point.mul k A))
  return lhs.equal rhs

end WinnowCensus.Ed25519
