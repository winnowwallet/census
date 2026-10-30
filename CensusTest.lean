import WinnowCensus
import Lean.Data.Json
open WinnowCensus Winnow Lean

/-! `census-test`: the census's Lean against published vectors and the Swift tool's known answers, run from
the repository root.

- SHA3-256 against FIPS 202's empty and "abc" digests.
- Base32 against RFC 4648's vectors, both ways, and refusing an unknown character or nonzero trailing bits.
- Onion addresses against the Python contract tests' `onion(n)`, and every Tor and I2P host in the
  published `census/peers.json` accepted by `canonicalOverlay`, a corrupted checksum refused.
- Ed25519 against RFC 8032's test vectors 1-3 (deterministic signatures, byte for byte), the Swift tool's
  known answer (`tests/test_contract.py`'s KAT: seed 0x01×32 over the domain tag and
  `{"date":"2026-09-14"}`; CryptoKit's signatures carry added randomness, so it is verified, not
  reproduced), and the live `census/peers.json.sig` (CryptoKit's) verified; a flipped signature bit,
  another message and another key refused. -/

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) (why : String := "") : IO Unit := do
  if ok then IO.println s!"ok   {name}"
  else IO.println s!"FAIL {name}{if why.isEmpty then "" else s!": {why}"}"; failures.modify (· + 1)

def rfc8032 : List (String × String × String × String) := [
  ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
   "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
   "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
  ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
   "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
   "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
  ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
   "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
   "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a")]

def domain : ByteArray := "winnow-census-peers-v1".toUTF8.push 0

def flipBit (b : ByteArray) (i : Nat) : ByteArray := b.set! i (b.get! i ^^^ 1)

