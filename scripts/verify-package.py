#!/usr/bin/env python3
"""Verify release/DMG contents; --install copies the release to Applications first."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from install_release import install_release

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--app', type=Path, default=ROOT / 'Perch.app', help='release bundle to verify or install')
    args = parser.parse_args()
    info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    app, installed = args.app, Path('/Applications/Perch.app')
    dmg = ROOT / f'dist/Perch-{version}.dmg'
    if args.install:
        install_release(app, ROOT)
    subprocess.run(['hdiutil', 'verify', str(dmg)], check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    lines = [f'Perch {version} ({build}) release and DMG verification', '']
    with tempfile.TemporaryDirectory(prefix='perch-package-mount-') as work:
        mount = Path(work)
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            bundles = [('workspace', app), ('DMG', mount / 'Perch.app')]
            if args.install:
                bundles.append(('installed', installed))
            hashes = []
            for label, bundle in bundles:
                subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
                packaged = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
                for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIdentifier'):
                    assert packaged[key] == info[key], f'{label}: unexpected {key}'
                binary = (bundle / 'Contents/MacOS/Perch').read_bytes()
                assert b'local.perch.debug' not in binary, f'{label}: debug channel included'
                assert b'OffscreenHost' not in binary, f'{label}: verification host included'
                digest = hashlib.sha256(binary).hexdigest()
                hashes.append(digest)
                lines.append(f'{label}: version {version} ({build}), strict signature valid, debug channel and verification host absent, SHA256 {digest}')
            assert len(set(hashes)) == 1, 'Executable contents differ'
            assert os.readlink(mount / 'Applications') == '/Applications'
            signature = subprocess.check_output(['codesign', '-dvv', str(app)], stderr=subprocess.STDOUT, text=True)
            lines += ['All executable hashes match.',
                      'Read-only DMG mounted, filesystem checksum verified, Applications link valid.',
                      'Ad-hoc signed; not notarized.' if 'Signature=adhoc' in signature else 'Developer-signed release.',
                      f'DMG SHA256 {hashlib.sha256(dmg.read_bytes()).hexdigest()}']
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    report = '\n'.join(lines) + '\n'
    (ROOT / 'verification/perch-package-report.txt').write_text(report)
    print(report)


if __name__ == '__main__':
    main()
