#!/usr/bin/env python3
"""Check source artifacts and release immutability without publishing to GitHub."""
import base64
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
import homebrew_release as release


class HomebrewRelease(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='perch-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        files = {
            'build.sh': b'#!/bin/bash\nexit 0\n',
            'LICENSE': b'MIT\n',
            'Assets/AppIcon.png': b'icon fixture',
            'scripts/make-icon.swift': b'// icon fixture\n',
            'Sources/Perch/AppMain.swift': b'// app fixture\n',
            'packaging/homebrew/perch.rb.in': (release.ROOT / 'packaging/homebrew/perch.rb.in').read_bytes(),
            'Info.plist': plistlib.dumps({'CFBundleShortVersionString': '1.9', 'CFBundleVersion': '12'}),
        }
        for name, data in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Perch test', '-c', 'user.email=test@localhost',
                        'commit', '-qm', 'Source fixture'], check=True)
        self.destination = Path(self.temp.name) / 'release'
        self.commit = subprocess.check_output(['git', '-C', str(self.root), 'rev-parse', 'HEAD'], text=True).strip()

    def test_missing_tag_lookup_counts_as_missing(self):
        for status in ('404', '422'):
            failure = subprocess.CompletedProcess([], 1, '', f'gh: No commit found for SHA: v1.9 (HTTP {status})')
            with patch.object(release.subprocess, 'run', return_value=failure):
                self.assertIsNone(release.github('repos/owner/perch/commits/v1.9', missing_ok=True))
        failure = subprocess.CompletedProcess([], 1, '', 'gh: Bad credentials (HTTP 401)')
        with patch.object(release.subprocess, 'run', return_value=failure):
            with self.assertRaises(RuntimeError):
                release.github('repos/owner/perch/commits/v1.9', missing_ok=True)

    def test_archive_contains_only_build_inputs_with_a_matching_formula(self):
        (self.root / 'private-session.json').write_text('must stay local')
        (self.root / 'Perch.app').mkdir()
        (self.root / 'Perch.app/private-binary').write_bytes(b'must stay local')
        version, archive, checksum, formula = release.package(self.root, self.destination, 'owner/perch')
        with tarfile.open(archive) as tar:
            self.assertEqual(set(tar.getnames()), {
                'Perch-1.9/build.sh', 'Perch-1.9/Info.plist', 'Perch-1.9/LICENSE',
                'Perch-1.9/Assets/AppIcon.png', 'Perch-1.9/scripts/make-icon.swift',
                'Perch-1.9/Sources/Perch/AppMain.swift',
            })
            self.assertEqual(tar.getmember('Perch-1.9/build.sh').mode, 0o755)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertEqual(checksum.read_text(), f'{digest}  Perch-1.9-source.tar.gz\n')
        self.assertIn(f'sha256 "{digest}"', formula.read_text())
        self.assertIn('https://github.com/owner/perch/releases/download/v1.9/Perch-1.9-source.tar.gz', formula.read_text())
        self.assertNotIn('@BUILD@', formula.read_text())
        second = release.package(self.root, Path(self.temp.name) / 'repeat', 'owner/perch')[1]
        self.assertEqual(archive.read_bytes(), second.read_bytes())

    def test_archive_refuses_symlinked_build_inputs(self):
        source = self.root / 'Sources/Perch/AppMain.swift'
        source.unlink()
        source.symlink_to(self.root / 'LICENSE')
        with self.assertRaisesRegex(ValueError, 'regular release source file'):
            release.package(self.root, self.destination, 'owner/perch')

    def test_dirty_checkout_stops_before_any_github_request(self):
        (self.root / 'build.sh').write_text('uncommitted change')
        with patch.object(release.shutil, 'which', return_value='/usr/bin/gh'), patch.object(release, 'github') as github:
            with self.assertRaisesRegex(RuntimeError, 'checkout must be clean'):
                release.publish(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
            github.assert_not_called()

    def test_version_tag_cannot_be_reused_for_another_commit(self):
        responses = [{'private': False}, {'private': False}, {'sha': self.commit}, {'sha': 'other-commit'}]
        with patch.object(release.shutil, 'which', return_value='/usr/bin/gh'), \
                patch.object(release, 'github', side_effect=responses), patch.object(release, 'run') as mutate:
            with self.assertRaisesRegex(RuntimeError, 'already points to another commit'):
                release.publish(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
            mutate.assert_not_called()

    def test_asset_conflict_is_checked_before_uploading_a_missing_asset(self):
        responses = [{'private': False}, {'private': False}, {'sha': self.commit}, {'sha': self.commit},
                     {'draft': False, 'assets': [{'name': 'Perch-1.9-source.tar.gz.sha256'}]}]

        def download(*args, **kwargs):
            self.assertEqual(args[:3], ('gh', 'release', 'download'))
            destination = Path(args[args.index('--dir') + 1])
            (destination / 'Perch-1.9-source.tar.gz.sha256').write_text('different published checksum')

        with patch.object(release.shutil, 'which', return_value='/usr/bin/gh'), \
                patch.object(release, 'github', side_effect=responses), patch.object(release, 'run', side_effect=download) as calls:
            with self.assertRaisesRegex(RuntimeError, 'Refusing to replace published'):
                release.publish(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
            self.assertEqual(calls.call_count, 1)

    def test_publishing_preserves_other_formulae_and_an_identical_retry_is_a_noop(self):
        remote = Path(self.temp.name) / 'remote.git'
        seed = Path(self.temp.name) / 'tap-seed'
        (seed / 'Formula').mkdir(parents=True)
        (seed / 'Formula/other.rb').write_text('another maintained formula\n')
        subprocess.run(['git', 'init', '-q', str(seed)], check=True)
        subprocess.run(['git', '-C', str(seed), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(seed), '-c', 'user.name=Perch test', '-c', 'user.email=test@localhost',
                        'commit', '-qm', 'Existing tap package'], check=True)
        subprocess.run(['git', 'clone', '-q', '--bare', str(seed), str(remote)], check=True)
        published = {}
        mutations = []
        # Tap commits must use the source checkout's identity, not the global one.
        subprocess.run(['git', '-C', str(self.root), 'config', 'user.name', 'Perch author'], check=True)
        subprocess.run(['git', '-C', str(self.root), 'config', 'user.email', 'author@example.invalid'], check=True)

        def github(path, missing_ok=False):
            if path in ('repos/owner/perch', 'repos/owner/homebrew-tap'):
                return {'private': False}
            if path == f'repos/owner/perch/commits/{self.commit}':
                return {'sha': self.commit}
            if path == 'repos/owner/perch/commits/v1.9':
                return {'sha': self.commit} if published else None
            if path == 'repos/owner/perch/releases/tags/v1.9':
                return {'draft': False, 'assets': [{'name': name} for name in published]} if published else None
            self.fail(f'Unexpected GitHub request: {path}')

        def execute(*args, **kwargs):
            if args[:3] == ('gh', 'release', 'create'):
                for name in args[4:6]:
                    artifact = Path(name)
                    published[artifact.name] = artifact.read_bytes()
                mutations.append('release created')
                return
            if args[:3] == ('gh', 'release', 'download'):
                artifact = args[args.index('--pattern') + 1]
                (Path(args[args.index('--dir') + 1]) / artifact).write_bytes(published[artifact])
                return
            if args[:3] == ('gh', 'repo', 'clone'):
                subprocess.run(['git', 'clone', '-q', str(remote), args[4]], check=True)
                return
            self.assertEqual(args[0], 'git')
            if 'commit' in args:
                mutations.append('formula committed')
            subprocess.run(args, check=True, **kwargs)

        with patch.object(release.shutil, 'which', return_value='/usr/bin/gh'), \
                patch.object(release, 'github', side_effect=github), patch.object(release, 'run', side_effect=execute):
            release.publish(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
            head = subprocess.check_output(['git', '--git-dir', str(remote), 'rev-parse', 'HEAD'], text=True)
            release.publish(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(remote), 'rev-parse', 'HEAD'], text=True), head)
        self.assertEqual(mutations, ['release created', 'formula committed'])
        author = subprocess.check_output(['git', '--git-dir', str(remote), 'log', '-1', '--format=%an <%ae> %cn <%ce>'], text=True).strip()
        self.assertEqual(author, 'Perch author <author@example.invalid> Perch author <author@example.invalid>')
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(remote), 'show', 'HEAD:Formula/other.rb'], text=True),
                         'another maintained formula\n')
        formula = subprocess.check_output(['git', '--git-dir', str(remote), 'show', 'HEAD:Formula/perch.rb'], text=True)
        self.assertIn('class Perch < Formula', formula)
        self.assertIn(f'sha256 "{hashlib.sha256(published["Perch-1.9-source.tar.gz"]).hexdigest()}"', formula)


    def sync_fixture(self, released_build='12'):
        """A tap remote plus GitHub fakes where v1.9 is already released."""
        remote = Path(self.temp.name) / 'sync-remote.git'
        seed = Path(self.temp.name) / 'sync-seed'
        (seed / 'Formula').mkdir(parents=True)
        (seed / 'Formula/perch.rb').write_text('old formula\n')
        subprocess.run(['git', 'init', '-q', str(seed)], check=True)
        subprocess.run(['git', '-C', str(seed), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(seed), '-c', 'user.name=Perch test', '-c', 'user.email=test@localhost',
                        'commit', '-qm', 'Tap'], check=True)
        subprocess.run(['git', 'clone', '-q', '--bare', str(seed), str(remote)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'config', 'user.name', 'Perch author'], check=True)
        subprocess.run(['git', '-C', str(self.root), 'config', 'user.email', 'author@example.invalid'], check=True)
        digest = 'ab' * 32
        mutations = []
        released = base64.b64encode(plistlib.dumps({'CFBundleShortVersionString': '1.9', 'CFBundleVersion': released_build})).decode()

        def github(path, missing_ok=False):
            if path == 'repos/owner/perch/releases/tags/v1.9':
                return {'draft': False, 'assets': [{'name': 'Perch-1.9-source.tar.gz'}, {'name': 'Perch-1.9-source.tar.gz.sha256'}]}
            if path == 'repos/owner/homebrew-tap':
                return {'private': False}
            if path == 'repos/owner/perch/contents/Info.plist?ref=v1.9':
                return {'content': released}
            self.fail(f'Unexpected GitHub request: {path}')

        def execute(*args, **kwargs):
            if args[:3] == ('gh', 'release', 'download'):
                (Path(args[args.index('--dir') + 1]) / 'Perch-1.9-source.tar.gz.sha256').write_text(f'{digest}  Perch-1.9-source.tar.gz\n')
                return
            if args[:3] == ('gh', 'repo', 'clone'):
                subprocess.run(['git', 'clone', '-q', str(remote), args[4]], check=True)
                return
            self.assertEqual(args[0], 'git', f'Unexpected command: {args}')
            if 'commit' in args:
                mutations.append('formula committed')
            subprocess.run(args, check=True, **kwargs)

        return remote, digest, mutations, github, execute

    def test_sync_refreshes_the_formula_of_a_released_version_without_a_new_release(self):
        remote, digest, mutations, github, execute = self.sync_fixture()
        with patch.object(release, 'github', side_effect=github), patch.object(release, 'run', side_effect=execute):
            release.sync(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
            release.sync(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
        self.assertEqual(mutations, ['formula committed'])  # The second sync is a no-op.
        formula = subprocess.check_output(['git', '--git-dir', str(remote), 'show', 'HEAD:Formula/perch.rb'], text=True)
        self.assertIn(f'sha256 "{digest}"', formula)
        self.assertIn('url "https://github.com/owner/perch/releases/download/v1.9/Perch-1.9-source.tar.gz"', formula)
        self.assertIn('head "https://github.com/owner/perch.git", branch: "main"', formula)
        author = subprocess.check_output(['git', '--git-dir', str(remote), 'log', '-1', '--format=%ae'], text=True).strip()
        self.assertEqual(author, 'author@example.invalid')

    def test_sync_refuses_a_new_build_number_under_a_released_version(self):
        remote, digest, mutations, github, execute = self.sync_fixture(released_build='11')
        with patch.object(release, 'github', side_effect=github), patch.object(release, 'run', side_effect=execute):
            with self.assertRaisesRegex(RuntimeError, 'released as build 11'):
                release.sync(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
        self.assertEqual(mutations, [])

    def test_sync_publishes_when_the_version_has_no_release(self):
        with patch.object(release, 'github', return_value=None), patch.object(release, 'publish') as publish:
            release.sync(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
        publish.assert_called_once_with(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')

    def test_sync_requires_a_clean_checkout(self):
        (self.root / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '2.0', 'CFBundleVersion': '13'}))
        with patch.object(release, 'github') as github:
            with self.assertRaisesRegex(RuntimeError, 'must be clean'):
                release.sync(self.root, self.destination, 'owner/perch', 'owner/homebrew-tap')
        github.assert_not_called()

if __name__ == '__main__':
    unittest.main(verbosity=2)
