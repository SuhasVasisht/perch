#!/usr/bin/env python3
"""Compare production widget pixels across real focus states on local fixtures."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import hashlib
import json
import plistlib
import uuid
import subprocess
import tempfile
import threading

from PIL import Image, ImageChops
from interactive_verification import require_interactive

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'verification'
FIXTURE = b'''<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;background:transparent!important;color:white;font:18px -apple-system,sans-serif;}
#label{position:absolute;left:28px;top:110px;margin:0;}
</style><p id="label">Perch appearance fixture</p>'''


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(FIXTURE)))
        self.end_headers()
        self.wfile.write(FIXTURE)

    def log_message(self, *_):
        pass


def compare_pixels():
    # Validate actual state after capture as well as the native pre-capture check.
    for state in json.loads((OUTPUT / 'appearance-states.json').read_text()):
        expected_active = not state['name'].endswith('app-inactive')
        expected_key = state['name'].endswith('focused')
        assert state['active'] == expected_active and state['key'] == expected_key, state
    lines = []
    for mode in ('clear', 'frosted'):
        focused = Image.open(OUTPUT / f'appearance-{mode}-focused.png').convert('RGB')
        states = ['first-inactive', 'resigned', 'app-inactive']
        if mode == 'clear':
            states.insert(0, 'initial-paint-inactive')
        for state in states:
            other = Image.open(OUTPUT / f'appearance-{mode}-{state}.png').convert('RGB')
            equal = focused.size == other.size and ImageChops.difference(focused, other).getbbox() is None
            lines.append(f'{"PASS" if equal else "FAIL"} {mode} focused/{state} composited pixels are identical')
            if not equal:
                difference = ImageChops.difference(focused, other)
                difference.save(OUTPUT / f'appearance-{mode}-{state}-difference.png')
    clear = Image.open(OUTPUT / 'appearance-clear-focused.png').convert('RGB')
    frost = Image.open(OUTPUT / 'appearance-frosted-focused.png').convert('RGB')
    visible_difference = ImageChops.difference(clear, frost).getbbox() is not None
    lines.append(f'{"PASS" if visible_difference else "FAIL"} Clear and Frosted remain visually distinct')
    return lines


def main():
    require_interactive(allow_compile_only=True)
    parser = argparse.ArgumentParser()
    parser.add_argument('--compile-only', action='store_true', help='compile without opening any native windows')
    args = parser.parse_args()
    OUTPUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='perch-appearance-test-') as work:
        work = Path(work)
        sources = []
        # Immutable snapshots avoid concurrent changes during the compiler run.
        for name in ('WidgetWindow.swift', 'WidgetChrome.swift'):
            source = work / name
            shutil.copy2(ROOT / 'Sources/Perch' / name, source)
            sources.append(source)
        binary = work / 'VerifyAppearance'
        subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                        '-framework', 'AppKit', '-framework', 'WebKit',
                        '-target', 'arm64-apple-macosx26.0', str(ROOT / 'tests/VerifyAppearance.swift'),
                        *map(str, sources), '-o', str(binary)], check=True)
        if args.compile_only:
            print('PASS appearance harness compiles. No native windows opened.')
            return
        helper = work / 'AppearanceFocusTarget.app' / 'Contents'
        (helper / 'MacOS').mkdir(parents=True)
        helper_binary = helper / 'MacOS' / 'AppearanceFocusTarget'
        shutil.copy2(binary, helper_binary)
        (helper / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.perch.appearance-focus.' + uuid.uuid4().hex,
            'CFBundleExecutable': helper_binary.name,
            'CFBundleName': 'Appearance focus target',
            'CFBundlePackageType': 'APPL',
        }))
        source_hashes = {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
        (OUTPUT / 'appearance-source.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}/', str(OUTPUT), str(helper_binary)],
                                    capture_output=True, text=True, timeout=75)
            report = result.stdout
            if result.returncode:
                report += result.stderr
            else:
                report += '\n'.join(compare_pixels()) + '\n'
                report += ('Public NSVisualEffectView HUD material stays active without changing native focus. '
                           'Clear uses no material; Frosted has a stable HUD blur. '
                           'This intentionally removes Liquid Glass refraction.\n')
            (OUTPUT / 'appearance-local-report.txt').write_text(report)
            print(report, end='')
            if result.returncode or '\nFAIL ' in '\n' + report:
                raise SystemExit(result.returncode or 1)
        finally:
            server.shutdown()


if __name__ == '__main__':
    main()
