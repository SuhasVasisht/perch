#!/usr/bin/env python3
"""Exercise the real XWidget and WebKit against local pages, with isolated data."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import threading

from offscreen_support import adapt_sources

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = (ROOT / 'tests/x-fixture/index.html').read_bytes()


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(FIXTURE)

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='perch-x-test-') as work:
            binary = Path(work) / 'VerifyX'
            negative = '--negative-control' in sys.argv
            baseline = '--reading-baseline' in sys.argv
            source_root = Path('/tmp/shell-1.7-before-x-reading-fix') if baseline else ROOT
            # Only OS activity and presentation are adapted in immutable copies;
            # page logic, native fits, sessions and navigation remain real.
            sources, manifest = adapt_sources(source_root, Path(work))
            if negative:
                for snapshot in sources:
                    if snapshot.name == 'CropScript.swift':
                        snapshot.write_text(snapshot.read_text().replace('restoreEntry();', ''))
            for path in [ROOT / 'tests/VerifyX.swift', ROOT / 'tests/OffscreenHost.swift', Path(__file__)]:
                manifest[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
            test_source = Path(work) / 'VerifyX.swift'
            test_source.write_text((ROOT / 'tests/VerifyX.swift').read_text())
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                            '-framework', 'AppKit', '-framework', 'WebKit',
                            '-target', 'arm64-apple-macosx26.0', str(test_source),
                            str(ROOT / 'tests/OffscreenHost.swift'),
                            *map(str, sources), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}'],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
            print(result.stdout, end='')
            if result.returncode:
                print(result.stderr[-5000:])
            report = ROOT / ('verification/x-offscreen-reading-baseline.txt' if baseline else 'verification/x-offscreen-negative-control.txt' if negative else 'verification/x-offscreen-report.txt')
            report.write_text('Nonactivating real WebKit; OS activity and key/click input are simulated.\n' + result.stdout + (result.stderr if result.returncode else ''))
            report.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
            if baseline:
                if not result.returncode or 'Keyboard motion follows the selected post ID when its connected cell is reused' not in result.stdout:
                    raise SystemExit('Reading baseline did not fail at the targeted cell-reuse check')
                print('PASS reading baseline detects connected-cell reuse regression')
                return
            if negative:
                return_checks = ('Back after Enter restores the selected post from an interrupted key transition',
                                 'Back returns to the same short post after snapping settles',
                                 'Back from nested reply restores comment scroll')
                if not result.returncode or not any(name in result.stdout for name in return_checks):
                    raise SystemExit('Negative control did not fail at the expected return-position check')
                print('PASS negative control detects the return-position regression')
                return
            raise SystemExit(result.returncode)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
