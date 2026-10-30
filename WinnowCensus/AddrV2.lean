import Winnow.Net.Wire
import Winnow.Net.PeerAddress
import Winnow.IO.Census
import WinnowCensus.Overlay

/-! # Gossiped addresses: `addr` and BIP155 `addrv2`

What a peer answers to `getaddr`. `addr` carries IPv4 and IPv6 only (16-byte `CAddress`); `addrv2`, which
a peer sends once both sides said `sendaddrv2` before `verack`, also carries Tor v3 keys and I2P destination
hashes, so it is the only way to learn overlay peers from the network itself. Each entry is reduced to the
census's canonical `host:port`: a public numeric clearnet host (`CensusCatalog.canonicalHost`), a v3 onion
derived from its key, or a `.b32.i2p` name of its hash. I2P has no ports and announces 0; the census and
btcnodes list I2P peers on 8333, so 0 becomes 8333 and the same peer deduplicates across sources. Tor v2,
CJDNS and unknown network ids are skipped, as are entries whose address length does not fit their network. -/

namespace WinnowCensus
open Winnow Winnow.Net Winnow.IO

/-- One gossiped peer. `time` is when the answering node last heard of it (Unix seconds). -/
structure Heard where
  host : String
  port : UInt16
  services : UInt64
  time : UInt32
  deriving BEq, Inhabited, Repr

def Heard.key (h : Heard) : String :=
  if h.host.contains ':' then s!"[{h.host}]:{h.port}" else s!"{h.host}:{h.port}"

def maximumAddresses : Nat := 1_000

/-- BIP155's address length per network id, for the ids the census can dial. -/
def addrV2Length : UInt8 → Option Nat
  | 1 => some 4 | 2 => some 16 | 4 => some 32 | 5 => some 32 | _ => none

private def portOrI2P (overlay : Overlay) (port : UInt16) : UInt16 :=
  if overlay == .i2p && port == 0 then 8333 else port

/-- The canonical host for an `addrv2` network id and address, when the census can dial it. -/
def addrV2Host (network : UInt8) (address : ByteArray) : Option String :=
  match network with
  | 1 => if address.size == 4 then
      CensusCatalog.canonicalHost s!"{address.get! 0}.{address.get! 1}.{address.get! 2}.{address.get! 3}" else none
  | 2 => if address.size == 16 then
      CensusCatalog.canonicalHost (PeerAddress.host { services := 0, ip := address, port := 0 }) else none
  | 4 => if address.size == 32 then some (onionAddress address) else none
  | 5 => if address.size == 32 then some (encodeBase32 address ++ ".b32.i2p") else none
  | _ => none

/-- An `addr` payload's entries the census can dial (`PeerMessage.addr` decoded them). -/
def heardOfAddr (xs : Array PeerAddress) : Array Heard :=
  xs.filterMap fun a => do
    let host ← CensusCatalog.canonicalHost a.host
    guard (a.port != 0)
    return { host, port := a.port, services := a.services, time := a.time.getD 0 }

/-- Decodes an `addrv2` payload (BIP155): how many entries it holds, and those the census can dial. A
malformed payload is an error, as `addr` is for `PeerMessage.decode`. -/
def decodeAddrV2 (payload : ByteArray) : Except Winnow.WireError (Nat × Array Heard) := Wire.eval (do
  let count ← Wire.varInt
  if count.toNat > maximumAddresses then throw (.malformed s!"addrv2 count {count}")
  let mut out : Array Heard := #[]
  for _ in [0:count.toNat] do
    let time ← Wire.u32
    let services ← Wire.varInt
    let network ← Wire.u8
    let address ← Wire.varData 512
    let portLE ← Wire.u16
    let port := (portLE <<< 8) ||| (portLE >>> 8)
    match addrV2Length network with
    | some n =>
      if address.size != n then throw (.malformed s!"addrv2 network {network} address of {address.size} bytes")
    | none => pure ()
    if let some host := addrV2Host network address then
      let port := portOrI2P (Overlay.ofHost host) port
      if port != 0 then out := out.push { host, port, services, time }
  Wire.requireEnd
  return (count.toNat, out)) payload

/-- One `addrv2` entry, as a peer would send it (for the tests). -/
def encodeAddrV2Entry (time : UInt32) (services : UInt64) (network : UInt8) (address : ByteArray) (port : UInt16) :
    ByteArray :=
  u32LE time ++ compactSize services ++ ByteArray.mk #[network] ++ compactSize address.size.toUInt64 ++ address ++
    ByteArray.mk #[(port >>> 8).toUInt8, port.toUInt8]

end WinnowCensus
