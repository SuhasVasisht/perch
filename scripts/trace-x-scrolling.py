#!/usr/bin/env python3
"""Census actual baseline CropScript scroll writers on an isolated local fixture."""
import argparse
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from offscreen_support import adapt_sources, source_dir

ROOT = Path(__file__).resolve().parent.parent
BASELINE = Path('/tmp/shell-1.7-before-x-reading-fix')
OUTPUT = ROOT / 'verification'


def reading_outcomes(scenes):
    by_name = {scene['name']: scene for scene in scenes}
    ack = by_name['pending-fit-after-compositor-gap']
    reuse = by_name['connected-node-reused-during-key-motion']
    reuse_event = next(event for event in reuse['events'] if event['kind'] == 'site-node-reuse')
    reuse_time = reuse_event['t']
    later_old_motion_writes = sum(event['kind'] == 'scroll-write' and event.get('owner') == 'key-rAF'
                                    and event['t'] > reuse_time for event in reuse['events'])
    resume = by_name['simulated-suspended-frames-lifecycle-return']
    return {
        'new reading offset survives an older native fit acknowledgement': ack['proof']['after'] == ack['proof']['moved'],
        'old keyboard motion stops when its connected node changes post identity': later_old_motion_writes == 0,
        'reading offset freezes after target identity disappears until new input': abs(reuse['snapshot']['y'] - reuse_event['y']) < 1,
        'latest pre-deactivation reading offset survives old callbacks after focus return': abs(resume['snapshot']['y'] - resume['proof']['beforeResume']) < 1,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path, default=BASELINE)
    parser.add_argument('--fixture-root', type=Path, default=BASELINE, help='keep the same frozen fixture for baseline/candidate source comparisons')
    parser.add_argument('--snapshots', action='store_true', help='capture three WK page snapshots, never desktop')
    parser.add_argument('--probe', action='store_true', help='bounded five-second nonactivating compositor proof')
    parser.add_argument('--offscreen', action='store_true', default=True, help='nonactivating host (always enabled)')
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--label', default='', help='append a label to artifact names for source comparisons')
    parser.add_argument('--expect', choices=['report-only', 'fixed', 'broken'], default='report-only')
    args = parser.parse_args()
    prefix = 'x-scroll-ownership' + ('-' + args.label if args.label else '')
    fixture = (args.fixture_root / 'tests/x-fixture/index.html').read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(fixture)))
            self.end_headers()
            self.wfile.write(fixture)
        def log_message(self, *_):
            pass

    OUTPUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='perch-scroll-ownership-') as directory:
        work = Path(directory)
        tracked = [source_dir(args.source_root)/name for name in ('WidgetWindow.swift', 'WidgetChrome.swift', 'XWidget.swift', 'CropScript.swift')]
        tracked += [ROOT/'tests/TraceXScrolling.swift', ROOT/'tests/OffscreenHost.swift', ROOT/'scripts/offscreen_support.py', Path(__file__).resolve(), args.fixture_root/'tests/x-fixture/index.html']
        before_hashes = {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked}
        sources, adaptation = adapt_sources(args.source_root, work)
        harness = work / 'TraceXScrolling.swift'
        host = work / 'OffscreenHost.swift'
        shutil.copy2(ROOT/'tests/TraceXScrolling.swift', harness)
        shutil.copy2(ROOT/'tests/OffscreenHost.swift', host)
        hashes = {'fixture': hashlib.sha256(fixture).hexdigest(),
                  'TraceXScrolling.swift': hashlib.sha256(harness.read_bytes()).hexdigest(),
                  'OffscreenHost.swift': hashlib.sha256(host.read_bytes()).hexdigest(),
                  'offscreen_support.py': hashlib.sha256((ROOT/'scripts/offscreen_support.py').read_bytes()).hexdigest(),
                  'adaptation': adaptation}
        binary = work / 'TraceXScrolling'
        subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-framework', 'AppKit', '-framework', 'WebKit',
                        '-target', 'arm64-apple-macosx26.0', str(harness), str(host), *map(str, sources), '-o', str(binary)], check=True)
        if args.compile_only:
            print('PASS local scroll ownership harness compiles; no windows opened')
            return
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            raw = OUTPUT / (prefix + '-trace.json')
            result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', str(raw)] + (['--probe'] if args.probe else ['--snapshots'] if args.snapshots else []), capture_output=True, text=True, timeout=55)
            after_hashes = {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked}
            hashes['run_inputs'] = before_hashes
            hashes['unchanged_during_run'] = before_hashes == after_hashes
            (OUTPUT/(prefix + '-source.json')).write_text(json.dumps(hashes, indent=2)+'\n')
            print(result.stdout, end='')
            if before_hashes != after_hashes:
                raise SystemExit('FAIL source, fixture, host, adapter, or test changed during run')
            if result.returncode:
                print(result.stderr[-4000:])
                raise SystemExit(result.returncode)
            if args.probe or args.snapshots:
                (OUTPUT/(prefix + '-source.json')).write_text(json.dumps(hashes, indent=2)+'\n')
                return
            scenes = json.loads(raw.read_text())
            lines = ['Premise under audit: independent delayed scroll correctors are safe when each checks only its local pending serial.',
                     'Source: ' + str(args.source_root), 'Fixture: ' + str(args.fixture_root / 'tests/x-fixture/index.html'), 'No production edits or account requests. Nonactivating host; lifecycle is simulated, not real OS focus.', 'PASS source/fixture/host/adapter/test/runner hashes unchanged throughout run.', '']
            outcomes = reading_outcomes(scenes)
            lines += [f'{"PASS" if passed else "FAIL"} {name}' for name, passed in outcomes.items()]
            lines.append('')
            census = {}
            for scene in scenes:
                writers = Counter(event.get('owner', 'unclassified') for event in scene['events'] if event['kind'] == 'scroll-write')
                census[scene['name']] = dict(writers)
                lines += [scene['name'], 'Proof: ' + json.dumps(scene['proof'], sort_keys=True),
                          'Final offset: ' + str(scene['snapshot']['y']), 'Scroll writer calls: ' + json.dumps(dict(writers), sort_keys=True), '']
            catalog = [
                '', 'BASELINE ownership catalog from /tmp/shell-1.7-before-x-reading-fix only; these source notes do not describe a candidate build:',
                'key-rAF: connected DOM cell + local keyMotion object. It does not capture/validate the post ID or focus/input epoch.',
                'fit-ack: pending serial + post ID + URL. It does not validate the reading offset or compositor progress since measurement.',
                'wheel snap: local scrollIntent + timer + selected DOM cell; scrollIntoView starts a separate browser smooth animation.',
                'restoreFrame: saved entry anchors + local restoring object + time ceiling; DOM input cancels it, swallowed activation input does not.',
                'site/router: fixture owns delayed 54px scrollTo drift on popstate; real site may own independent adjustments.',
                'browser-native: smooth animation/anchoring/compositor scroll produces scroll events without a new JS scroll method call.',
                '', 'BASELINE base audit: no WebContentProcessDidTerminate handler exists; Home reloads at popup paths are Google sign-in return handlers.',
                'Focus-first panel input intentionally consumes down/up before the page; the page pointerdown cancellation contract therefore misses activation clicks.',
                'BASELINE double-Up logic only refreshes at the absolute first Home post; the requested anywhere-Home reset requires a distinct explicit intent.',
            ]
            lines += catalog
            lines += ['Caveats: compositor gap and row reuse are explicitly simulated site/browser ordering, not physical trackpad evidence.',
                      'The suspended-frame case deliberately queues requestAnimationFrame callbacks and invokes native lifecycle hooks; it proves neither real OS focus routing nor natural WebKit suspension.',
                      'Scroll events without a programmatic call can come from browser animation, anchoring, layout, or compositor scrolling; this trace cannot uniquely identify them.']
            (OUTPUT/(prefix + '-outcomes.json')).write_text(json.dumps(outcomes, indent=2)+'\n')
            (OUTPUT/(prefix + '-census.json')).write_text(json.dumps(census, indent=2)+'\n')
            (OUTPUT/(prefix + '-source.json')).write_text(json.dumps(hashes, indent=2)+'\n')
            (OUTPUT/(prefix + '-report.txt')).write_text('\n'.join(lines)+'\n')
            print('\n'.join(lines))
            if args.expect == 'fixed' and not all(outcomes.values()):
                raise SystemExit(1)
            if args.expect == 'broken' and any(outcomes.values()):
                raise SystemExit(1)
        finally:
            server.shutdown()


if __name__ == '__main__':
    main()
