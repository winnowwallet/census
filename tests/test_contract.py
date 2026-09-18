"""Offline contract/publication fixtures; run after `swift build`."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('CENSUS_BINARY', ROOT / '.build/debug/WinnowCensus'))
DATE = '2026-09-11T07:08:08Z'
# Ed25519 seed 0x01×32 over the domain tag and b'{"date":"2026-09-14"}'.
KAT_PUBLIC_KEY = '8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c'
KAT_SIGNATURE = ('bdaac83b679535934fb1337a5bf40bc6e666cb040c0f8d83dbdbf7b88b7c187b'
                 'b8a344182895dab82b646cd88e4236e4096f0a6fca6fefe661ba972fbbd78209')

def onion(n):
    key = n.to_bytes(32, 'big')
    checksum = hashlib.sha3_256(b'.onion checksum' + key + b'\x03').digest()[:2]
    return base64.b32encode(key + checksum + b'\x03').decode().lower() + '.onion'

def record(host, height=900_000, outcome='ok', latency=10):
    return dict(host=host, port=8333, outcome=outcome, userAgent='/Satoshi:30/',
                startHeight=height, services=64, latencyMs=latency,
                network='tor' if host.endswith('.onion') else 'i2p' if host.endswith('.i2p') else 'clearnet',
                runStartedAt=DATE, observedAt=DATE, inputSHA256='0' * 64, runSample=0)

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def run_records(self, records, extra=(), success=True):
        for r in records:
            r.setdefault('expectedRecords', len(records))
        raw = self.root / 'records.jsonl'
        raw.write_text(''.join(json.dumps(r) + '\n' for r in records))
        result = subprocess.run([str(BIN), '--replay', str(raw), '--tip', '900000', '--summary-json', str(self.root / 'summary.json'),
                                 '--tor-socks', '127.0.0.1:9050', '--i2p-socks', '127.0.0.1:4447', *extra], capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        if success:
            return json.loads((self.root / 'summary.json').read_text()), json.loads((self.root / 'peers.json').read_text())
    def full(self):
        return [record('8.8.8.8'), record(onion(1)), record('a' * 52 + '.b32.i2p')]
    def publish(self, success=True):
        result = subprocess.run([str(ROOT / 'scripts/census-publish'), str(self.root / 'summary.json'), '--peers', str(self.root / 'peers.json'),
                                 '--records', str(self.root / 'records.jsonl'), '--validator', str(BIN), '--dir', str(self.root / 'public')], capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
    def test_production_peer_catalog_is_trackable(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_bytes((ROOT / ".gitignore").read_bytes())
        for path, ignored in [("peers.json", True), ("census/peers.json", False)]:
            result = subprocess.run(["git", "check-ignore", "--no-index", path], cwd=self.root, capture_output=True)
            self.assertEqual(result.returncode == 0, ignored, path)

    def test_replay_dates_and_complete_publication(self):
        s, p = self.run_records(self.full())
        self.assertEqual(s['generatedAt'], DATE)
        self.assertEqual(p['date'], DATE[:10])
        self.assertTrue(s['completeRun'])
        self.publish()
        self.assertTrue((self.root / 'public/2026-09-11.json').exists())
        days = json.loads((self.root / 'public/index.json').read_text())['days']
        self.assertEqual([d['date'] for d in days], ['2026-09-11'])
    def test_symmetric_extreme_heights(self):
        s, p = self.run_records([record('8.8.8.8', 900100), record('9.9.9.9', 899900), record('1.1.1.1', 900101),
                                 record('2.2.2.2', -2147483648), record('3.3.3.3', 2147483647)])
        self.assertEqual(s['networks']['clearnet']['atTip'], 2)
        self.assertEqual(s['families']['Core']['atTip'], 2)
        self.assertEqual(len(p['networks']['clearnet']), 2)
    def test_aliases_validation_and_diversity(self):
        rows = [record('::ffff:8.8.8.8'), record('8.8.8.8'), record('8.8.4.4'), record('127.0.0.1'),
                record('2001:db8::1'), record(onion(1).upper()), record(onion(1)), record('a'*56+'.onion')]
        _, p = self.run_records(rows)
        self.assertEqual(len(p['networks']['clearnet']), 1)
        self.assertEqual(len(p['networks']['tor']), 1)
        self.assertEqual(p['networks']['tor'][0]['host'], onion(1))
        before = (self.root / 'peers.json').read_bytes()
        self.run_records(list(reversed(rows)))
        self.assertEqual(before, (self.root / 'peers.json').read_bytes())
    def test_overlay_cap(self):
        _, p = self.run_records([record(onion(n)) for n in range(2005)])
        self.assertEqual(len(p['networks']['tor']), 2000)
    def test_hidden_overlays_are_sampled_by_hash_not_latency(self):
        rows = [record(onion(n), latency=n) for n in range(2100)]
        _, p = self.run_records(rows)
        chosen = {e['host'] for e in p['networks']['tor']}
        self.assertEqual(len(chosen), 2000)
        slowest = {onion(n) for n in range(2000, 2100)}
        self.assertTrue(chosen & slowest, 'selection is not the 2,000 fastest responders')
        first = (self.root / 'peers.json').read_bytes()
        self.run_records(list(reversed(rows)))
        self.assertEqual(first, (self.root / 'peers.json').read_bytes(), 'the same day replays to the same list')
    def test_clearnet_still_keeps_the_fastest_duplicate(self):
        _, p = self.run_records([record('8.8.8.8', latency=50), record('::ffff:8.8.8.8', latency=5)])
        self.assertEqual([e['host'] for e in p['networks']['clearnet']], ['8.8.8.8'])
    def test_committed_catalog_has_a_trusted_signature(self):
        public = (ROOT / 'census/signing-public-key.txt').read_text().strip()
        self.assertRegex(public, r'^[0-9a-f]{64}$')
        peers = self.root / 'peers.json'
        peers.write_bytes((ROOT / 'census/peers.json').read_bytes())
        signature = peers.with_suffix('.json.sig')
        signature.write_bytes((ROOT / 'census/peers.json.sig').read_bytes())
        def verify():
            return subprocess.run([str(BIN), 'verify', '--public-key', public, str(peers)], capture_output=True).returncode
        self.assertEqual(verify(), 0)
        peers.write_bytes(peers.read_bytes() + b'\n')
        self.assertNotEqual(verify(), 0)
        peers.write_bytes((ROOT / 'census/peers.json').read_bytes())
        signature.unlink()
        self.assertNotEqual(verify(), 0)

    def test_keygen_sign_and_verify(self):
        out = subprocess.run([str(BIN), 'keygen'], capture_output=True, check=True).stdout.decode()
        secret = re.search(r'CENSUS_SIGNING_KEY=(\S+)', out)[1]
        public = re.search(r'public key: ([0-9a-f]{64})', out)[1]
        self.run_records(self.full())
        peers = self.root / 'peers.json'
        without = {k: v for k, v in os.environ.items() if k != 'CENSUS_SIGNING_KEY'}
        self.assertNotEqual(subprocess.run([str(BIN), 'sign', str(peers)], env=without, capture_output=True).returncode, 0)
        subprocess.run([str(BIN), 'sign', '--key-env', 'CENSUS_SIGNING_KEY', str(peers)],
                       env={**without, 'CENSUS_SIGNING_KEY': secret}, check=True, capture_output=True)
        sig = json.loads((self.root / 'peers.json.sig').read_text())
        self.assertEqual(sig['algorithm'], 'ed25519')
        self.assertEqual(sig['publicKey'], public)
        self.assertEqual(len(sig['signature']), 128)
        subprocess.run([str(BIN), 'verify', '--public-key', public, str(peers)], check=True, capture_output=True)
        self.assertNotEqual(subprocess.run([str(BIN), 'verify', '--public-key', 'ab' * 32, str(peers)], capture_output=True).returncode, 0)
        peers.write_bytes(peers.read_bytes() + b'\n')
        self.assertNotEqual(subprocess.run([str(BIN), 'verify', str(peers)], capture_output=True).returncode, 0)
    def test_signature_known_answer_matches_the_wallet(self):
        # The wallet's CensusSignatureTests verify this same signature file
        # over this same payload under this same key (CryptoKit's Ed25519
        # signatures are randomised, so the vector is a file to verify, not a
        # signing output to reproduce). Both repositories pin it.
        payload = self.root / 'payload.json'
        payload.write_bytes(b'{"date":"2026-09-14"}')
        (self.root / 'payload.json.sig').write_text(json.dumps(
            {'algorithm': 'ed25519', 'publicKey': KAT_PUBLIC_KEY, 'signature': KAT_SIGNATURE}))
        subprocess.run([str(BIN), 'verify', '--public-key', KAT_PUBLIC_KEY, str(payload)], check=True, capture_output=True)
        payload.write_bytes(b'{"date":"2026-09-15"}')
        self.assertNotEqual(subprocess.run([str(BIN), 'verify', str(payload)], capture_output=True).returncode, 0)
        # The seed behind the vector derives the same public key here.
        secret = base64.b64encode(b'\x01' * 32).decode()
        payload.write_bytes(b'{"date":"2026-09-14"}')
        subprocess.run([str(BIN), 'sign', str(payload)], env={**os.environ, 'CENSUS_SIGNING_KEY': secret}, check=True, capture_output=True)
        self.assertEqual(json.loads((self.root / 'payload.json.sig').read_text())['publicKey'], KAT_PUBLIC_KEY)
    def test_missing_or_invalid_replay_dates(self):
        rows = self.full()
        for r in rows: r.pop('runStartedAt')
        self.run_records(rows, success=False)
        self.run_records(rows, extra=('--observed-at', DATE))
        self.run_records(rows, extra=('--observed-at', '2099-01-01T00:00:00Z'), success=False)
        self.run_records(rows, extra=('--observed-at', '2026-02-30T00:00:00Z'), success=False)
    def test_failure_retains_all_previous_good_files(self):
        self.run_records(self.full()); self.publish()
        public = self.root / 'public'
        baseline = {p.name: p.read_bytes() for p in public.iterdir()}
        for field, value in [('completeRun', False), ('sample', 1), ('expectedRecords', 10), ('peerListSHA256', 'wrong')]:
            self.run_records(self.full())
            p = self.root / 'summary.json'; s = json.loads(p.read_text()); s[field] = value; p.write_text(json.dumps(s))
            self.publish(success=False)
            self.assertEqual(baseline, {p.name: p.read_bytes() for p in public.iterdir()})
        rows = self.full(); rows[1]['outcome'] = 'timeout'
        self.run_records(rows); self.publish(success=False)
        self.assertEqual(baseline, {p.name: p.read_bytes() for p in public.iterdir()})

if __name__ == '__main__': unittest.main()
