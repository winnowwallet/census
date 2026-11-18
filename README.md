# Winnow peer census

Canonical repository: [winnowwallet/census](https://github.com/winnowwallet/census).
Engineering changes and daily data belong to the Winnow organization.
The existing `winnow-census` Cloudflare Worker and census.winnowwallet.com
domain are retained; the Worker name is a deployment identifier.

Bitcoin endpoints, dialled daily with the Winnow wallet's handshake and
published at **https://census.winnowwallet.com/**. The day's list is the
BTCNodes snapshot, the peers the census itself published in the last week, the
DNS seeds, and Tor and I2P peers that known peers name
([below](#where-the-dial-list-comes-from)). The dial runs the Swift app's
connection code ([winnowwallet/winnow](https://github.com/winnowwallet/winnow));
the wallet that ships is
[winnowwallet/winnow-lean](https://github.com/winnowwallet/winnow-lean)
([which code dials](#the-wallet-it-dials-with)).

The census is a hybrid: Lean gathers the dial list and checks the crypto, the
Swift tool dials, writes the summary and the peer list, signs and validates,
Python publishes and computes health, and JavaScript renders the pages.

A successful Winnow version handshake requires advertised `NODE_COMPACT_FILTERS`.
It does not verify a compact-filter response or establish peer honesty. The
numbers describe observed endpoints: handshake outcomes, advertised services, and reported heights. Heights and user agents are claims, not proof of a particular chain or implementation.

## What is here

- `Sources/WinnowCensus`, `Package.swift` — the Swift tool. Dials a node list (a btcnodes.io snapshot
  or a plain `host:port` file) with the Swift app's `PeerConnection`, records what each
  peer reports in its handshake, waits a moment for the BIP133 fee filter, and
  disconnects. Read-only: version, verack, disconnect. Tor and I2P addresses go
  through local SOCKS5 proxies when `--tor-socks` / `--i2p-socks` are given,
  each overlay on its own queue with its own ceiling (`--parallel`,
  `--tor-parallel`, `--i2p-parallel`): a Tor client saturates, rather than
  queues, past a few dozen concurrent rendezvous. `--peer-list` turns a run's
  JSON lines into `census/peers.json`, the signed candidate list each wallet
  build bundles (below). `keygen`, `sign` and `verify` sign the list and check
  its signature; `--validate-peer-list` checks a list against the contract.
- `CensusInput.lean`, `WinnowCensus/`, `CensusTest.lean`, `lakefile.toml`,
  `lake-manifest.json`, `lean-toolchain` — the Lean part. `census-input`
  gathers the day's dial list, adds the `input` block to the summary and keeps
  `census/known.txt`; `census-test` checks the crypto and the host rules (see
  "Moving to Lean"). `scripts/install-lean` installs the toolchain on CI.
- `scripts/census-publish` — validates an accepted run, files its summary under
  `census/<date>.json`, replaces `census/peers.json` and rebuilds
  `census/index.json`.
- `scripts/collect_health.py`, `scripts/census_health.py` — after publication,
  archive the accepted run under `health-evidence/runs/` and write
  `census/health.json` and the `health-nodes-<sha256>.json.gz` it names
  ([HEALTH.md](HEALTH.md)).
- `scripts/census_compare.py` — captures and compares other censuses ("Cross-census
  evidence" below).
- `scripts/census-tables` — Markdown tables from a run's JSON lines, for a
  write-up.
- `scripts/census_time_of_day.py` — sets a downloaded off-hours sample beside
  the census it followed, endpoint by endpoint: answered in both, in one, or in
  neither. Tor's answer rate varies more from run to run than a few hours
  explain, so its time-of-day signal needs many pairs.
- `tests/` — the Python contract tests, which run the built Swift tool, and
  `comparison/2026-09-14-publication-guard/reproduce.py`, the preserved
  rejected-run replay.
- `.github/workflows/peer-census.yml` — the daily run (cron `23 5 * * *`, UTC)
  on a GitHub-hosted macOS runner, which installs Tor and i2pd itself, commits
  the aggregate here, and deploys the site. A second schedule (cron
  `23 17 * * *`, twelve hours on) runs the same steps, gathers its own list,
  dials the first 3,000 endpoints of that list's seeded order and publishes
  nothing; its records stay in the two-week artifact. GitHub starts scheduled
  runs late (by hours, on the runs of 15–17 November 2026), so neither cron
  time is the hour of the dial.
- `.github/workflows/census-retry.yml` — reruns a scheduled census once when
  the step that starts Tor and I2P, or the publication step, failed.
- `.github/workflows/test.yml` — on pull requests and on pushes to main that
  touch the code: builds the Swift tool, runs the Python tests and the
  comparison replay, and, in its `lean` job, builds and runs `census-test`.
- `.github/workflows/site.yml` and `wrangler.jsonc` — deploy `index.html`,
  `assets/`, `health/` and `census/` as a Cloudflare Worker with static assets
  on a push to main that changes any of them (or `wrangler.jsonc`, or the
  workflow), after the Swift tool has validated `census/peers.json` and its
  signature. The daily run deploys itself.
  The Worker's custom domain, census.winnowwallet.com, gets its DNS record and
  certificate from Cloudflare on deploy. Needs the `CF_API_TOKEN` and
  `CF_ACCOUNT_ID` secrets; see "Deploying" below.
- `index.html` — the page structure and explanatory copy.
- `assets/census.css` — shared page styles.
- `assets/census.js` — daily census rendering.
- `assets/explorer.js` — optional outcome/transport filters and dated endpoint history.
- `health/index.html` and `assets/health.js` — the standalone network health page.
- `gateways/` — the reproducible Tor and I2P gateway VMs the wallet's
  Automatic routing discovers on the tailnet ([guide](gateways/README.md)).
  The I2P census mirror it used to describe is retired.
- `census/` — what the site serves. One aggregate per day (`<date>.json`) and
  `index.json`; `peers.json`, `peers.json.sig` and `signing-public-key.txt`
  (below); `known.txt`, the census's own history of published endpoints;
  `health.json` and the `health-nodes-<sha256>.json.gz` it names, which holds
  every endpoint's daily outcomes over the 30-day window
  ([HEALTH.md](HEALTH.md)). Each day writes a new `health-nodes` file and the
  earlier ones stay in the directory.
- `health-evidence/` — every accepted run's summary and full per-node records
  (`runs/<date>-<records sha256>/`, compressed) and the mining snapshots,
  committed by the daily run. Each run's working files (snapshot, dial list,
  JSON lines, router logs) are also a two-week workflow artifact.
- `comparison/` — dated cross-census evidence ("Cross-census evidence" below).
- `HEALTH.md` — the health measurements, the files they publish and what reads
  them.

## Moving to Lean

The census is moving to Lean, onto the Winnow wallet's own Lean peer code (winnowwallet/winnow-lean's `Lean/`
package, pinned in `lakefile.toml`), replacing the Swift tool, the Python scripts and the JavaScript pages:
the site will be static HTML written by Lean. The published files (`census/*.json`, `peers.json` and its
signature) keep their formats and the signing key, so wallet builds that import them are unaffected. The
format includes the bytes: winnow-lean's `scripts/import-census` applies its health filter only when
re-serializing `peers.json` the way the Swift tool writes it (`JSONEncoder`, pretty-printed, sorted keys)
reproduces the signed bytes, and ships the list unfiltered otherwise.

In Lean today (`WinnowCensus/`):

- The dial list: `census-input` (`CensusInput.lean`, `Input.lean`, `Gossip.lean`, `AddrV2.lean`). The daily
  run uses it to gather the list, add the `input` block to the summary and update `census/known.txt` (next
  section).
- Ed25519 (RFC 8032; key generation, signing, cofactored verification), SHA3-256 and base32 with the Tor and
  I2P host checks (`Crypto/`, `Overlay.lean`). No Lean executable signs yet: the daily run signs and verifies
  with the Swift tool.

`lake build census-test && .lake/build/bin/census-test` holds the crypto to RFC 8032's and FIPS 202's
vectors, RFC 4648's, the Python tests' onion addresses, the Swift tool's known answer, every overlay host in
`census/peers.json`, and the published `peers.json.sig`, and checks `addrv2` decoding, snapshot parsing,
the history file and the merged dial list.

Still Swift: the dial, the summary, `peers.json`, signing and verification, and list validation. Still
Python: publication (`scripts/census-publish`), health (`scripts/collect_health.py`) and the contract tests.
Still JavaScript: the pages (`assets/`). The Swift tool runs the census until the Lean one matches it.

### Where the dial list comes from

The census no longer depends on btcnodes alone. `census-input gather` (`CensusInput.lean`,
`WinnowCensus/Input.lean`, `WinnowCensus/Gossip.lean`) gathers the day's list before the dial from:

- **btcnodes**: the snapshot, when there is one. Its state is recorded, never a reason to stop: `missing`,
  `unreadable`, or `degraded` for `noTip`, `stale` (over 36 hours old), `unchanged` (the previous day's bytes)
  or `shrank` (under three quarters of the previous day's nodes).
- **history**: the endpoints the census published in the last 7 days, from `census/known.txt` (one
  `host:port day` line each, the day it was last published; entries leave after 90 days). Longer gains
  nothing: on 2026-10-31, of the published peers missing from btcnodes, 48% of those last published a day
  earlier answered, 10–15% of those two to seven days old, and none of 728 older ones.
- **seeds**: the DNS seeds' `x49` names (nodes serving compact filters), clearnet only.
- **gossip**: Tor and I2P peers from history are asked `getaddr` after `sendaddrv2` (BIP155), and the
  overlay peers they name that advertise compact filters and were heard of within a day are added, at most
  1,000 per overlay. Clearnet gossip is off: 1,000 such endpoints yielded 3 usable peers on 2026-10-31,
  and 4 of the 1,000 that Tor and I2P peers named on 2026-10-30.

The first full run on these inputs (diagnostic, 2026-10-30, unpublished): 21,696 endpoints, 18,561 of them
btcnodes'. Of the 3,135 btcnodes did not list, 626 were usable: on Tor, 102 of 245 found only by gossip and
63 of 827 only in history; on I2P, 85 of 129 and 59 of 217. Its list had 2,875 Tor, 2,895 I2P and 995
clearnet peers, where that morning's published list had 2,472, 2,810 and 939.

Without any snapshot, history and seeds alone gave 973 publishable clearnet peers on 2026-10-31, where
btcnodes' list had given 1,140 the day before. `census-input annotate` puts the report into the day's
summary as `input`, with the dial's outcomes counted per source: `input.outcomes.btcnodes` counts only the
snapshot's endpoints, comparable with the days before 2026-10-30, when the snapshot was the whole input
(`census/2026-10-30.json` is the first published summary with an `input` block).

## The peer list (`census/peers.json`)

The per-node product for the wallet. Each run derives a validated candidate list from the day's JSON lines.
The wallet does not download it: each build of winnow-lean bundles the list
current at build time. Its `scripts/import-census` takes `peers.json` and
`peers.json.sig` at one census commit, verifies the signature, drops the
clearnet entries the health record scores as inconsistent
([HEALTH.md](HEALTH.md#published-files-and-consumers)), holds the result to the
app's own decoder and writes `build/census/peers.json`, which the app ships.
The app itself downloads no list and checks no signature. The Swift tool
writes the file:

```sh
WinnowCensus --peer-list census.jsonl --tip HEIGHT --out census/peers.json
```

```json
{
  "schemaVersion": 1,
  "date": "2026-09-13",
  "tip": 966774,
  "networks": {
    "clearnet": [{"host": "1.2.3.4", "port": 8333, "userAgent": "/Satoshi:31.1.0/", "startHeight": 966770}],
    "tor":      [{"host": "abc…xyz.onion", "port": 8333, "userAgent": "…", "startHeight": 966770}],
    "i2p":      [{"host": "….b32.i2p", "port": 8333, "userAgent": "…", "startHeight": 966770}]
  }
}
```

`date` is the original observation day (UTC), preserved during replay, `tip` the height the run judged peers against.
Where clearnet records are the same endpoint or share a netblock, the one with the shortest probe duration is kept, with deterministic host, port, user-agent and height tie-breakers; a duplicate Tor or I2P endpoint is chosen by a per-day hash of the address, not by latency. Each network is listed in host and port order. Every entry completed Winnow's
handshake (so it advertises `NODE_COMPACT_FILTERS`) and sits within 100
blocks of the reference tip in either direction. A height outside that tolerance is excluded without assuming why it differs. On top of that:

- **clearnet** satisfies the wallet's PeerPolicyTests invariants: public IP
  literals only (no hostnames), port 8333, at most one entry per IPv4 /16
  (IPv6 /32) netblock.
- **tor** / **i2p** keep their hostnames and any port, and list every
  verified service; there is no per-overlay cap. The file must stay within
  the wallet's 4 MB and 65,536-entry bounds, or publication fails and the
  last good list stays up.

The run's JSON lines are a 14-day workflow artifact, and an accepted run's are
also committed, compressed, under `health-evidence/runs/`
([HEALTH.md](HEALTH.md)). This file is a product for the wallet rather than a
census view.

## Run it yourself

```sh
curl -sL -A winnow-census -o snapshot.json https://btcnodes.io/api/v1/snapshots/latest/
swift run -c release WinnowCensus --input snapshot.json --sample 3000 --out census.jsonl
# the day's full list, as the daily run gathers and dials it. With local routers
# (brew install tor i2pd) and the Lean toolchain that lean-toolchain names:
lake build census-input
.lake/build/bin/census-input gather --date "$(date -u +%Y-%m-%d)" --snapshot snapshot.json --census census \
    --history-days 7 --seeds --gossip-tor 150 --gossip-i2p 150 --gossip-parallel 48 --gossip-deadline 90 \
    --tor-socks 127.0.0.1:9050 --i2p-socks 127.0.0.1:4447 \
    --out input.txt --sources input-sources.txt --report input.json
swift run -c release WinnowCensus --input input.txt \
    --tor-socks 127.0.0.1:9050 --i2p-socks 127.0.0.1:4447 \
    --out census.jsonl --summary-json summary.json
.lake/build/bin/census-input annotate --report input.json --sources input-sources.txt \
    --records census.jsonl --summary summary.json
scripts/census-tables census.jsonl
```

`gather` lists Tor and I2P endpoints only when their SOCKS port is given;
without `--tor-socks` and `--i2p-socks` the list is clearnet alone. The daily
run's concurrency and timeouts are in `.github/workflows/peer-census.yml`.

## Reading the numbers

**Endpoints, not nodes.** One node can listen on clearnet, Tor and I2P at once,
and Bitcoin Core deliberately makes linking a node's addresses across networks
hard, so the census cannot tell how many endpoints are doors into the same node.
The census does not estimate unique physical nodes; even multiple clearnet
addresses can belong to one node.

**Heights are claims.** A `version.startHeight` is whatever the peer says. The
tool judges peers against the median height that usable peers report (or a
`--tip` override) rather than any top percentile, because nodes on other
chains claim heights well above Bitcoin's. "Behind" and "ahead" both use a
100-block margin; another chain's nodes sit thousands above. The daily run
logs the snapshot's `latest_height` only as a cross-check and warns when it
is more than 100 blocks from the median: on 2026-09-29 a stale snapshot tip
made every honest peer look ahead, and publication was refused.

**Days can be re-filed.** `WinnowCensus --replay census.jsonl --tip N
--summary-json day.json` rebuilds a day's summary from the run's JSON lines
(the two-week workflow artifact, or an accepted run's `records.jsonl.gz` under
`health-evidence/runs/`, uncompressed: the same bytes) without dialling, so a
changed rule can be applied to a past day.

The first run, 2026-09-04, and the stall in the wallet that prompted it, are
written up in [One in Twelve Peers Is on a Dead Chain](https://apnewman.com/p/dead-chain-peers/).
The tool began life as a pull request against the wallet's old repository
(since deleted) and moved here so the wallet's history never carries a daily
data commit.

## Signing (`census/peers.json.sig`)

The list is a trust input for the wallet, so every published list must be
signed. The signature is checked when a wallet build imports the list, not in
the app: winnow-lean's `scripts/import-census` refuses a list whose
`census/peers.json.sig` does not verify (`scripts/ed25519_verify.py`) under a
key pinned in its `scripts/census-public-key.txt`, or names another key. The
wallet's side is in its
[census signing guide](https://winnowwallet.com/census-signing.md). Ed25519
over the tag `winnow-census-peers-v1\0` and the file's exact bytes:

```json
{"algorithm":"ed25519","publicKey":"<32 bytes hex>","signature":"<64 bytes hex>"}
```

```sh
WinnowCensus keygen                                   # a fresh secret, printed once, and its public key
WinnowCensus sign --key-env CENSUS_SIGNING_KEY census/peers.json
WinnowCensus verify [--public-key HEX] census/peers.json
```

The secret is stored as the repository's `CENSUS_SIGNING_KEY` Actions secret.
The matching public key is in `census/signing-public-key.txt` and pinned in
winnow-lean's `scripts/census-public-key.txt`. The daily job signs every
accepted list and verifies it against `census/signing-public-key.txt` before
committing or deploying. A missing or mismatched secret
fails publication and leaves the last published list available.

The Site workflow requires the same signature even for direct data changes;
it refuses missing signatures, modified bytes, and signatures from other keys.
Contract tests verify the committed list against the pinned key too.

For rotation, first add the new public key to winnow-lean's
`scripts/census-public-key.txt`, one key per line beside the old one, so a
build accepts a list signed by either. Then replace the Actions secret, update
`census/signing-public-key.txt`, and publish a matching signed list together.
Remove the old key from the wallet's pin when no list signed by it needs to
ship. Installed apps carry the list they were built with and check no
signature, so a rotation does not reach them. Never commit the private key or
include it in logs.

Onion and I2P entries are not capped: every hidden service that answered at
the tip with compact filters is published, so no latency ranking decides
which ones a wallet sees. Clearnet keeps the fastest duplicate and one entry
per netblock, as before.

## Deploying

The site is a Cloudflare Worker that serves static assets; `wrangler deploy`
uploads `site/` and creates the custom domain. GitHub Actions does it on a push
to main that changes the site's files and after every published daily census.
Two repository secrets are needed:

- `CF_ACCOUNT_ID` — the account ID, shown on the right of any zone's
  Overview page in the Cloudflare dashboard.
- `CF_API_TOKEN` — an API token made from the **Edit Cloudflare Workers**
  template (My Profile → API Tokens → Create Token), plus **Zone → DNS →
  Edit**, with **Zone Resources** set to include `winnowwallet.com` so the
  custom domain and its DNS record can be created. If a `census` DNS record
  already exists in the zone, delete it before the first deploy; wrangler will
  not overwrite one.

Nothing else is configured by hand: no DNS record, no Pages project.

## Publication contract and replay

The census uses `WalletCore.CensusCatalog` for current clearnet address, schema,
date, height and diversity validation. Its own `PublicationCatalog` preserves
and validates Tor and I2P entries for publication. Tor v3 names include checksum/version validation;
I2P b32 names are canonical 32-byte destinations. IPv4-mapped aliases and IPv6
spellings are normalized before endpoint deduplication. Overlays are not capped
beyond the wallet's list bounds; the clearnet catalog also requires port 8333 and one
address per IPv4 /16 or IPv6 /32.

`--summary-json` writes its aggregate and a sibling `peers.json` from the same
records. Each record carries the original run start, completion timestamp,
sample size, expected record count and source snapshot hash. The aggregate
preserves that observation window separately from its processing timestamp and
includes hashes linking the raw records and peer list. Replaying an old file
without observation metadata requires its known original `--observed-at` UTC
instant; this diagnostic replay does not acquire full-run provenance.

Publication requires a complete unsampled run covering clearnet, Tor and I2P,
with at least 50% version-handshake success on each overlay. The publisher checks
the shared peer contract and all hashes before changing files. Failures preserve
the previous published data. Historical replays cannot roll the live catalog
backwards. Missing dates remain absent rather than synthetic zeroes.

```sh
scripts/census-publish summary.json --peers peers.json --records census.jsonl --dir census
swift build
python3 -m unittest discover -s tests -v
lake build census-test census-input && .lake/build/bin/census-test
```

The Python tests run the Swift tool that `swift build` leaves in
`.build/debug/` (or the one `CENSUS_BINARY` names).

## Cross-census evidence

`python3 scripts/census_compare.py capture --out comparison/NEW-SNAPSHOT`
captures BTCNodes, Bitnod.es, 21 Ninja and Coin Dance independently. Add
`--btcnodes snapshot.json --winnow-summary census/YYYY-MM-DD.json
--winnow-records census.jsonl` to preserve the exact input and linked full-run
observations. `compare comparison/NEW-SNAPSHOT` repeats normalization offline,
verifies hashes, and produces JSON and Markdown results. A capture directory is
immutable; choose a new directory for a new observation.

Every result records source URLs, retrieval details, source hashes, processing
revision and tool hash. Unknown windows, changed markup and missing metrics are
explicitly unavailable or inconclusive. Endpoint overlap compares named stages;
service-bit percentages are calculated only over the same version-responding
endpoint intersection within the stated timing bound. This does not establish
correct filter responses or independent confirmation from BTCNodes, the
largest source of Winnow's dial list. External source failures never affect
daily publication.

Method references: [BTCNodes](https://btcnodes.io/),
[Bitnod.es](https://www.bitnod.es/) (eight-day unresponsive retention),
[21 Ninja methodology](https://21.ninja/reachable-nodes/methodology/), and
[Coin Dance](https://coin.dance/nodes) (address deduplication).

## Website development

The dashboard is a static page with no frontend build step or dependencies.
From the repository root, run `python3 -m http.server 8000` and open
`http://localhost:8000`. Opening the HTML directly from disk will not load the
JSON observations. Both deployment workflows copy `index.html`, `assets/`, `health/`, and
`census/` into `site/`; keep these inputs together when previewing or deploying.

The daily dashboard at `/` and experimental network health page at `/health/`
load independently, so a missing health artifact cannot hide the census. Published JSON and signature
files retain their existing URLs. `comparison/` and `health-evidence/` are not
part of the website bundle; the health files under `census/` are.

## The wallet it dials with

Two wallet codebases are involved, pinned differently.

**The dial: the Swift app.** `Package.swift` names the `main` branch of
[winnowwallet/winnow](https://github.com/winnowwallet/winnow), the Swift app,
and `Package.resolved` is not committed, so a fresh checkout, including every
daily run, resolves that branch's newest WalletCore; `swift package update`
moves an existing checkout. As of 2026-11-18 (UTC), that branch had last changed
on 2026-10-25. The daily run builds it, then runs the offline contract tests
and the preserved comparison replay; if either fails, nothing is published
that day. The run's artifact keeps the resolved `Package.resolved`, which
names the exact wallet commit that dialled. The census dials Tor and I2P
through WalletCore's SOCKS5 transport. Overlay catalog validation is
maintained here, so wallet changes cannot silently discard Tor or I2P
publication data.

**The dial list: the Lean wallet.** The wallet that ships is
[winnowwallet/winnow-lean](https://github.com/winnowwallet/winnow-lean).
`lakefile.toml` and `lake-manifest.json` pin its `Lean/` package at `a3ade55`
(its tag v0.9.11), and `census-input` builds on that: the wire framing and
messages, SOCKS5 negotiation, the DNS seed resolver, the bounded JSON parser
and the `CensusCatalog` host rules. Its `getaddr` session is its own, not the
wallet's `PeerConnection` (`WinnowCensus/Gossip.lean`). Moving the pin means
changing both files.

Both wallets announce protocol version 70016 and the user agent
`/winnow:0.1/` (`Sources/WalletCore/Network/Transport/PeerConnection.swift` in
winnow, `Lean/Winnow/IO/Transport.lean` in winnow-lean), but the handshake the
census records is the Swift code's. The wallet dials clearnet peers directly
and reaches Tor and I2P peers through SOCKS5 gateways the user runs
(`gateways/`); when a gateway answers, it sends every peer through Tor or I2P.

Click an outcome and transport on the census page to filter reported software
and inspect endpoint history. The explorer downloads the existing compressed
health history only on demand and lets readers select an accepted observation
day. When that attempt has no user agent, the latest earlier report is explicitly
counted as historical; missing reports remain Unknown. At most 100 endpoint
rows are rendered; the linked download retains the complete history. The
headline and outcome/transport totals remain the latest daily aggregate.
