"""Dependency promotion must keep a reproducible pin and roll back failures."""
import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('wallet_update', str(Path(__file__).resolve().parents[1] / 'scripts/update-wallet'))
spec = importlib.util.spec_from_loader(loader.name, loader)
updater = importlib.util.module_from_spec(spec)
loader.exec_module(updater)


class WalletUpdateTests(unittest.TestCase):
    def test_candidate_is_promoted_only_after_all_checks(self):
        self.exercise(None)

    def test_failed_build_or_contract_restores_both_package_files(self):
        for failure in ('swift', 'unittest', 'reproduce.py'):
            with self.subTest(failure=failure):
                self.exercise(failure)

    def exercise(self, failure):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = '.package(url: "https://github.com/winnowwallet/winnow", revision: "' + 'a' * 40 + '")\n'
            (root / 'Package.swift').write_text(manifest)
            (root / 'Package.resolved').write_text('original lock\n')
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                if args[0] == 'git':
                    return subprocess.CompletedProcess(args, 0, 'b' * 40 + '\trefs/heads/main\n')
                if args[0] == 'swift':
                    (root / 'Package.resolved').write_text('candidate lock\n')
                if failure and any(failure in arg for arg in args):
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0)
            with patch.object(updater.subprocess, 'run', side_effect=run):
                if failure:
                    with self.assertRaises(subprocess.CalledProcessError):
                        updater.update(root)
                else:
                    updater.update(root)
            if failure:
                self.assertEqual((root / 'Package.swift').read_text(), manifest)
                self.assertEqual((root / 'Package.resolved').read_text(), 'original lock\n')
            else:
                self.assertIn('b' * 40, (root / 'Package.swift').read_text())
                self.assertEqual(len(calls), 4)
                self.assertIn('unittest', calls[2])
                self.assertIn('--check', calls[3])
