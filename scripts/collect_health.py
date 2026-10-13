#!/usr/bin/env python3
"""Retain accepted daily evidence and update the health baseline independently.

Run only after census-publish accepts the full run. A failure leaves the previous
health.json pointer intact and does not change the peer catalog.
"""
import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from census_health import UTC, accepted, calculate, mining, read, stamp


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        f.write(data)
        name = f.name
    os.replace(name, path)


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()


def select_days(candidates, now):
    selected = {}
    for summary, raw in candidates:
        start, _ = accepted(summary, raw, now)
        if (now.date() - start.date()).days > 29:
            continue
        # Explicit a-priori rule: latest accepted window for each UTC start day.
        # Repeated scans never increase the attempted-day denominator.
        rank = (summary['observationEndedAt'], summary['recordsSHA256'])
        previous = selected.get(start.date())
        if previous is None or rank > previous[0]:
            selected[start.date()] = (rank, summary, raw)
    return [(s, r) for _, s, r in sorted(selected.values(), key=lambda v: v[1]['generatedAt'])]


def collect(root, summary, raw, now, offline=False, clock=lambda: dt.datetime.now(UTC)):
    start, _ = accepted(summary, raw, now)
    archive = root / 'health-evidence' / 'runs' / (start.date().isoformat() + '-' + summary['recordsSHA256'])
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        staged = Path(tempfile.mkdtemp(prefix='.stage-', dir=archive.parent))
        (staged / 'summary.json').write_bytes(encoded(summary))
        (staged / 'records.jsonl.gz').write_bytes(gzip.compress(raw, mtime=0))
        os.rename(staged, archive)
    candidates = []
    for path in sorted((root / 'health-evidence' / 'runs').glob('*/summary.json')):
        if path.parent.name.startswith('.stage-'):
            continue
        candidates.append((json.loads(read(path)), read(path.parent / 'records.jsonl.gz')))
    mining_dir = root / 'health-evidence' / 'mining'
    mining_dir.mkdir(parents=True, exist_ok=True)
    capture_status = 'offline replay; no retrieval attempted'
    if not offline:
        url = 'https://mempool.space/api/v1/mining/hashrate/1m'
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'hashrate.json'
            try:
                result = subprocess.run(['curl', '-fsSL', '--proto', '=https', '--proto-redir', '=https',
                                         '--connect-timeout', '5', '--max-time', '25', '--max-filesize', '2097152',
                                         url, '-o', str(target)], capture_output=True, timeout=30)
                success = result.returncode == 0
            except subprocess.TimeoutExpired:
                success = False
            capture_status = 'captured' if success else 'unavailable; bounded retrieval failed'
            if success:
                captured = clock().replace(microsecond=0)
                content = read(target)
                digest = hashlib.sha256(content).hexdigest()
                meta = dict(schemaVersion=1, url=url, retrievedAt=captured.strftime('%Y-%m-%dT%H:%M:%SZ'),
                            file=digest + '.json', sha256=digest, captureMethod='HTTP response body',
                            observationWindow='Per-point timestamps; current averaging window unavailable')
                try:
                    mining(content, meta, captured)  # Validate before archiving.
                except (ValueError, KeyError, TypeError, OverflowError):
                    capture_status = 'unavailable; mining response failed validation'
                else:
                    atomic(mining_dir / meta['file'], content)
                    atomic(mining_dir / (digest + '-manifest.json'), encoded(meta))
                now = captured
    report = calculate(select_days(candidates, now), now)
    report['selectionPolicy'] = 'Latest accepted observation end per UTC start day; hash breaks exact ties.'
    report['processingRevision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    report['miningCaptureAttempt'] = capture_status
    snapshots = list((root / 'health-evidence').glob('*/mining-manifest.json')) + list(mining_dir.glob('*-manifest.json'))
    available = []
    for path in snapshots:
        meta = json.loads(read(path))
        if stamp(meta['retrievedAt']) <= now:
            available.append((meta['retrievedAt'], path, meta))
    if available:
        _, path, meta = max(available, key=lambda v: v[0])
        report['mining'] = mining(read(path.parent / meta['file']), meta, now)
    nodes = report.pop('nodes')
    eligible = [n['consistencyScore'] for n in nodes if n['consistencyScore'] is not None]
    report['nodeCount'] = len(nodes)
    report['assessedNodeCount'] = len(eligible)
    report['consistencyStatus'] = 'measured' if eligible else 'insufficient_history'
    nodes_data = gzip.compress(encoded({'schemaVersion': 1, 'asOf': report['asOf'], 'nodes': nodes}), mtime=0)
    digest = hashlib.sha256(nodes_data).hexdigest()
    filename = 'health-nodes-' + digest + '.json.gz'
    report['nodesArtifact'] = dict(file=filename, sha256=digest)
    atomic(root / 'census' / filename, nodes_data)
    # Commit pointer last. If anything above fails, the last good report stays.
    atomic(root / 'census' / 'health.json', encoded(report))
    print(f"Health: {len(nodes)} endpoints, {len(report['acceptedDays'])} days, {len(eligible)} assessed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--records', type=Path, required=True)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    collect(args.root.resolve(), json.loads(read(args.summary)), read(args.records),
            dt.datetime.now(UTC).replace(microsecond=0), args.offline)


if __name__ == '__main__':
    main()
