#!/usr/bin/env python3
"""Exercise the shared registry UI using three account-free native widgets."""
from pathlib import Path
import subprocess
import tempfile
from interactive_verification import require_interactive

require_interactive()
ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='perch-settings-test-') as work:
    binary = Path(work) / 'VerifySettings'
    sources = [ROOT / 'Sources/Perch' / name for name in [
        'WidgetWindow.swift', 'WidgetChrome.swift', 'PerchGlyph.swift',
        'WidgetDesk.swift', 'WidgetRegistration.swift']]
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                    '-framework', 'AppKit', '-framework', 'WebKit',
                    '-target', 'arm64-apple-macosx26.0', str(ROOT / 'tests/VerifySettings.swift'),
                    *map(str, sources), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=60)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr[-6000:])
    report = ROOT / 'verification/settings-local-report.txt'
    report.write_text(result.stdout + (result.stderr if result.returncode else ''))
    raise SystemExit(result.returncode)
