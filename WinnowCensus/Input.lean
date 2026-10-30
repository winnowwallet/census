import Lean.Data.Json
import Winnow.IO.Census
import WinnowCensus.Overlay

/-! # The day's dial list, from more than one source

The census used to dial exactly the btcnodes snapshot, so a day btcnodes failed (19 and 22 October 2026) or
served a thin or stale list (23–26 October) was a day lost or skewed. The dial list is now the union of:

* **btcnodes**: the snapshot, when there is one, whatever its state; its state is judged and recorded, never
  a reason to stop. `missing` or `unreadable`: no snapshot. `noTip`: no `latest_height`. `stale`: its
  `timestamp` is more than 36 hours old. `unchanged`: the same bytes as the previous published day's.
  `shrank`: fewer than three quarters of the previous day's nodes.
* **history**: every endpoint the census published in the last `historyDays` days (`census/known.txt`, one
  `host:port day` line per endpoint, the day it was last published).
* **seeds** and **gossip**: clearnet peers from the DNS seeds, and peers of every overlay that known peers
  name when asked (`getaddr`, answered in `addr`/`addrv2`), see `Gossip.lean`.

Each endpoint is reduced to the Swift tool's canonical `host:port` (`PublicationCatalog.canonicalHost`):
numeric public clearnet hosts (`CensusCatalog.canonicalHost`), v3 onions with a valid checksum and
`.b32.i2p` names (`canonicalOverlay`). The sources stay attached to each endpoint (`input-sources.txt`), so
the summary can count btcnodes' own endpoints apart and stay comparable with the days before. -/

namespace WinnowCensus
open Lean Winnow.IO

inductive Source where
  | btcnodes | history | seeds | gossip
  deriving BEq, Inhabited, Repr

def Source.name : Source → String
  | .btcnodes => "btcnodes" | .history => "history" | .seeds => "seeds" | .gossip => "gossip"

def Source.all : List Source := [.btcnodes, .history, .seeds, .gossip]

def Source.ofName? (s : String) : Option Source := Source.all.find? (·.name == s)

/-- `host:port` with IPv6 bracketed. -/
def endpointKey (host : String) (port : UInt16) : String :=
  if host.contains ':' then s!"[{host}]:{port}" else s!"{host}:{port}"

/-- The Swift tool's `parseHostPort`: the last colon splits off a port 1…65535; brackets around an IPv6 host
are removed; the host is lowercased. -/
def parseHostPort (text : String) : Option (String × UInt16) := do
  let text := text.trimAscii.toString
  let cs := text.toList
  let colon ← (List.range cs.length).reverse.find? (cs[·]! == ':')
  let port ← (String.ofList (cs.drop (colon + 1))).toNat?
  guard (0 < port && port < 65_536)
  let mut host := (String.ofList (cs.take colon)).toLower
  if host.startsWith "[" then
    guard (host.endsWith "]")
    host := ((host.drop 1).dropEnd 1).toString
  guard (!host.isEmpty && !host.contains '[' && !host.contains ']')
  return (host, port.toUInt16)

/-- The canonical endpoint and its overlay, or none for a host the census does not dial. -/
def canonicalEndpoint (host : String) (port : UInt16) : Option (String × Overlay) := do
  let overlay := Overlay.ofHost host
  let host ← if overlay == .clearnet then CensusCatalog.canonicalHost host else canonicalOverlay host overlay
  return (endpointKey host port, overlay)

def canonicalKey (text : String) : Option (String × Overlay) := do
  let (host, port) ← parseHostPort text
  canonicalEndpoint host port

/-! ## The btcnodes snapshot -/

structure Snapshot where
  /-- The node keys, as btcnodes lists them. -/
  nodes : Array String
  latestHeight : Option Int
  timestamp : Option Int
  sha256 : String

/-- What the previous published day recorded of its snapshot: the `input.btcnodes` block of its summary, or,
before there was one, `inputSHA256` and `dialled` (the snapshot was the whole input then). -/
structure PreviousSnapshot where
  date : String
  sha256 : Option String
  nodes : Option Nat

def jsonNat? (j : Json) (k : String) : Option Nat := (j.getObjValAs? Nat k).toOption
def jsonStr? (j : Json) (k : String) : Option String := (j.getObjValAs? String k).toOption

def PreviousSnapshot.ofSummary (date : String) (j : Json) : PreviousSnapshot :=
  match j.getObjVal? "input" |>.toOption |>.bind (·.getObjVal? "btcnodes" |>.toOption) with
  | some b => { date, sha256 := jsonStr? b "sha256", nodes := jsonNat? b "nodes" }
  | none => { date, sha256 := jsonStr? j "inputSHA256", nodes := jsonNat? j "dialled" }

