import WinnowCensus
import Lean.Data.Json
open WinnowCensus Winnow Winnow.Net Winnow.IO Lean

/-! `census-input`: the day's dial list, and what became of it.

```
census-input gather --date YYYY-MM-DD [--snapshot snapshot.json] [--census census] [--history-days 7]
                    [--seeds] [--gossip-clearnet N] [--gossip-tor N] [--gossip-i2p N] [--gossip-parallel 64]
                    [--gossip-deadline 75] [--gossip-max-age-hours 24] [--gossip-cap 1000]
                    [--tor-socks HOST:PORT] [--i2p-socks HOST:PORT]
                    --out input.txt --sources input-sources.txt --report input.json
census-input annotate --report input.json --sources input-sources.txt --records census.jsonl --summary summary.json
census-input known --known census/known.txt --peers census/peers.json [--keep-days 90]
```

`gather` writes the union of the sources (`Input.lean`) as a plain `host:port` list for the dial, each
endpoint's sources beside it, and a report: the snapshot's state, how many endpoints each source gave and
how many only it gave, and what gossip asked and heard. A missing or degraded snapshot never fails it; an
empty list does. `annotate` adds the report to the dial's summary as `input`, with the dial's outcomes
counted per source, so `input.outcomes.btcnodes` stays comparable with the days the snapshot was the whole
input. `known` enters a published `peers.json` into the history file. -/

def usage : String := "usage: census-input gather|annotate|known … (see CensusInput.lean)"

structure Args where
  values : List (String × String) := []
  flags : List String := []

def parseArgs : List String → Args → Except String Args
  | [], a => .ok a
  | "--seeds" :: rest, a => parseArgs rest { a with flags := "--seeds" :: a.flags }
  | k :: v :: rest, a => if k.startsWith "--" then parseArgs rest { a with values := (k, v) :: a.values }
                         else .error s!"unexpected {k}"
  | [k], _ => .error s!"{k} needs a value"

def Args.get? (a : Args) (k : String) : Option String := a.values.lookup k
def Args.nat (a : Args) (k : String) (d : Nat) : Nat := ((a.get? k).bind String.toNat?).getD d
def Args.req (a : Args) (k : String) : IO String := match a.get? k with
  | some v => pure v | none => throw (IO.userError s!"{k} is required")

def sha256Hex (b : ByteArray) : String := hex (Winnow.sha256 b)

def readIfExists (p : System.FilePath) : IO (Option ByteArray) := do
  if ← p.pathExists then return some (← IO.FS.readBinFile p) else return none

/-- The latest published day before `today` and its summary. -/
def previousSummary (dir : System.FilePath) (today : String) : IO (Option PreviousSnapshot) := do
  if !(← dir.pathExists) then return none
  let days := (← dir.readDir).filterMap fun e =>
    let n := e.fileName
    if n.endsWith ".json" && (CensusCatalog.day (n.dropEnd 5).toString).isSome then some (n.dropEnd 5).toString else none
  let some day := (days.filter (· < today)).qsort (· < ·) |>.back? | return none
  let text ← IO.FS.readFile (dir / s!"{day}.json")
  return (Json.parse text).toOption.map (PreviousSnapshot.ofSummary day)

def overlayCounts (keys : Array (String × Overlay)) : Json :=
  Json.mkObj ([Overlay.clearnet, .tor, .i2p].map fun o => (o.name, toJson (keys.filter (·.2 == o)).size))

