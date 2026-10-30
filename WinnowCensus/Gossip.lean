import Winnow.IO.Transport
import Winnow.IO.Seeds
import WinnowCensus.AddrV2
import WinnowCensus.Input

/-! # Finding peers without btcnodes: DNS seeds and `getaddr`

**Seeds.** Each of the network's DNS seeds is asked through the system resolver for its `x49` name first
(seeders answer `x<hex>.<seed>` with nodes advertising those service bits: 0x49 is NODE_NETWORK, NODE_WITNESS
and NODE_COMPACT_FILTERS), then its plain name if that gave nothing. Seeds answer with clearnet addresses
only.

**Gossip.** A known peer is asked what it knows. This is its own short session, not the wallet's
`PeerConnection`: BIP155 only lets a node send `addrv2` (the format that carries Tor v3 and I2P addresses)
to a peer that said `sendaddrv2` between `version` and `verack`, and the wallet's handshake sends `verack`
at once. The session is `version`; on their `version`, `sendaddrv2` and `verack`; on their `verack`,
`getaddr`; then it listens until an `addr` or `addrv2` of more than one entry arrives (a node announces
itself in a message of one) or the deadline passes. Pings are answered; nothing else is sent. Bitcoin Core
answers `getaddr` once per connection, only on inbound connections (ours are), from a cache it refreshes
about once a day, and flushes its address queue on a timer averaging 30 seconds, hence the long listen.

Overlay peers are asked through the same SOCKS5 gateways the dial uses. What a peer heard is kept only if it
advertises NODE_COMPACT_FILTERS (the wallet cannot use it otherwise), the answering node heard of it within
`maxAgeSeconds`, and, on clearnet, it listens on 8333 (the published list keeps only 8333). -/

namespace WinnowCensus
open Winnow Winnow.Net Winnow.IO Std.Net Std.Async

def compactFilters : UInt64 := (1 : UInt64) <<< 6

/-- What one peer said, or why it said nothing. -/
structure Answer where
  peer : String
  overlay : Overlay
  heard : Array Heard := #[]
  error : Option String := none

private def frame (params : NetworkParams) (m : PeerMessage) : ByteArray :=
  MessageFramer.frame m.command m.payload params.magic

/-- One `getaddr` session with `endpoint` (through `socks` for an overlay peer), ended by `deadlineMs`. -/
def askPeer (endpoint : PeerEndpoint) (socks : Option PeerEndpoint) (params : NetworkParams)
    (deadlineMs : Nat) : IO (Except String (Array Heard)) := do
  let sock ← TCP.Socket.Client.mk
  let closed ← IO.mkRef false
  let close : IO Unit := do
    if ← closed.modifyGet (fun c => (c, true)) then return
    try sock.native.cancelRecv catch _ => pure ()
    try discard <| sock.shutdown.toIO catch _ => pure ()
  after deadlineMs close
  let heard ← IO.mkRef (#[] : Array Heard)
  let answered ← IO.mkRef false
  let session : IO Unit := do
    let target := socks.getD endpoint
    (do sock.connect (← PeerConnection.resolveAddress target.host target.port) : Async Unit).block
    if socks.isSome then
      match ← (PeerConnection.negotiateSOCKS5 sock endpoint).block with
      | .ok () => pure ()
      | .error e => throw (IO.userError e.description)
    let send (m : PeerMessage) : IO Unit := (sock.send (frame params m)).block
    send (.version { version := PeerConnection.protocolVersion, services := 0, timestamp := Int64.ofInt (← wallSeconds),
                     receiver := .unspecified, sender := .unspecified, nonce := ← randomU64,
                     userAgent := PeerConnection.userAgent, startHeight := 0, relay := false })
    let mut framer : MessageFramer := { magic := params.magic }
    repeat
      if ← closed.get then break
      let some chunk ← (sock.recv? ((1 : UInt64) <<< 16)).block | break
      if chunk.isEmpty then break
      framer := framer.append chunk
      repeat
        let (next, f) ← match framer.nextMessage with
          | .ok r => pure r
          | .error e => throw (IO.userError s!"framing: {e.name}")
        framer := f
        let some (command, payload) := next | break
        match PeerMessage.decode command payload with
        | .ok (.version _) => send (.unknown "sendaddrv2" .empty); send .verack
        | .ok .verack => send .getaddr
        | .ok (.ping n) => send (.pong n)
        | .ok (.addr xs) =>
          heard.modify (· ++ heardOfAddr xs)
          if xs.size > 1 then answered.set true
        | .ok (.unknown "addrv2" p) =>
          if let .ok (count, xs) := decodeAddrV2 p then
            heard.modify (· ++ xs)
            if count > 1 then answered.set true
        | _ => pure ()
      if ← answered.get then break
  let outcome ← session.toBaseIO
  close
  let got ← heard.get
  if ← answered.get then return .ok got
  match outcome with
  | .error e => return .error (toString e)
  | .ok () => return if got.isEmpty then .error "no answer before the deadline" else .ok got

/-- Asks every peer, `parallel` at a time, each on its own thread. -/
def askAll (peers : Array (String × Overlay × PeerEndpoint × Option PeerEndpoint)) (params : NetworkParams)
    (parallel deadlineMs : Nat) : IO (Array Answer) := do
  let next ← IO.mkRef 0
  let answers ← IO.mkRef (#[] : Array Answer)
  let worker : IO Unit := do
    repeat
      let i ← next.modifyGet fun i => (i, i + 1)
      let some (key, overlay, endpoint, socks) := peers[i]? | break
      let answer : Answer := match ← askPeer endpoint socks params deadlineMs with
        | .ok heard => { peer := key, overlay, heard }
        | .error e => { peer := key, overlay, error := some e }
      answers.modify (·.push answer)
  let tasks ← (List.range (min parallel peers.size)).mapM fun _ => IO.asTask (prio := .dedicated) worker
  for t in tasks do discard <| IO.wait t
  answers.get

/-- What the network told the census: endpoint → (overlay, how many peers named it, the latest `time`). -/
def tally (answers : Array Answer) (now : Int) (maxAgeSeconds : Nat) :
    Std.HashMap String (Overlay × Nat × UInt32) := Id.run do
  let mut m : Std.HashMap String (Overlay × Nat × UInt32) := {}
  for a in answers do
    let mut seen : Std.HashSet String := {}
    for h in a.heard do
      if h.services &&& compactFilters == 0 then continue
      if now - h.time.toNat > maxAgeSeconds then continue
      let some (key, overlay) := canonicalEndpoint h.host h.port | continue
      if overlay == .clearnet && h.port != 8333 then continue
      if seen.contains key then continue
      seen := seen.insert key
      m := m.alter key fun
        | some (o, n, t) => some (o, n + 1, max t h.time)
        | none => some (overlay, 1, h.time)
  return m

/-- Clearnet endpoints on 8333 from the DNS seeds, `x49.` names first. -/
def seedEndpoints (seeds : Array String) (port : UInt16) : IO (Array String) := do
  let tasks ← seeds.mapM fun s => IO.asTask (prio := .dedicated) do
    let filtered ← SeedResolver.getaddrinfo s!"x49.{s}" port
    if !filtered.isEmpty then return filtered
    SeedResolver.getaddrinfo s port
  let mut out := #[]
  for t in tasks do
    if let .ok es := ← IO.wait t then
      for e in es do
        if let some (key, _) := canonicalEndpoint e.host e.port then
          if !out.contains key then out := out.push key
  return out

end WinnowCensus
