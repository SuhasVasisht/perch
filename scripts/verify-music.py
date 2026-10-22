#!/usr/bin/env python3
"""Run the real MusicWidget in isolated WebKit using local native-control variants."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from interactive_verification import require_interactive

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = (ROOT / 'tests/music-fixture/index.html').read_bytes()


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(FIXTURE)

    def log_message(self, *_):
        pass


def main():
    require_interactive()
    server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='perch-music-test-') as work:
            binary = Path(work) / 'VerifyMusic'
            sources = [ROOT / 'Sources/Perch' / name for name in ['WidgetWindow.swift', 'WidgetChrome.swift', 'MusicWidget.swift']]
            negative = '--negative-control' in sys.argv
            if negative:
                music = ROOT / 'Sources/Perch/MusicWidget.swift'
                temporary_music = Path(work) / 'MusicWidget.swift'
                temporary_music.write_text(music.read_text().replace('        ${bar} .left-controls-buttons > #play-pause-button,\n', ''))
                sources = [temporary_music if p == music else p for p in sources]
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                            '-framework', 'AppKit', '-framework', 'WebKit',
                            '-target', 'arm64-apple-macosx26.0', str(ROOT / 'tests/VerifyMusic.swift'),
                            *map(str, sources), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}/'],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=100)
            print(result.stdout, end='')
            if result.returncode:
                print(result.stderr[-5000:])
            report = ROOT / ('verification/music-negative-control.txt' if negative else 'verification/music-local-report.txt')
            report.parent.mkdir(exist_ok=True)
            report.write_text(result.stdout + (result.stderr if result.returncode else ''))
            if negative:
                if result.returncode == 0 or 'loading keeps native control slots on every frame' not in result.stdout:
                    raise SystemExit('Negative control did not detect the loading-slot regression')
                print('PASS negative control detects the native loading-slot regression')
                return
            raise SystemExit(result.returncode)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
