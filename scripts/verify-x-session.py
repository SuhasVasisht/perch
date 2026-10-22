#!/usr/bin/env python3
"""Exercise exact X lifecycle logic in immutable nonactivating WebKit source copies."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import datetime
import hashlib
import json
import subprocess
import tempfile
import threading

from offscreen_support import adapt_sources

ROOT = Path(__file__).resolve().parent.parent


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write((ROOT / 'tests/x-fixture/index.html').read_bytes())

    def log_message(self, *_):
        pass


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='perch-x-session-offscreen-') as work:
        binary = Path(work) / 'VerifyXSession'
        sources, manifest = adapt_sources(ROOT, Path(work) / 'sources')
        dependencies = ['tests/OffscreenHost.swift', 'tests/VerifyXSession.swift',
                        'tests/x-fixture/index.html', 'scripts/offscreen_support.py',
                        'scripts/verify-x-session.py']
        evidence = {
            'mode': 'Offscreen compositor with controlled lifecycle, not actual OS activation',
            'captured_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'production_and_adapter_manifest': manifest,
            'fixture_and_host_sha256': {name: sha(ROOT / name) for name in dependencies},
        }
        subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                        '-framework', 'AppKit', '-framework', 'WebKit',
                        '-target', 'arm64-apple-macosx26.0', str(ROOT / 'tests/VerifyXSession.swift'),
                        str(ROOT / 'tests/OffscreenHost.swift'),
                        *map(str, sources), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}'],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=100)
        print(result.stdout, end='')
        if result.returncode:
            print(result.stderr[-6000:])
        report = ROOT / 'verification/x-session-offscreen-report.txt'
        report.write_text('OFFSCREEN: controlled lifecycle; no actual OS activation.\n' +
                          result.stdout + (result.stderr if result.returncode else ''))
        evidence['report_sha256'] = sha(report)
        evidence['exit_code'] = result.returncode
        evidence['fixture_and_host_files_unchanged_during_run'] = all(
            sha(ROOT / name) == value for name, value in evidence['fixture_and_host_sha256'].items())
        evidence['source_files_unchanged_during_run'] = all(
            sha(ROOT / 'Sources/Perch' / name) == record['original_sha256']
            for name, record in manifest.items())
        (ROOT / 'verification/x-session-offscreen-source-hashes.json').write_text(json.dumps(evidence, indent=2) + '\n')
        raise SystemExit(result.returncode)
finally:
    server.shutdown()