def main : IO UInt32 := do
  -- SHA3-256
  check "sha3-256 of nothing" (hex (Sha3.sha3_256 .empty) == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
  check "sha3-256 of abc" (hex (Sha3.sha3_256 "abc".toUTF8) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
  check "sha3-256 across a block boundary" (hex (Sha3.sha3_256 (ByteArray.mk (Array.replicate 200 0xa3))) ==
    "79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
  -- Base32
  for (plain, enc) in [("", ""), ("f", "my"), ("fo", "mzxq"), ("foo", "mzxw6"), ("foob", "mzxw6yq"),
                       ("fooba", "mzxw6ytb"), ("foobar", "mzxw6ytboi")] do
    check s!"base32 {repr plain}" (encodeBase32 plain.toUTF8 == enc && decodeBase32 enc == some plain.toUTF8)
  check "base32 refuses a character outside the alphabet" (decodeBase32 "mzxw1" == none)
  check "base32 refuses nonzero trailing bits" (decodeBase32 "mz" == none)
  -- onion addresses
  let key (n : Nat) : ByteArray := (Ed25519.leBytes n 32).reverse
  check "onion address of key 1, as the contract tests make it"
    (onionAddress (key 1) == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa7v2id.onion")
  check "onion address of key 2^200+7" (onionAddress (key (2 ^ 200 + 7)) == "aaaaaaaaaaaqaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaad5eqyd.onion")
  let peers ← IO.FS.readFile "census/peers.json"
  let some j := (Json.parse peers).toOption | check "census/peers.json parses" false; return 1
  let hosts (net : String) : List String := match j.getObjValD "networks" |>.getObjValD net |>.getArr? with
    | .ok a => a.toList.filterMap fun e => (e.getObjValAs? String "host").toOption
    | .error _ => []
  let tor := hosts "tor"
  let i2p := hosts "i2p"
  let badTor := tor.filter fun h => canonicalOverlay h .tor != some h
  let badI2p := i2p.filter fun h => canonicalOverlay h .i2p != some h
  check s!"every published onion host is accepted ({tor.length})" (!tor.isEmpty && badTor.isEmpty) s!"{badTor.take 3}"
  check s!"every published I2P host is accepted ({i2p.length})" (!i2p.isEmpty && badI2p.isEmpty) s!"{badI2p.take 3}"
  let good := "22nzruyyjaqpzner5zdcz3fan3gw3mj23vr7cmcexmnjb65flwyxvdqd.onion"
  let wrongSum := encodeBase32 (key 1 ++ (onionChecksum (key 1)).set! 0 ((onionChecksum (key 1)).get! 0 ^^^ 1) ++ ByteArray.mk #[3]) ++ ".onion"
  check "an onion with a wrong checksum is refused" (canonicalOverlay wrongSum .tor == none && canonicalOverlay (onionAddress (key 1)) .tor != none)
  let wrongVersion := encodeBase32 (key 1 ++ onionChecksum (key 1) ++ ByteArray.mk #[2]) ++ ".onion"
  check "an onion of another version is refused" (canonicalOverlay wrongVersion .tor == none)
  check "an onion is lowercased" (canonicalOverlay good.toUpper .tor == some good)
  check "a v2-length onion is refused" (canonicalOverlay "expyuzz4wqqyqhjn.onion" .tor == none)
  check "overlays by suffix" (Overlay.ofHost good == .tor && Overlay.ofHost "x.b32.i2p" == .i2p && Overlay.ofHost "1.2.3.4" == .clearnet)
  -- Ed25519
  for (i, (sk, pk, msg, sig)) in rfc8032.zipIdx.map (fun (v, i) => (i + 1, v)) do
    let sk := ofHex! sk
    let msg := ofHex! msg
    check s!"RFC 8032 test {i}: public key" (hex (Ed25519.publicKey sk) == pk)
    check s!"RFC 8032 test {i}: signature" (hex (Ed25519.sign sk msg) == sig)
    check s!"RFC 8032 test {i}: verifies" (Ed25519.verify (ofHex! pk) msg (ofHex! sig))
  let seed := ByteArray.mk (Array.replicate 32 1)
  let kat := domain ++ "{\"date\":\"2026-09-14\"}".toUTF8
  let katSig := "bdaac83b679535934fb1337a5bf40bc6e666cb040c0f8d83dbdbf7b88b7c187bb8a344182895dab82b646cd88e4236e4096f0a6fca6fefe661ba972fbbd78209"
  check "the Swift tool's known answer: public key" (hex (Ed25519.publicKey seed) == "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c")
  -- CryptoKit signs with added randomness, so its signature is a vector to verify, not to reproduce
  check "the Swift tool's known answer: its signature verifies" (Ed25519.verify (Ed25519.publicKey seed) kat (ofHex! katSig))
  check "the Swift tool's known answer: another date is refused"
    (!Ed25519.verify (Ed25519.publicKey seed) (domain ++ "{\"date\":\"2026-09-15\"}".toUTF8) (ofHex! katSig))
  check "a Lean signature over the same message verifies" (Ed25519.verify (Ed25519.publicKey seed) kat (Ed25519.sign seed kat))
  let sigFile ← IO.FS.readFile "census/peers.json.sig"
  let peerBytes ← IO.FS.readBinFile "census/peers.json"
  let some sj := (Json.parse sigFile).toOption | check "peers.json.sig parses" false; return 1
  let livePk := ofHex! ((sj.getObjValAs? String "publicKey").toOption.getD "")
  let liveSig := ofHex! ((sj.getObjValAs? String "signature").toOption.getD "")
  check "the published peers.json.sig (CryptoKit) verifies" (Ed25519.verify livePk (domain ++ peerBytes) liveSig)
  check "a flipped signature bit is refused" (!Ed25519.verify livePk (domain ++ peerBytes) (flipBit liveSig 5))
  check "a flipped S bit is refused" (!Ed25519.verify livePk (domain ++ peerBytes) (flipBit liveSig 40))
  check "another message is refused" (!Ed25519.verify livePk (domain ++ peerBytes.push 10) liveSig)
  check "without the domain tag it is refused" (!Ed25519.verify livePk peerBytes liveSig)
  check "another key is refused" (!Ed25519.verify (Ed25519.publicKey seed) (domain ++ peerBytes) liveSig)
  let n ← failures.get
  IO.println (if n == 0 then "census-test: all passed" else s!"census-test: {n} failed")
  return if n == 0 then 0 else 1
