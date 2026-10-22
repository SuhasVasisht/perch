#!/usr/bin/env python3
"""Compile only shared Perch code and test with isolated preferences/local media."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import io
import plistlib
import shutil
import struct
import subprocess
import tempfile
import threading
import wave
from interactive_verification import require_interactive

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = (ROOT / 'tests/perch-fixture/index.html').read_bytes()
buffer = io.BytesIO()
with wave.open(buffer, 'wb') as audio:
    audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    audio.writeframes(struct.pack('<h', 0) * 8000)
TONE = buffer.getvalue()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        data = TONE if self.path == '/tone.wav' else FIXTURE
        start, end = 0, len(data)-1
        requested = self.headers.get('Range') if self.path == '/tone.wav' else None
        if requested:
            bounds = requested.removeprefix('bytes=').split('-')
            start = int(bounds[0] or 0)
            end = min(int(bounds[1] or end), end)
        self.send_response(206 if requested else 200)
        self.send_header('Content-Type', 'audio/wav' if self.path == '/tone.wav' else 'text/html')
        self.send_header('Content-Length', str(end-start+1))
        self.send_header('Accept-Ranges', 'bytes')
        if requested:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        self.wfile.write(data[start:end+1])
    def log_message(self, *_):
        pass

def main():
    require_interactive()
    parser = argparse.ArgumentParser()
    parser.add_argument('--negative-control', action='store_true')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='perch-shared-test-') as work:
            binary = Path(work) / 'VerifyPerch'
            source = ROOT/'Sources/Perch/WidgetWindow.swift'
            if args.negative_control:
                changed = source.read_text().replace('if focusBeforeInteraction {', 'if true {', 1)
                source = Path(work)/'WidgetWindow.swift'
                source.write_text(changed)
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                            '-framework', 'AppKit', '-framework', 'WebKit',
                            '-target', 'arm64-apple-macosx26.0',
                            str(ROOT/'tests/VerifyPerch.swift'),
                            str(source),
                            str(ROOT/'Sources/Perch/WidgetChrome.swift'), '-o', str(binary)], check=True)
            helper = Path(work)/'BackgroundHelper.app/Contents'
            (helper/'MacOS').mkdir(parents=True)
            shutil.copy2(binary, helper/'MacOS/BackgroundHelper')
            (helper/'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'BackgroundHelper', 'CFBundlePackageType': 'APPL',
                'CFBundleIdentifier': 'local.perch.shared-click-helper',
                'CFBundleName': 'Perch local click helper',
            }))
            result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', str(helper/'MacOS/BackgroundHelper')],
                                    text=True, capture_output=True, timeout=65)
            print(result.stdout, end='')
            if result.returncode:
                print(result.stderr[-5000:])
            (ROOT/'verification').mkdir(exist_ok=True)
            report = 'perch-click-negative-control.txt' if args.negative_control else 'perch-local-report.txt'
            (ROOT/'verification'/report).write_text(result.stdout + (result.stderr if result.returncode else ''))
            if args.negative_control:
                caught = result.returncode != 0 and 'FAIL PerchFailure(message: "direct mode delivers the first inactive click exactly once")' in result.stdout
                print('Negative control detected the hard-coded focus-first regression.' if caught else 'Negative control failed to detect the expected click regression.')
                raise SystemExit(0 if caught else 1)
            raise SystemExit(result.returncode)
    finally:
        server.shutdown()

if __name__ == '__main__':
    main()
