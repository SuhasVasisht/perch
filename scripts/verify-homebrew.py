#!/usr/bin/env python3
"""Build and test the generated Homebrew formula without replacing the live app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

from homebrew_release import DEFAULT_REPO, ROOT, package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, default=ROOT / 'verification/perch-homebrew-report.json')
    args = parser.parse_args()
    if shutil.which('brew') is None:
        parser.exit(1, 'Install Homebrew before running this check.\n')
    env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_INSTALL_CLEANUP='1', HOMEBREW_NO_ANALYTICS='1')
    existing = subprocess.run(['brew', 'list', '--versions', '--formula', 'perch'], env=env, text=True, capture_output=True)
    if existing.returncode == 0 and existing.stdout.strip():
        parser.exit(1, 'Perch is already installed through Homebrew. Run brew test perch instead.\n')
    tap = 'perch-verification/run' + uuid.uuid4().hex[:10]
    formula = f'{tap}/perch'
    log = []

    def checked(*command, **kwargs):
        print('+ ' + ' '.join(map(str, command)), flush=True)
        result = subprocess.run(list(map(str, command)), env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
        print(result.stdout, end='', flush=True)
        log.append({'command': list(map(str, command)), 'exit_code': result.returncode, 'output': result.stdout})
        result.check_returncode()
        return result.stdout.strip()

    def live_binary_hash():
        path = Path('/Applications/Perch.app/Contents/MacOS/Perch')
        return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

    original_hash = live_binary_hash()
    report = {'result': 'failed', 'tap': tap, 'commands': log}
    tapped = False
    try:
        with tempfile.TemporaryDirectory(prefix='perch-homebrew-verify-') as directory:
            work = Path(directory)
            version, archive, checksum, generated = package(ROOT, work / 'release', DEFAULT_REPO)
            source_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
            second = package(ROOT, work / 'repeat', DEFAULT_REPO)[1]
            if archive.read_bytes() != second.read_bytes():
                raise RuntimeError('Packaging the same sources produced different archives')
            local_tap = work / 'homebrew-tap'
            (local_tap / 'Formula').mkdir(parents=True)
            # Only the download URL changes. Install, requirements, checksum, and test stay identical.
            content = re.sub(r'^  url ".*"$', f'  url "{archive.as_uri()}"', generated.read_text(), count=1, flags=re.MULTILINE)
            (local_tap / 'Formula/perch.rb').write_text(content)
            checked('git', 'init', '-q', local_tap)
            checked('git', '-C', local_tap, 'add', 'Formula/perch.rb')
            checked('git', '-C', local_tap, '-c', 'user.name=Perch verification', '-c', 'user.email=verification@localhost',
                    'commit', '-qm', 'Local source installation check')
            checked('brew', 'tap', tap, str(local_tap))
            tapped = True
            checked('brew', 'audit', '--strict', '--skip-style', formula)
            checked('brew', 'install', '--formula', '--build-from-source', formula)
            checked('brew', 'test', formula)
            prefix = Path(checked('brew', '--prefix', formula))
            actual = checked(prefix / 'bin/perch', '--version')
            info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
            expected = f'Perch {version} ({info["CFBundleVersion"]})'
            if actual != expected:
                raise RuntimeError(f'Expected {expected!r}, got {actual!r}')
            binary = prefix / 'Perch.app/Contents/MacOS/Perch'
            data = binary.read_bytes()
            if b'local.perch.debug' in data or b'OffscreenHost' in data:
                raise RuntimeError('Installed app contains development-only hooks')
            signature = checked('codesign', '-dvv', prefix / 'Perch.app')
            if 'Signature=adhoc' not in signature:
                raise RuntimeError('Expected the free ad-hoc signature')
            if live_binary_hash() != original_hash:
                raise RuntimeError('The live /Applications/Perch.app executable changed during verification')
            report.update(result='passed', version=actual, source_sha256=source_hash,
                          installed_binary_sha256=hashlib.sha256(data).hexdigest(),
                          signature='ad-hoc', reproducible_source_archive=True,
                          live_app_unchanged=True, installed_prefix=str(prefix))
    finally:
        # This unique tap and install belong to this check, never to the user's live app.
        if tapped:
            installed = subprocess.run(['brew', 'list', '--versions', '--formula', formula], env=env, text=True, capture_output=True)
            if installed.returncode == 0 and installed.stdout.strip():
                cleanup = subprocess.run(['brew', 'uninstall', '--formula', formula], env=env, text=True, capture_output=True)
                if cleanup.returncode:
                    report['cleanup_error'] = cleanup.stdout + cleanup.stderr
                else:
                    report['temporary_install_removed'] = True
            else:
                report['temporary_install_removed'] = True
            untap = subprocess.run(['brew', 'untap', tap], env=env, text=True, capture_output=True)
            if untap.returncode:
                report['untap_error'] = untap.stdout + untap.stderr
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(f'Verification report: {args.report}', flush=True)
    if report.get('cleanup_error') or report.get('untap_error'):
        raise RuntimeError('Verification cleanup failed; see the report')
    print(f'PASS: source-built Homebrew install, native {report["version"]}, strict signature, and cleanup.', flush=True)


if __name__ == '__main__':
    main()