def gather (a : Args) : IO UInt32 := do
  let today ← a.req "--date"
  if (CensusCatalog.day today).isNone then throw (IO.userError "--date YYYY-MM-DD")
  let now ← wallSeconds
  let census : System.FilePath := (a.get? "--census").getD "census"
  let socks (k : String) : Option PeerEndpoint := (a.get? k).bind parseHostPort |>.map fun (h, p) => { host := h, port := p }
  let torSocks := socks "--tor-socks"
  let i2pSocks := socks "--i2p-socks"
  let dialable (o : Overlay) : Bool := o == .clearnet || (o == .tor && torSocks.isSome) || (o == .i2p && i2pSocks.isSome)
  let mut list : DialList := {}
  -- btcnodes
  let previous ← previousSummary census today
  let mut btcnodes : List (String × Json) := []
  match a.get? "--snapshot" with
  | none => btcnodes := [("status", "missing")]
  | some path =>
    match ← readIfExists path with
    | none => btcnodes := [("status", "missing")]
    | some bytes =>
      let sha := sha256Hex bytes
      match (String.fromUTF8? bytes).map (Snapshot.parse · sha) with
      | some (.ok s) =>
        let problems := snapshotProblems s previous now
        let mut kept := 0
        for n in s.nodes do
          if let some (k, o) := canonicalKey n then
            if dialable o then list := list.add k o .btcnodes; kept := kept + 1
        btcnodes := [("status", if problems.isEmpty then "ok" else "degraded"), ("problems", toJson problems),
          ("nodes", toJson s.nodes.size), ("dialable", toJson kept), ("sha256", toJson sha),
          ("latestHeight", toJson s.latestHeight), ("timestamp", toJson s.timestamp)]
      | _ => btcnodes := [("status", "unreadable"), ("sha256", toJson sha)]
  if let some p := previous then
    btcnodes := btcnodes ++ [("previous", Json.mkObj [("date", toJson p.date), ("sha256", toJson p.sha256),
      ("nodes", toJson p.nodes)])]
  -- history
  let historyDays := a.nat "--history-days" 7
  let known := Known.parse ((← readIfExists (census / "known.txt")).bind String.fromUTF8? |>.getD "")
  let recent := known.recent today historyDays
  for (k, _) in recent do
    if let some (key, o) := canonicalKey k then
      if dialable o then list := list.add key o .history
  -- seeds
  let mut seedReport : List (String × Json) := []
  if a.flags.contains "--seeds" then
    let found ← seedEndpoints NetworkParams.mainnet.dnsSeeds 8333
    for k in found do list := list.add k .clearnet .seeds
    seedReport := [("seeds", toJson NetworkParams.mainnet.dnsSeeds.size), ("endpoints", toJson found.size)]
  -- gossip
  let mut gossipReport : List (String × Json) := []
  let asks : List (Overlay × Nat) := [(.clearnet, a.nat "--gossip-clearnet" 0), (.tor, a.nat "--gossip-tor" 0),
    (.i2p, a.nat "--gossip-i2p" 0)]
  if asks.any (·.2 > 0) then
    -- the most recently published peers are the likeliest to answer
    let latest := (recent.map (·.2)).foldl (fun a b => if b > a then b else a) ""
    let fresh ← shuffle (recent.filter (·.2 == latest))
    let mut peers := #[]
    for (o, n) in asks do
      if !dialable o then continue
      let mine := (fresh.filterMap fun (k, _) => do
        let (key, o') ← canonicalKey k
        guard (o' == o)
        let (host, port) ← parseHostPort k
        return (key, o, ({ host, port } : PeerEndpoint), if o == .tor then torSocks else if o == .i2p then i2pSocks else none))
      peers := peers ++ mine.extract 0 n
    let t0 ← IO.monoMsNow
    let answers ← askAll peers NetworkParams.mainnet (a.nat "--gossip-parallel" 64) (1000 * a.nat "--gossip-deadline" 75)
    let heard := tally answers now (3600 * a.nat "--gossip-max-age-hours" 24)
    let cap := a.nat "--gossip-cap" 1000
    let mut accepted : Array (String × Overlay) := #[]
    for o in [Overlay.clearnet, .tor, .i2p] do
      let fresh := heard.toArray.filter fun (k, (o', _, _)) => o' == o && !list.contains k && dialable o
      let ranked := fresh.qsort fun (k₁, (_, n₁, t₁)) (k₂, (_, n₂, t₂)) =>
        n₁ > n₂ || (n₁ == n₂ && (t₁ > t₂ || (t₁ == t₂ && k₁ < k₂)))
      for (k, _) in ranked.extract 0 cap do accepted := accepted.push (k, o)
    let alsoKnown := heard.toArray.filter (fun (k, _) => list.contains k) |>.size
    for (k, o) in accepted do list := list.add k o .gossip
    for (k, (o, _, _)) in heard.toArray do
      if list.contains k then list := list.add k o .gossip
    let answered := answers.filter (·.error.isNone)
    let errors := (answers.filterMap (·.error)).foldl (fun (m : Std.HashMap String Nat) e =>
      let short := (e.splitOn ":").head!.take 60 |>.toString
      m.insert short (m.getD short 0 + 1)) {}
    gossipReport := [("asked", overlayCounts (peers.map fun (k, o, _) => (k, o))),
      ("answered", overlayCounts (answered.map fun x => (x.peer, x.overlay))),
      ("addresses", toJson (answers.foldl (· + ·.heard.size) 0)),
      ("usableHeard", overlayCounts (heard.toArray.map fun (k, (o, _)) => (k, o))),
      ("alreadyListed", toJson alsoKnown),
      ("added", overlayCounts accepted),
      ("errors", Json.mkObj (errors.toList.map fun (k, n) => (k, toJson n))),
      ("seconds", toJson (((← IO.monoMsNow) - t0) / 1000))]
  -- write
  let sorted := list.sorted
  if sorted.isEmpty then
    IO.eprintln "census-input: no endpoints from any source"
    return 1
  IO.FS.writeFile (← a.req "--out") (String.join (sorted.toList.map (·.1 ++ "\n")))
  IO.FS.writeFile (← a.req "--sources") list.renderSources
  let counts := list.counts
  let report := Json.mkObj [
    ("date", toJson today), ("endpoints", toJson sorted.size),
    ("byOverlay", overlayCounts (sorted.map fun (k, o, _) => (k, o))),
    ("btcnodes", Json.mkObj btcnodes),
    ("historyDays", toJson historyDays), ("historyKnown", toJson known.size),
    ("sources", Json.mkObj (counts.map fun (s, n, _) => (s, toJson n))),
    ("onlyFrom", Json.mkObj (counts.map fun (s, _, n) => (s, toJson n))),
    ("seeds", Json.mkObj seedReport), ("gossip", Json.mkObj gossipReport)]
  IO.FS.writeFile (← a.req "--report") (report.pretty ++ "\n")
  IO.eprintln <| s!"census-input: {sorted.size} endpoints; " ++
    ", ".intercalate (counts.map fun (s, n, only) => s!"{s} {n} ({only} only there)") ++
    s!"; btcnodes {(Json.mkObj btcnodes).getObjValD "status" |>.compress}"
  return 0

/-- Outcome counts per source over the dial's records. -/
def annotate (a : Args) : IO UInt32 := do
  let some report := (Json.parse (← IO.FS.readFile (← a.req "--report"))).toOption | throw (IO.userError "report")
  let sources := parseSources (← IO.FS.readFile (← a.req "--sources"))
  let summaryPath ← a.req "--summary"
  let some summary := (Json.parse (← IO.FS.readFile summaryPath)).toOption | throw (IO.userError "summary")
  let mut table : Std.HashMap String (Std.HashMap String Nat) := {}
  let mut unmatched := 0
  for line in (← IO.FS.readFile (← a.req "--records")).splitOn "\n" do
    if line.trimAscii.isEmpty then continue
    let some r := (Json.parse line).toOption | throw (IO.userError "record")
    let host := (r.getObjValAs? String "host").toOption.getD ""
    let port := (r.getObjValAs? Nat "port").toOption.getD 0
    let outcome := (r.getObjValAs? String "outcome").toOption.getD "?"
    let some ss := sources.get? (endpointKey host port.toUInt16) | unmatched := unmatched + 1; continue
    let classes := ss.toList.map (·.name) ++ (if ss.contains .btcnodes then [] else ["notInBtcnodes"])
    for c in classes do
      let row := table.getD c {}
      table := table.insert c ((row.insert outcome (row.getD outcome 0 + 1)).insert "dialled" (row.getD "dialled" 0 + 1))
  let outcomes := Json.mkObj (table.toList.map fun (c, row) => (c, Json.mkObj (row.toList.map fun (k, n) => (k, toJson n))))
  let input := report.setObjVal! "outcomes" outcomes |>.setObjVal! "unmatchedRecords" (toJson unmatched)
  IO.FS.writeFile summaryPath ((summary.setObjVal! "input" input).pretty ++ "\n")
  if unmatched > 0 then IO.eprintln s!"census-input: {unmatched} records match no listed endpoint"
  return 0

def knownCommand (a : Args) : IO UInt32 := do
  let path ← a.req "--known"
  let known := Known.parse ((← readIfExists path).bind String.fromUTF8? |>.getD "")
  let some peers := (Json.parse (← IO.FS.readFile (← a.req "--peers"))).toOption | throw (IO.userError "peers.json")
  match known.merge peers (a.nat "--keep-days" 90) with
  | .error e => IO.eprintln s!"census-input known: {e}"; return 1
  | .ok m =>
    IO.FS.writeFile path m.render
    IO.eprintln s!"census-input known: {m.size} endpoints"
    return 0

def main (argv : List String) : IO UInt32 := do
  match argv with
  | cmd :: rest =>
    let a ← IO.ofExcept (parseArgs rest {} |>.mapError IO.userError)
    match cmd with
    | "gather" => gather a
    | "annotate" => annotate a
    | "known" => knownCommand a
    | _ => IO.eprintln usage; return 2
  | [] => IO.eprintln usage; return 2
