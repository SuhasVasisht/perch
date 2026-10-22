#!/usr/bin/env python3
"""Check release path swaps with temporary files; no app launches or registration."""
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from install_release import replace_preserving, retire_legacy


class ReleaseInstallation(unittest.TestCase):
    def test_open_code_survives_bundle_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            current, candidate, retired = (root / name for name in ['Perch.app', 'Candidate.app', 'Old.retired'])
            current.mkdir()
            candidate.mkdir()
            (current / 'Perch').write_bytes(b'old-running-code')
            (candidate / 'Perch').write_bytes(b'new-release-code')
            inode = (current / 'Perch').stat().st_ino
            with (current / 'Perch').open('rb') as running:
                replace_preserving(candidate, current, retired)
                self.assertEqual(running.read(), b'old-running-code')
                self.assertEqual((retired / 'Perch').stat().st_ino, inode)
                self.assertEqual((current / 'Perch').read_bytes(), b'new-release-code')

    def test_workspace_link_replaces_old_bundle_and_can_be_repeated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            current, installed = root / 'Perch.app', root / 'Installed.app'
            current.mkdir()
            installed.mkdir()
            (current / 'Perch').write_bytes(b'old-workspace-code')
            (installed / 'Perch').write_bytes(b'installed-code')
            for index in range(2):
                link = root / f'NewLink-{index}'
                link.symlink_to(installed, target_is_directory=True)
                replace_preserving(link, current, root / f'Retired-{index}')
                self.assertTrue(current.is_symlink())
                self.assertEqual(current.resolve(), installed)
                self.assertEqual((current / 'Perch').read_bytes(), b'installed-code')
            self.assertEqual((root / 'Retired-0/Perch').read_bytes(), b'old-workspace-code')

    def test_first_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, current = root / 'Candidate.app', root / 'Perch.app'
            candidate.mkdir()
            (candidate / 'Perch').write_bytes(b'first-install')
            replace_preserving(candidate, current, root / 'Unused.retired')
            self.assertEqual((current / 'Perch').read_bytes(), b'first-install')

    def test_legacy_shell_bundles_retire_without_changing_open_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            applications, workspace, stage, retired = (root / name for name in ['Applications', 'workspace', 'stage', 'retired'])
            for folder in (applications, workspace, stage, retired):
                folder.mkdir()
            legacy = applications / 'Shell.app'
            (legacy / 'Contents/MacOS').mkdir(parents=True)
            (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.tweetframe'}))
            (legacy / 'Contents/MacOS/Shell').write_bytes(b'running-shell')
            other = applications / 'Other.app'
            other.mkdir()
            (workspace / 'Shell.app').symlink_to(legacy, target_is_directory=True)
            with (legacy / 'Contents/MacOS/Shell').open('rb') as running:
                retire_legacy(applications, workspace, stage, retired)
                self.assertEqual(running.read(), b'running-shell')
            self.assertFalse(legacy.exists())
            self.assertEqual((stage / 'Legacy-Shell.retired/Contents/MacOS/Shell').read_bytes(), b'running-shell')
            self.assertTrue((retired / 'Workspace-Shell.retired').is_symlink())
            self.assertFalse((workspace / 'Shell.app').is_symlink())
            self.assertTrue(other.exists())
            retire_legacy(applications, workspace, stage, retired)  # nothing left to move

    def test_unrelated_shell_app_is_left_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            unrelated = root / 'Shell.app'
            (unrelated / 'Contents').mkdir(parents=True)
            (unrelated / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.shell'}))
            retire_legacy(root, root / 'missing-workspace', root, root)
            self.assertTrue(unrelated.is_dir())


if __name__ == '__main__':
    unittest.main(verbosity=2)
