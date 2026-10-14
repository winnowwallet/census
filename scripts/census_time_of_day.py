#!/usr/bin/env python3
"""Set an off-hours sample beside the accepted census it followed.

scripts/census_time_of_day.py SAMPLE_DIR [SAMPLE_DIR ...] [--root .]

Each SAMPLE_DIR is a downloaded off-hours artifact (summary.json and
census.jsonl). It is paired with the latest accepted run in health-evidence/
that started before it, within a day, and every endpoint dialled by both is
counted by whether it answered (a version response) in each. If dials failed
at random, as Tor's do, "census only" and "sample only" come out about equal;
a node that keeps daily hours shows up as one outweighing the other. The
census's split and ahead rules mark the odd endpoints, by what they reported
in the census.
"""
import argparse
import collections
import datetime as dt
import gzip
import json
from pathlib import Path

ANSWERED = ('ok', 'noCompactFilters')
SPLIT_HEIGHT = 961_632


def stamp(value):
    return dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def records(lines):
    return {(r['host'], r['port']): r for r in (json.loads(line) for line in lines if line.strip())}


def census_before(root, started):
    best = None
    for path in (root / 'health-evidence' / 'runs').glob('*/summary.json'):
        summary = json.loads(path.read_text())
        begun = stamp(summary['generatedAt'])
        if begun < started and started - begun <= dt.timedelta(days=1):
            if best is None or begun > stamp(best[0]['generatedAt']):
                best = (summary, path.parent)
    return best


def kind(record, tip, split):
    height = record.get('startHeight')
    if type(height) is not int:
        return None
    if split <= height <= split + 20:
        return 'atSplit'
    if height - tip > 100:
        return 'aheadOfTip'
    return None


def compare(census_summary, census_records, sample_records):
    tip = census_summary['observedTip']
    split = census_summary.get('splitHeight', SPLIT_HEIGHT)
    table = collections.defaultdict(collections.Counter)
    for key, late in sample_records.items():
        early = census_records.get(key)
        if early is None:
            continue
        a, b = early['outcome'] in ANSWERED, late['outcome'] in ANSWERED
        cell = 'both' if a and b else 'censusOnly' if a else 'sampleOnly' if b else 'neither'
        groups = [early['network']]
        odd = kind(early, tip, split) if a else None
        if odd:
            groups.append(odd)
        for group in groups:
            table[group][cell] += 1
    return {group: dict(counts) for group, counts in sorted(table.items())}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('samples', type=Path, nargs='+')
    parser.add_argument('--root', type=Path, default=Path('.'))
    args = parser.parse_args()
    for directory in args.samples:
        summary = json.loads((directory / 'summary.json').read_text())
        found = census_before(args.root, stamp(summary['generatedAt']))
        if found is None:
            print(f"{directory}: no accepted census within a day before {summary['generatedAt']}")
            continue
        census, run = found
        with gzip.open(run / 'records.jsonl.gz', 'rt') as stream:
            early = records(stream)
        late = records((directory / 'census.jsonl').read_text().splitlines())
        print(f"census {census['generatedAt']}  sample {summary['generatedAt']}")
        print(f"  {'':10} {'paired':>6} {'both':>6} {'census only':>11} {'sample only':>11} {'neither':>7}")
        for group, c in compare(census, early, late).items():
            total = sum(c.values())
            print(f"  {group:10} {total:6} {c.get('both', 0):6} {c.get('censusOnly', 0):11} "
                  f"{c.get('sampleOnly', 0):11} {c.get('neither', 0):7}")


if __name__ == '__main__':
    main()
