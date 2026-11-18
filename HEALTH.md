# Measuring Bitcoin health

This is the measurement specification for the census's health layer. Part of it
runs: endpoint consistency is computed after every accepted full census and
published as `census/health.json`. The mining components are partial and the
overall index is not published.

The peer catalog remains governed by its published contract. One rule outside
this repository does select wallet peers by a score: the wallet's build drops
clearnet entries with a low consistency score, as stated under
[Published files and consumers](#published-files-and-consumers). A score must
not become any other rule for selecting wallet peers without being stated
there.

## Endpoint consistency

Use accepted full runs, retaining the original observation windows and raw-record
hashes. Group canonical address-and-port endpoints over a rolling 30-day window.
Count at most one observation per UTC day. Replaying a run never adds evidence.
An endpoint absent from discovery was not attempted; do not count it as a failed
connection. Router outages and rejected runs contribute no endpoint failures.

Publish attempts, successful version responses, successful compact-filter service
handshakes, reported heights within ±100 blocks of that run's reference tip,
observed services, user agent, probe duration, and last observation. A timeout is
an observer result, not proof that the machine is offline. Addresses may change or
represent multiple machines, and correlated daily samples are not independent.

The initial **observed consistency score** is 100 × successful near-tip version
responses / attempts, available only after observations on at least three distinct
days. Always show numerator, denominator, dates, coverage, and the raw daily
results alongside it. Three days is a publication threshold, not a statistical
confidence guarantee. Do not describe this ratio as uptime or node honesty.

The **window census** counts the same population by majority of attempted days
rather than by one day's dial. An endpoint attempted on at least three days counts
under each state it showed on at least half of them: a version response, a height
within 100 blocks of that run's tip, a height within 20 blocks above the BIP-110
split, or a height over 100 blocks above the tip. One lost dial does not remove an
endpoint and one answer does not add it. These count every version response, so
the split and ahead counts are not the daily census's counts among usable peers.
Every scheduled run comes from the same daily cron, so a node that keeps daily
hours is mostly seen the same way each day. GitHub starts scheduled runs late by
a varying amount and a rerun comes later still, so the hour is not fixed; this is
not a measure of time-of-day availability.

Capabilities are separate: compact filters, witness, full or limited block
service, and protocol version where recorded. An old version string alone does
not lower consistency. A node without compact filters is less useful to this
wallet but may validate Bitcoin correctly. Advertisements are claims; verified
filter responses need a separate bounded protocol measurement.

## Network components

Publish time series for response rate, near-tip reports among all version
responders, observed endpoint consistency, advertised services, overlay coverage,
software families, and prefix diversity. Each percentage needs its denominator.
Keep missing dates as gaps. Distinguish a changing discovery population from a
fixed-endpoint longitudinal cohort; otherwise churn can look like improvement.

## Mining components

Preserve dated public mining snapshots with source URL, retrieval time, exact
available observation window, source hash, and processing revision. Include
estimated hashrate, difficulty, block intervals, and pool-attributed block shares
where the source supplies them. Hashrate is estimated from work and elapsed time;
short-window changes include block-arrival noise. More hashpower is not a proof
of decentralization or transaction inclusion.

For pool shares p_i, show HHI = Σ p_i² and effective pool count = 1 / HHI, together
with unknown attribution and the measured block count. Pool attribution is not
ownership, operator independence, or control of every miner's hashpower. Do not
silently treat all unknown blocks as one independent pool. Missing source data
remains unavailable and cannot block or overwrite a good peer census.

Primary API and implementation references:
- https://mempool.space/docs/api/rest
- https://github.com/mempool/mempool
- https://github.com/mempool/mining-pools

## Overall score

An overall **Bitcoin health index** is an experimental, versioned model built
from these components, not a direct measurement or a safety certificate. Publish
normalization, weights, missing-data policy, and sensitivity to alternative
weights before assigning a number. Keep the component dashboard primary. Missing
consistency history or mining evidence must not be replaced with a neutral score,
zero, or an available-component average.

Endpoint consistency is measured: every accepted full census adds a day to the
30-day window, and `census/health.json` says which days the window holds
(`acceptedDays`) and how many endpoints have the three attempted days a score
needs (`assessedNodeCount` of `nodeCount`). The index is still not published:
`overallBitcoinHealthScore` is null. No composite model has been published with
its normalization, weights and missing-data policy, and the mining evidence is
partial: estimated hashrate and difficulty, without pool attribution or block
intervals.

## Published files and consumers

After each accepted full census, `scripts/collect_health.py` writes two files
into `census/`, which the site serves:

- `census/health.json`: `schemaVersion` 1, `modelVersion`
  `"observed-consistency-1"`, `asOf`, `windowStartDate`, `acceptedDays`,
  `nodeCount`, `assessedNodeCount`, `consistencyStatus`, `windowCensus`,
  `definitions`, `selectionPolicy`, `processingRevision`, `evidence`, `mining`,
  `miningCaptureAttempt`, `overallStatus`, `overallBitcoinHealthScore` (null),
  and `nodesArtifact`:
  `{"file": "health-nodes-<sha256>.json.gz", "sha256": "<sha256>"}`, where the
  hash is the SHA-256 of the compressed file its name carries.
- `census/health-nodes-<sha256>.json.gz`: `{"schemaVersion": 1, "asOf": …,
  "nodes": […]}` with one record per endpoint dialled in the window. A record
  has `endpoint` (`host:port`, an IPv6 host in brackets), `network` (`ipv4`,
  `ipv6`, `tor` or `i2p`), `attemptDays`, `responseDays`,
  `nearTipResponseDays`, `splitResponseDays`, `aheadResponseDays`,
  `consistencyScore` (null under three attempted days), `status` (`measured` or
  `insufficient_history`) and `observations`, the daily results.

The nodes file is written first and `health.json`, the pointer to it, last, so
a failed update leaves the previous pair in place. Once the new pointer is
written, the nodes files nothing names are removed. The one the previous
pointer named stays until the next run, for a page that read the old pointer
just before the site was replaced. Earlier nodes files are in this repository's
history, and each can be recomputed from the runs kept in `health-evidence/`.

Three things read them:

- The health page (`assets/health.js`) reads `health.json`.
- The census page's explorer (`assets/explorer.js`) reads `health.json` and
  downloads the nodes file it names on demand.
- The wallet's build. winnow-lean's `scripts/import-census` (as of its
  release/0.9.16) verifies the signature of `census/peers.json`, then applies
  the health record to it before the list is bundled:
  - It filters only when `modelVersion` is `observed-consistency-1`. With any
    other value, or no `health.json`, the list ships unfiltered.
  - `nodesArtifact.file` must be `health-nodes-<64 hex>.json.gz`, with that hex
    equal to `nodesArtifact.sha256` and to the SHA-256 of the file it fetches;
    otherwise the import refuses the census. It also refuses a `health.json`
    over 4 MiB and a nodes file over 64 MiB, or over 1 GiB expanded.
  - Each `peers.json` entry is matched to a record by `endpoint`, and by
    `network`: a clearnet entry to `ipv4` or `ipv6`, a Tor entry to `tor`, an
    I2P entry to `i2p`.
  - A clearnet entry is dropped when its record has a `consistencyScore` under
    70 and `attemptDays` of at least 3. Entries with no record, or with fewer
    attempted days, are kept. If fewer than 200 clearnet entries would remain,
    none are dropped.
  - Tor and I2P entries are kept as published; the import only records how many
    the rule would have dropped.

The thresholds (70, 3 and 200) are the wallet's, set in that script, not here.
What this repository owes the wallet is the meaning of `modelVersion`,
`nodesArtifact`, the nodes file's name and its `endpoint`, `network`,
`consistencyScore` and `attemptDays`. Changing the name or meaning of any of
them needs a new `modelVersion`, so that an import that does not know it ships
the list unfiltered instead of misreading it.

## Reproduce the baseline

```sh
python3 scripts/census_health.py health-evidence/2026-09-13/manifest.json \
  --mining-manifest health-evidence/2026-09-13/mining-manifest.json \
  --as-of 2026-09-13T18:59:20Z --out health-report.json
```

The manifest points at immutable captured summary and raw records. Add selected
accepted runs to a new manifest to calculate a 30-day series. An explicit
evaluation timestamp makes replay deterministic. The first baseline, the
accepted run of 2026-09-13, covers 26,691 endpoints and one accepted day, so
every consistency score in it is null.
A preserved Mempool snapshot supplies estimated hashrate and difficulty; pool
attribution and block intervals remain unavailable. The manifest explicitly
records that capture used JSON text from web retrieval, not HTTP wire bytes.
The health page marks the components experimental and shows the evaluation time
and the accepted days. Daily collection follows each accepted full census. `scripts/collect_health.py`
archives the hash-linked raw records and summary, selects the latest accepted
observation window per UTC start day (hash breaks exact ties), and writes a new
compressed endpoint report before replacing the public component pointer. Multiple
same-day scans count as one day. Old evidence remains retained; calculation uses
the latest 30 days. Mining retrieval is bounded, and its last good snapshot keeps
its original timestamp when a new request fails. Health update failure cannot
block publication of the accepted peer catalog. The tested numerical composite
remains under development.

```sh
python3 scripts/collect_health.py --summary summary.json --records census.jsonl
```

Use `--offline` to reuse preserved mining evidence without a network request.
Per-endpoint downloads expose individual daily outcomes and denominators; they
do not certify that an endpoint belongs to the same machine over time.
