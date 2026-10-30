import WinnowCensus.Crypto.Sha3

/-! # Tor and I2P hosts

Which overlay a host is on, and whether a `.onion` or `.b32.i2p` host is well formed: base32 (RFC 4648,
lowercase, no padding, trailing bits zero), a v3 onion's 35 bytes (key, checksum, version 3) with its
SHA3-256 checksum, an I2P destination hash's 32 bytes. The Swift tool's `PublicationCatalog.canonicalOverlay`
and `OverlayNetwork`. -/

namespace WinnowCensus

inductive Overlay where
  | clearnet | tor | i2p
  deriving BEq, Inhabited, Repr

def Overlay.name : Overlay → String
  | .clearnet => "clearnet" | .tor => "tor" | .i2p => "i2p"

/-- A host's overlay, by its suffix (any case). -/
def Overlay.ofHost (host : String) : Overlay :=
  let h := host.toLower
  if h.endsWith ".onion" then .tor else if h.endsWith ".i2p" then .i2p else .clearnet

def base32Alphabet : String := "abcdefghijklmnopqrstuvwxyz234567"

/-- RFC 4648 base32, lowercase and unpadded; none for any other character or nonzero trailing bits. -/
def decodeBase32 (text : String) : Option ByteArray := Id.run do
  let alphabet := base32Alphabet.toList
  let mut buffer : Nat := 0
  let mut bits : Nat := 0
  let mut out := ByteArray.empty
  for ch in text.toList do
    let some v := alphabet.idxOf? ch | return none
    buffer := (buffer <<< 5 ||| v) % 2 ^ 13
    bits := bits + 5
    if bits ≥ 8 then
      bits := bits - 8
      out := out.push ((buffer >>> bits) % 256).toUInt8
  if buffer % 2 ^ bits != 0 then return none
  return some out

/-- RFC 4648 base32, lowercase and unpadded. -/
def encodeBase32 (bytes : ByteArray) : String := Id.run do
  let alphabet := base32Alphabet.toList.toArray
  let mut buffer : Nat := 0
  let mut bits : Nat := 0
  let mut out := ""
  for b in bytes.toList do
    buffer := (buffer <<< 8 ||| b.toNat) % 2 ^ 13
    bits := bits + 8
    while bits ≥ 5 do
      bits := bits - 5
      out := out.push alphabet[(buffer >>> bits) % 32]!
  if bits > 0 then out := out.push alphabet[(buffer <<< (5 - bits)) % 32]!
  return out

/-- The checksum a v3 onion address carries for its 32-byte key (rend-spec-v3). -/
def onionChecksum (key : ByteArray) : ByteArray :=
  (Sha3.sha3_256 (".onion checksum".toUTF8 ++ key ++ ByteArray.mk #[3])).extract 0 2

/-- A v3 onion address for a 32-byte key. -/
def onionAddress (key : ByteArray) : String :=
  encodeBase32 (key ++ onionChecksum key ++ ByteArray.mk #[3]) ++ ".onion"

/-- The host, lowercased, when it is a well-formed host of its overlay: a v3 onion with a valid checksum,
or a 52-character `.b32.i2p` destination. -/
def canonicalOverlay (host : String) (overlay : Overlay) : Option String := do
  let host := host.toLower
  let suffix := if overlay == .tor then ".onion" else ".b32.i2p"
  guard (host.endsWith suffix)
  let label := (host.dropEnd suffix.length).toString
  let bytes ← decodeBase32 label
  if overlay == .tor then
    guard (label.length == 56 && bytes.size == 35 && bytes.get! 34 == 3)
    guard (bytes.extract 32 34 == onionChecksum (bytes.extract 0 32))
  else
    guard (label.length == 52 && bytes.size == 32)
  return host

end WinnowCensus
