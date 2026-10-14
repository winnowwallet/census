# Measuring Bitcoin health

This is a measurement specification for the next census layer. The existing
peer catalog remains governed by its published contract. A score must not become
an unexplained new rule for selecting wallet peers.

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
Every run is dialled at roughly the same hour, so a node that keeps daily hours is
seen the same way each day; this is not a measure of time-of-day availability.

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

The September 13 accepted run supplies a baseline. It does not establish temporal
consistency. The index is therefore currently unavailable. Collect repeated
observations and mining evidence before publishing a numerical composite.

## Reproduce the baseline

```sh
python3 scripts/census_health.py health-evidence/2026-09-13/manifest.json \
  --mining-manifest health-evidence/2026-09-13/mining-manifest.json \
  --as-of 2026-09-13T18:59:20Z --out health-report.json
```

The manifest points at immutable captured summary and raw records. Add selected
accepted runs to a new manifest to calculate a 30-day series. An explicit
evaluation timestamp makes replay deterministic. The first baseline covers
26,691 endpoints and one accepted day, so every consistency score is null.
A preserved Mempool snapshot supplies estimated hashrate and difficulty; pool
attribution and block intervals remain unavailable. The manifest explicitly
records that capture used JSON text from web retrieval, not HTTP wire bytes.
The component dashboard labels this as a dated experimental baseline. Daily
collection follows each accepted full census. `scripts/collect_health.py`
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
