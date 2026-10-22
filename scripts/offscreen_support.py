"""Strict test-copy adapters for a nonactivating AppKit/WK compositor host.
Only OS activity/presentation boundaries change. Production files are never edited.
"""
from pathlib import Path
import hashlib

NAMES = ('WidgetWindow.swift', 'WidgetChrome.swift', 'XWidget.swift', 'CropScript.swift')


def source_dir(root):
    """Sources/Perch, or Sources/TweetFrame in frozen pre-rename baselines."""
    root = Path(root)
    return root / 'Sources/Perch' if (root / 'Sources/Perch').is_dir() else root / 'Sources/TweetFrame'


def adapt_sources(source_root, output_dir):
    """Return (source_paths, manifest); callers also compile tests/OffscreenHost.swift."""
    source_root, output_dir = Path(source_root), Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    result, manifest = [], {}
    for name in NAMES:
        original = (source_dir(source_root) / name).read_text()
        source = original
        changes = {}

        def replace(old, new, allowed):
            nonlocal source
            count = source.count(old)
            if count not in allowed:
                raise ValueError(f'{name}: expected {allowed} instances of {old!r}, got {count}')
            source = source.replace(old, new)
            changes[old] = count

        # Frozen pre-rename baselines call the browser class ShellWebView.
        view = 'PerchWebView' if 'PerchWebView' in original else 'ShellWebView'
        if name == 'WidgetWindow.swift':
            replace('NSApp.activate(ignoringOtherApps: true)', '/* offscreen host never activates NSApp */', {2})
            replace('panel.makeKeyAndOrderFront(nil)', 'OffscreenHost.present(panel)', {1})
            replace('            makeKeyAndOrderFront(nil)', '            OffscreenHost.present(self)', {1})
            replace('override var canBecomeKey: Bool { true }', 'override var canBecomeKey: Bool { false }', {1})
            replace('override var canBecomeMain: Bool { true }', 'override var canBecomeMain: Bool { false }', {1})
            replace('panel.isKeyWindow && NSApp.isActive', 'OffscreenHost.isActive', {0, 1})
            replace('private func updateBrowserActivity()', 'func updateBrowserActivity()', {0, 1})
            if 'func goForward()' not in source:
                replace(f'    func browserDidCreate(_ browser: {view}) {{}}', f'    func goForward() {{ webView?.goForward() }}\n    func browserDidCreate(_ browser: {view}) {{}}', {1})
            # Baseline has no lifecycle API. Absence is deliberately a no-op,
            # preserving the old behavior under the same simulated boundary.
            if f'func browserDidActivate(_ browser: {view})' not in source:
                replace(f'    func browserDidCreate(_ browser: {view}) {{}}',
                        f'    func updateBrowserActivity() {{}}\n    func browserDidCreate(_ browser: {view}) {{}}\n    func browserDidActivate(_ browser: {view}) {{}}\n    func browserDidDeactivate(_ browser: {view}) {{}}', {1})
        if name == 'WidgetChrome.swift':
            replace('override var canBecomeKey: Bool { true }', 'override var canBecomeKey: Bool { false }', {1})
            replace('            window.isOpaque = false', '            window.alphaValue = 0.001\n            window.ignoresMouseEvents = true\n            window.isOpaque = false', {1})
            replace('accessory.makeKeyAndOrderFront(nil)', 'OffscreenHost.present(accessory)', {1})
            replace('outline.orderFront(nil)', 'OffscreenHost.present(outline)', {1})
            replace('accessory.orderFront(nil)', 'OffscreenHost.present(accessory)', {1})
        if name == 'XWidget.swift':
            replace('self.panel.isKeyWindow && NSApp.isActive', 'OffscreenHost.isActive', {0, 1})
            replace('panel.isKeyWindow, NSApp.isActive', 'OffscreenHost.isActive', {0, 1})
        if 'NSApp.activate(' in source or 'makeKeyAndOrderFront(' in source:
            raise ValueError(f'{name}: activating presentation remains in adapted source')
        path = output_dir / name
        path.write_text(source)
        result.append(path)
        manifest[name] = {'original_sha256': hashlib.sha256(original.encode()).hexdigest(),
                          'adapted_sha256': hashlib.sha256(source.encode()).hexdigest(),
                          'substitutions': changes}
    return result, manifest
