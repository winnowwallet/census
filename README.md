# Winnow peer census

Canonical repository: [winnowwallet/census](https://github.com/winnowwallet/census).
Engineering changes and daily data belong to the Winnow organization.
The existing `winnow-census` Cloudflare Worker and census.winnowwallet.com
domain are retained; the Worker name is a deployment identifier.

Supported BTCNodes Bitcoin endpoints, dialled daily with the same handshake the
[Winnow](https://github.com/winnowwallet/winnow) wallet uses, and published at
**https://census.winnowwallet.com/**.

A successful Winnow version handshake requires advertised `NODE_COMPACT_FILTERS`.
It does not verify a compact-filter response or establish peer honesty. The
numbers describe observed endpoints: handshake outcomes, advertised services, and reported heights. Heights and user agents are claims, not proof of a particular chain or implementation.

## What is here

- `Sources/WinnowCensus` — the tool. Dials a node list (a btcnodes.io snapshot
  or a plain `host:port` file) with Winnow's `PeerConnection`, records what each
  peer reports in its handshake, waits a moment for the BIP133 fee filter, and
  disconnects. Read-only: version, verack, disconnect. Tor and I2P addresses go
  through local SOCKS5 proxies when `--tor-socks` / `--i2p-socks` are given,
  each overlay on its own queue with its own ceiling (`--parallel`,
  `--tor-parallel`, `--i2p-parallel`): a Tor client saturates, rather than
  queues, past a few dozen concurrent rendezvous. `--peer-list` turns a run's
  JSON lines into `census/peers.json`, the wallet's fallback-peer list (below).
- `scripts/census-publish` — files a run's summary under `census/<date>.json`
  and rebuilds `census/index.json`.
- `scripts/census-tables` — Markdown tables from a run's JSON lines, for a
  write-up.
- `.github/workflows/peer-census.yml` — the daily run on a GitHub-hosted macOS
  runner, which installs Tor and i2pd itself, commits the aggregate here, and
  deploys the site.
- `.github/workflows/site.yml` and `wrangler.jsonc` — deploy `index.html` and
  `census/` as a Cloudflare Worker with static assets on every push to main.
  The Worker's custom domain, census.winnowwallet.com, gets its DNS record and
  certificate from Cloudflare on deploy. Needs the `CF_API_TOKEN` and
  `CF_ACCOUNT_ID` secrets; see "Deploying" below.
- `index.html` — the page structure and explanatory copy.
- `assets/census.css` — shared page styles.
- `assets/census.js` — daily census rendering.
- `assets/explorer.js` — optional outcome/transport filters and dated endpoint history.
- `health/index.html` and `assets/health.js` — the standalone network health page.
- `census/` — one aggregate per day, plus the permanent `peers.json` (below).
  Other per-node detail is a two-week workflow artifact; btcnodes already
  publishes the per-IP view.

## The peer list (`census/peers.json`)

The one per-node artifact kept permanently. Each run derives a validated candidate list from the day's JSON lines, and the wallet repo consumes it
at release time to render its bundled fallback peers:

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
Entries are selected by elapsed probe duration with deterministic host, port, user-agent and height tie-breakers. Every entry completed Winnow's
handshake (so it advertises `NODE_COMPACT_FILTERS`) and sits within 100
blocks of the reference tip in either direction. A height outside that tolerance is excluded without assuming why it differs. On top of that:

- **clearnet** satisfies the wallet's PeerPolicyTests invariants: public IP
  literals only (no hostnames), port 8333, at most one entry per IPv4 /16
  (IPv6 /32) netblock.
- **tor** / **i2p** keep their hostnames and any port, and are capped at
  2,000 entries per overlay — when a run yields more, the survivors are the
  lowest elapsed probe duration (including proxy setup and the bounded fee-filter wait).

The per-node JSON lines stay a 14-day workflow artifact; this file is the
carve-out, a product for the wallet rather than a census view.

## Run it yourself

```sh
curl -sL -A winnow-census -o snapshot.json https://btcnodes.io/api/v1/snapshots/latest/
swift run -c release WinnowCensus --input snapshot.json --sample 3000 --out census.jsonl
# with local routers: brew install tor i2pd, then
swift run -c release WinnowCensus --input snapshot.json \
    --tor-socks 127.0.0.1:9050 --i2p-socks 127.0.0.1:4447 \
    --tip "$(python3 -c 'import json;print(json.load(open("snapshot.json"))["latest_height"])')" \
    --out census.jsonl --summary-json summary.json
scripts/census-tables census.jsonl
```

## Reading the numbers

**Endpoints, not nodes.** One node can listen on clearnet, Tor and I2P at once,
and Bitcoin Core deliberately makes linking a node's addresses across networks
hard, so the census cannot tell how many endpoints are doors into the same node.
The census does not estimate unique physical nodes; even multiple clearnet
addresses can belong to one node.

**Heights are claims.** A `version.startHeight` is whatever the peer says. The
tool judges peers against the snapshot's `latest_height` (or the median of
what usable peers report) rather than any top percentile, because nodes on
other chains claim heights well above Bitcoin's. "Behind" and "ahead" both
use a 100-block margin: the snapshot ages a dozen blocks over an hour-long
dial, so honest peers end a few blocks above it, while another chain's nodes
sit thousands above.

**Days can be re-filed.** `WinnowCensus --replay census.jsonl --tip N
--summary-json day.json` rebuilds a day's summary from the run's JSON lines
(the two-week workflow artifact) without dialling, so a changed rule can be
applied to a past day.

The first run, 2026-09-04, and the stall in the wallet that prompted it, are
written up in [One in Twelve Peers Is on a Dead Chain](https://apnewman.com/p/dead-chain-peers/).
The tool began life as a pull request against the wallet's old repository
(since deleted) and moved here so the wallet's history never carries a daily
data commit.

## Signing (`census/peers.json.sig`)

The list is a trust input for the wallet, so every published list must be
signed. The wallet verifies the signature against the public
keys compiled into its `CensusPublisher` (see the wallet's
`docs/census-signing.md`). Ed25519 over the tag `winnow-census-peers-v1\0` and
the file's exact bytes:

```json
{"algorithm":"ed25519","publicKey":"<32 bytes hex>","signature":"<64 bytes hex>"}
```

```sh
WinnowCensus keygen                                   # a fresh secret, printed once, and its public key
WinnowCensus sign --key-env CENSUS_SIGNING_KEY census/peers.json
WinnowCensus verify [--public-key HEX] census/peers.json
```

The secret is stored as the repository's `CENSUS_SIGNING_KEY` Actions secret.
The matching public key is in `census/signing-public-key.txt` and compiled into
the wallet. The daily job signs every accepted list and verifies against that
pinned key before committing or deploying. A missing or mismatched secret
fails publication and leaves the last published list available.

The Site workflow requires the same signature even for direct data changes;
it refuses missing signatures, modified bytes, and signatures from other keys.
Contract tests verify the committed list against the pinned key too.

For rotation, first ship the new public key alongside the old key in the
wallet. Then replace the Actions secret, update the publisher's public key,
and publish a matching signed list together. Remove the old wallet key only
after supported wallet versions trust the replacement. Never commit the
private key or include it in logs.

Onion and I2P entries are sampled by a per-day hash of the address rather than
taken in latency order, so the overlay cap is a sample of the day's reachable
hidden services, not the fastest 2,000 responders (which one operator running
many services could fill). Clearnet keeps the fastest duplicate and one entry
per netblock, as before.

## Deploying

The site is a Cloudflare Worker that serves static assets; `wrangler deploy`
uploads `site/` and creates the custom domain. GitHub Actions does it on every
push to main and after every daily census. Two repository secrets are needed:

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
spellings are normalized before endpoint deduplication. The catalog is capped at
2,000 entries per overlay; the clearnet catalog also requires port 8333 and one
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
```

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
correct filter responses or independent confirmation from BTCNodes, Winnow's
input source. External source failures never affect daily publication.

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
files retain their existing URLs. Historical evidence lives in `comparison/`
and `health-evidence/` and is not part of the website bundle.

## Automatic wallet updates

Before each daily run, `scripts/update-wallet` resolves wallet `main` to an
exact commit and tries the release build, all offline contract tests, and the
preserved comparison replay. Only a passing revision is used for the census.
An incompatible candidate restores both package files; the workflow warns and
rebuilds the previous tested revision so collection can continue. Successful
package updates are committed with the accepted census data. The diagnostic
artifact includes the update log and both package files for reproducibility.

Run `scripts/update-wallet` locally to try the latest wallet revision. A failed
attempt exits nonzero and restores the pin; run `swift build` afterward to
rebuild the previous debug executable if needed. WalletCore provides optional SOCKS5 transport for the census; the GUI wallet
continues to use direct TCP. Overlay catalog validation is maintained here,
so wallet changes cannot silently discard Tor or I2P publication data.

Click an outcome and transport on the census page to filter reported software
and inspect endpoint history. The explorer downloads the existing compressed
health history only on demand and lets readers select an accepted observation
day. When that attempt has no user agent, the latest earlier report is explicitly
counted as historical; missing reports remain Unknown. At most 100 endpoint
rows are rendered; the linked download retains the complete history. The
headline and outcome/transport totals remain the latest daily aggregate.