def Snapshot.parse (text : String) (sha256 : String) : Except String Snapshot := do
  let j ← Json.parse text
  let .obj nodes ← j.getObjVal? "nodes" | throw "no nodes object"
  let int? (k : String) : Option Int := (j.getObjValAs? Int k).toOption
  return { nodes := nodes.toArray.map (·.1), latestHeight := int? "latest_height", timestamp := int? "timestamp", sha256 }

def staleAfterSeconds : Int := 36 * 3600

/-- Why a snapshot cannot stand for the network today; empty when it can. -/
def snapshotProblems (s : Snapshot) (previous : Option PreviousSnapshot) (now : Int) : Array String := Id.run do
  let mut out := #[]
  if s.latestHeight.all (· ≤ 0) then out := out.push "noTip"
  if s.timestamp.all (now - · > staleAfterSeconds) then out := out.push "stale"
  if let some p := previous then
    if p.sha256 == some s.sha256 then out := out.push "unchanged"
    if let some n := p.nodes then
      if 4 * s.nodes.size < 3 * n then out := out.push "shrank"
  return out

/-! ## History: `census/known.txt` -/

/-- Endpoint → the last day it was published. -/
abbrev Known := Std.HashMap String String

def Known.parse (text : String) : Known := Id.run do
  let mut m : Known := {}
  for line in text.splitOn "\n" do
    match line.trimAscii.toString.splitOn " " with
    | [key, day] =>
      if (CensusCatalog.day day).isSome then
        if let some (k, _) := canonicalKey key then
          if m.get? k |>.all (· < day) then m := m.insert k day
    | _ => pure ()
  return m

/-- Sorted lines, one per endpoint. -/
def Known.render (m : Known) : String :=
  let lines := m.toArray.qsort (fun a b => a.1 < b.1) |>.map fun (k, d) => s!"{k} {d}\n"
  String.join lines.toList

def dayNumber (day : String) : Int := (CensusCatalog.day day).getD 0

/-- `peers.json`'s endpoints entered under its date; entries older than `keepDays` before it are dropped. -/
def Known.merge (m : Known) (peers : Json) (keepDays : Nat) : Except String Known := do
  let date ← peers.getObjValAs? String "date"
  if (CensusCatalog.day date).isNone then throw s!"peers.json date {date}"
  let .obj networks ← peers.getObjVal? "networks" | throw "peers.json has no networks"
  let mut m := m
  for (_, entries) in networks.toArray do
    let .arr entries := entries | throw "peers.json network is not a list"
    for e in entries do
      let host ← e.getObjValAs? String "host"
      let port ← e.getObjValAs? Nat "port"
      if let some (k, _) := canonicalEndpoint host port.toUInt16 then
        if m.get? k |>.all (· < date) then m := m.insert k date
  let horizon := dayNumber date - keepDays
  return m.filter fun _ d => dayNumber d ≥ horizon

/-- The endpoints published within `days` days before `today` (today itself included). -/
def Known.recent (m : Known) (today : String) (days : Nat) : Array (String × String) :=
  let t := dayNumber today
  m.toArray.filter (fun (_, d) => t - dayNumber d < days && dayNumber d ≤ t) |>.qsort (fun a b => a.1 < b.1)

/-! ## The merged list -/

/-- Endpoint → (overlay, sources), in first-seen order. -/
structure DialList where
  order : Array String := #[]
  entries : Std.HashMap String (Overlay × Array Source) := {}

def DialList.add (l : DialList) (key : String) (overlay : Overlay) (source : Source) : DialList :=
  match l.entries.get? key with
  | some (o, ss) => if ss.contains source then l else { l with entries := l.entries.insert key (o, ss.push source) }
  | none => { order := l.order.push key, entries := l.entries.insert key (overlay, #[source]) }

def DialList.contains (l : DialList) (key : String) : Bool := l.entries.contains key

def DialList.sorted (l : DialList) : Array (String × Overlay × Array Source) :=
  (l.order.qsort (· < ·)).filterMap fun k => (l.entries.get? k).map fun (o, ss) => (k, o, ss)

/-- How many endpoints each source gave, and how many only it gave. -/
def DialList.counts (l : DialList) : List (String × Nat × Nat) :=
  Source.all.map fun s =>
    let mine := l.entries.toArray.filter (·.2.2.contains s)
    (s.name, mine.size, (mine.filter (·.2.2.size == 1)).size)

/-- `input-sources.txt`: `host:port<TAB>source,source` per endpoint. -/
def DialList.renderSources (l : DialList) : String :=
  String.join (l.sorted.toList.map fun (k, _, ss) => s!"{k}\t{",".intercalate (ss.toList.map (·.name))}\n")

def parseSources (text : String) : Std.HashMap String (Array Source) := Id.run do
  let mut m := {}
  for line in text.splitOn "\n" do
    match line.splitOn "\t" with
    | [k, ss] => m := m.insert k ((ss.splitOn ",").filterMap Source.ofName? |>.toArray)
    | _ => pure ()
  return m

end WinnowCensus
