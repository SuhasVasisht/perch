#!/usr/bin/env python3
"""Cold-start X checkpoints in the established nonactivating WebKit host."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
import threading

from offscreen_support import adapt_sources, source_dir

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--label', default='candidate')
    args = parser.parse_args()
    fixture = (ROOT / 'tests/x-fixture/index.html').read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(fixture)
        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='perch-x-startup-') as work:
            work = Path(work)
            sources, manifest = adapt_sources(args.source_root, work / 'sources')
            tracked = [ROOT / path for path in ('tests/VerifyXStartup.swift', 'tests/OffscreenHost.swift',
                       'tests/x-fixture/index.html', 'scripts/verify-x-startup.py', 'scripts/offscreen_support.py')]
            hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked}
            binary = work / 'VerifyXStartup'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                            '-framework', 'AppKit', '-framework', 'WebKit', '-target', 'arm64-apple-macosx26.0',
                            str(ROOT / 'tests/VerifyXStartup.swift'), str(ROOT / 'tests/OffscreenHost.swift'),
                            *map(str, sources), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}'],
                                    capture_output=True, text=True, timeout=50)
            report = ROOT / f'verification/x-startup-{args.label}.txt'
            report.write_text('Nonactivating real WebKit with controlled OS activity.\n' + result.stdout + (result.stderr if result.returncode else ''))
            manifest = {'production_sources': manifest, 'fixture_and_host_sha256': hashes,
                        'test_inputs_unchanged': all(hashlib.sha256(path.read_bytes()).hexdigest() == hashes[str(path.relative_to(ROOT))] for path in tracked),
                        'production_sources_unchanged': all(hashlib.sha256((source_dir(args.source_root) / name).read_bytes()).hexdigest() == record['original_sha256'] for name, record in manifest.items()),
                        'exit_code': result.returncode}
            report.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
            print(result.stdout, end='')
            if result.returncode: print(result.stderr[-3000:])
            raise SystemExit(result.returncode)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
