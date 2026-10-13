import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from census_health import calculate, mining
from collect_health import collect, select_days


def run(day=13, height=100, outcome='ok'):
    stamp = f'2026-09-{day:02d}T12:00:00Z'
    records = []
    for host, network in [('8.8.8.8', 'clearnet'), ('a' * 56 + '.onion', 'tor'), ('a' * 52 + '.b32.i2p', 'i2p')]:
        records.append(dict(host=host, port=8333, network=network, runStartedAt=stamp,
                            observedAt=stamp, runSample=0, inputSHA256='a' * 64,
                            outcome=outcome, startHeight=height, services=64,
                            userAgent='/old-version/', latencyMs=1))
    raw = ('\n'.join(json.dumps(r) for r in records) + '\n').encode()
    summary = dict(generatedAt=stamp, observationEndedAt=stamp, completeRun=True,
                   sample=0, recordsSHA256=hashlib.sha256(raw).hexdigest(),
                   observedTip=100, dialled=3, expectedRecords=3,
                   inputSHA256='a' * 64, processingRevision='b' * 40,
                   networks={n: dict(dialled=1, usable=1, noCompactFilters=0)
                             for n in ('clearnet', 'tor', 'i2p')})
    return summary, raw


class HealthTests(unittest.TestCase):
    now = dt.datetime(2026, 9, 13, 18, tzinfo=dt.timezone.utc)

    def test_one_day_and_replay_do_not_claim_consistency(self):
        report = calculate([run(), run()], self.now)
        self.assertEqual(len(report['acceptedDays']), 1)
        self.assertTrue(all(n['consistencyScore'] is None for n in report['nodes']))
        self.assertIsNone(report['overallBitcoinHealthScore'])

    def test_gaps_are_not_failures_and_old_software_has_no_penalty(self):
        report = calculate([run(9), run(11), run(13)], self.now)
        for node in report['nodes']:
            self.assertEqual(node['attemptDays'], 3)
            self.assertEqual(node['consistencyScore'], 100)

    def test_extreme_and_negative_heights_do_not_overflow(self):
        report = calculate([run(9), run(11, 2**128), run(13, -1)], self.now)
        for node in report['nodes']:
            self.assertAlmostEqual(node['consistencyScore'], 100 / 3)

    def test_future_partial_hash_and_overlay_failures_rejected(self):
        cases = [('sample', 1), ('completeRun', False), ('recordsSHA256', 'bad'),
                 ('expectedRecords', 4), ('observationEndedAt', '2099-01-01T00:00:00Z')]
        for key, value in cases:
            summary, raw = run()
            summary[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                calculate([(summary, raw)], self.now)
        summary, raw = run()
        summary['networks']['tor']['usable'] = 0
        with self.assertRaises(ValueError):
            calculate([(summary, raw)], self.now)

    def test_different_same_day_run_requires_selection(self):
        with self.assertRaises(ValueError):
            calculate([run(13, 99), run(13, 100)], self.now)

    def test_run_order_does_not_change_report(self):
        runs = [run(9), run(11), run(13)]
        self.assertEqual(calculate(runs, self.now), calculate(list(reversed(runs)), self.now))

    def test_mining_units_and_missing_components(self):
        source = dict(hashrates=[dict(timestamp=int(self.now.timestamp()), avgHashrate=2e18)],
                      currentHashrate=3e18, currentDifficulty=100)
        raw = json.dumps(source).encode()
        meta = dict(schemaVersion=1, sha256=hashlib.sha256(raw).hexdigest(), retrievedAt='2026-09-13T17:00:00Z')
        result = mining(raw, meta, self.now)
        self.assertEqual(result['currentHashrateEHs'], 3)
        self.assertEqual(result['hashrateSeries'][0]['hashrateEHs'], 2)
        self.assertIsNone(result['poolConcentration'])
        self.assertIsNone(result['blockInterval'])
        meta['sha256'] = 'invalid'
        with self.assertRaises(ValueError):
            mining(raw, meta, self.now)

    def test_mining_rejects_future_duplicate_and_nonfinite_data(self):
        for points in [
            [dict(timestamp=int(self.now.timestamp()) + 1, avgHashrate=1e18)],
            [dict(timestamp=1, avgHashrate=1e18)] * 2,
            [dict(timestamp=1, avgHashrate=float('nan'))]]:
            raw = json.dumps(dict(hashrates=points, currentHashrate=1e18, currentDifficulty=100)).encode()
            meta = dict(schemaVersion=1, sha256=hashlib.sha256(raw).hexdigest(), retrievedAt='2026-09-13T17:00:00Z')
            with self.assertRaises(ValueError):
                mining(raw, meta, self.now)

    def test_daily_selection_is_explicit_and_deterministic(self):
        early = run(13, 99)
        late = run(13, 100)
        late[0]['observationEndedAt'] = '2026-09-13T13:00:00Z'
        self.assertEqual(select_days([early, late], self.now), [late])
        self.assertEqual(select_days([late, early], self.now), [late])

    def test_collection_preserves_good_pointer_on_failure_and_replay(self):
        with tempfile.TemporaryDirectory() as temporary, patch('collect_health.subprocess.check_output', return_value='a' * 40):
            root = Path(temporary)
            summary, raw = run()
            collect(root, summary, raw, self.now, offline=True)
            output = root / 'census/health.json'
            previous = output.read_bytes()
            report = json.loads(previous)
            self.assertEqual(report['assessedNodeCount'], 0)
            artifact = root / 'census' / report['nodesArtifact']['file']
            self.assertEqual(hashlib.sha256(artifact.read_bytes()).hexdigest(), report['nodesArtifact']['sha256'])
            collect(root, summary, raw, self.now, offline=True)
            self.assertEqual(output.read_bytes(), previous)
            summary['sample'] = 1
            with self.assertRaises(ValueError):
                collect(root, summary, raw, self.now, offline=True)
            self.assertEqual(output.read_bytes(), previous)

    def test_invalid_mining_capture_keeps_previous_snapshot_and_updates_nodes(self):
        with tempfile.TemporaryDirectory() as temporary, patch('collect_health.subprocess.check_output', return_value='a' * 40):
            root = Path(temporary)
            previous = root / 'health-evidence' / 'mining'
            previous.mkdir(parents=True)
            content = json.dumps(dict(hashrates=[dict(timestamp=1, avgHashrate=2e18)],
                                      currentHashrate=3e18, currentDifficulty=100)).encode()
            (previous / 'previous.json').write_bytes(content)
            metadata = dict(schemaVersion=1, file='previous.json', retrievedAt='2026-09-12T17:00:00Z',
                            sha256=hashlib.sha256(content).hexdigest())
            (previous / 'previous-manifest.json').write_text(json.dumps(metadata))

            def invalid_response(command, **kwargs):
                Path(command[-1]).write_text('{"hashrates": []}')
                return type('Result', (), {'returncode': 0})()

            with patch('collect_health.subprocess.run', side_effect=invalid_response):
                collect(root, *run(), self.now, clock=lambda: self.now)
            report = json.loads((root / 'census/health.json').read_text())
            self.assertEqual(report['nodeCount'], 3)
            self.assertEqual(report['mining']['source'], metadata)
            self.assertEqual(report['miningCaptureAttempt'], 'unavailable; mining response failed validation')
            self.assertEqual(len(list(previous.glob('*-manifest.json'))), 1)
