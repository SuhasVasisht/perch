#!/usr/bin/env python3
"""Check the signed-in widgets in a running ./build.sh debug build.

Run: python3 scripts/verify-interactions.py
Uses the actual WebKit DOM and native window state. Does not post, like,
sign out, or start playback. Use native UI checks for physical clicks,
menus, dragging, and keyboard shortcuts as well.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import time
from interactive_verification import require_interactive


POSTER = '''import Foundation
let path = "/tmp/perch-debug.txt"
try? FileManager.default.removeItem(atPath: path)
DistributedNotificationCenter.default().postNotificationName(.init("local.perch.debug"),
  object: CommandLine.arguments.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)
for _ in 0..<60 {
  usleep(50_000)
  if let text = try? String(contentsOfFile: path, encoding: .utf8) { print(text); exit(0) }
}
fputs("No debug response. Build and run Perch with ./build.sh debug.\\n", stderr)
exit(1)
'''

GEOMETRY = r'''(() => {
  const bar = document.querySelector('ytmusic-app-layout > ytmusic-player-bar');
  const controls = ['.previous-button', '#play-pause-button', '#left-controls .next-button', '#right-controls .toggle-player-page-button'];
  const errors = [];
  const centers = [];
  for (const selector of controls) {
    const host = bar?.querySelector(selector);
    const button = host?.querySelector('button');
    const icon = button?.querySelector('yt-icon');
    if (!button || !icon) { errors.push(`Missing ${selector}`); continue; }
    const r = button.getBoundingClientRect(), h = host.getBoundingClientRect(), i = icon.getBoundingClientRect();
    if (r.width < 36 || r.height < 40) errors.push(`${selector}: undersized target ${r.width}x${r.height}`);
    if (Math.abs(r.width-h.width) > .5 || Math.abs(r.height-h.height) > .5) errors.push(`${selector}: button does not fill host`);
    if (Math.abs(r.x+r.width/2-i.x-i.width/2) > .5 || Math.abs(r.y+r.height/2-i.y-i.height/2) > .5) errors.push(`${selector}: icon not centered`);
    if (r.left < 0 || r.top < 0 || r.right > innerWidth+.5 || r.bottom > innerHeight+.5) errors.push(`${selector}: clipped target`);
    centers.push(r.y+r.height/2);
    // Round controls do not include the square bounding box's corners.
    const points = [[r.width/2,r.height/2],[2,r.height/2],[r.width-2,r.height/2],
      [r.width/2,2],[r.width/2,r.height-2], ...[.25,.75].flatMap(x=>[.25,.75].map(y=>[r.width*x,r.height*y]))];
    for (const [dx,dy] of points) {
      const hit = document.elementFromPoint(r.x+dx, r.y+dy);
      if (!button.contains(hit)) errors.push(`${selector}: another element intercepts ${dx},${dy}: ${hit?.tagName}#${hit?.id}`);
    }
  }
  if (Math.max(...centers)-Math.min(...centers) > .5) errors.push('Controls are not vertically aligned');
  const image = bar?.querySelector('.thumbnail-image-wrapper img');
  if (!image?.complete || !image.naturalWidth || image.getBoundingClientRect().width !== 48) errors.push('Album art missing or incorrectly sized');
  const track = bar?.querySelector('#progress-bar #progressContainer')?.getBoundingClientRect();
  if (!track || track.y < innerHeight-5 || track.bottom > innerHeight) errors.push('Progress line is not at the bottom');
  if (document.body.scrollWidth > innerWidth+1) errors.push('Horizontal overflow');
  const toggle = bar?.querySelector('#right-controls .toggle-player-page-button button');
  const label = window.__musicMini ? 'Open full player' : 'Switch to mini player';
  if (toggle?.getAttribute('aria-label') !== label) errors.push('Incorrect size-control label');
  return {errors, targets: controls.length, viewport:[innerWidth,innerHeight]};
})()'''


def main():
    require_interactive()
    results = []
    with tempfile.TemporaryDirectory(prefix="perch-verification-") as work:
        source = Path(work) / "post.swift"
        source.write_text(POSTER)
        poster = Path(work) / "post"
        subprocess.run(["swiftc", str(source), "-o", str(poster)], check=True)

        def command(*args):
            return subprocess.check_output([str(poster), *args], text=True, timeout=6).strip()

        def js(widget, expression):
            return json.loads(command("js", widget, f"JSON.stringify({expression})"))

        def check(name, condition, detail=""):
            result = f"{'PASS' if condition else 'FAIL'} {name}" + (f": {detail}" if detail else "")
            print(result, flush=True)
            results.append(result)
            if not condition:
                raise AssertionError(result)

        def wait(widget, expression):
            for _ in range(60):
                if js(widget, expression):
                    return
                time.sleep(.1)
            raise AssertionError(f"Timed out waiting for {expression}")

        original = json.loads(command("state", "music"))
        try:
            command("show", "music")
            js("music", "(() => { window.__perchVerificationOldDocument = true; return true; })()")
            command("load", "music", "https://music.youtube.com/")
            wait("music", "!window.__perchVerificationOldDocument && !!document.querySelector('ytmusic-app-layout > ytmusic-player-bar #play-pause-button button') && !!window.__musicPaint")
            wait("music", "!!document.querySelector('ytmusic-app-layout > ytmusic-player-bar .thumbnail-image-wrapper img')?.naturalWidth")
            for theme in ["glass", "dark", "light"]:
                command("theme", "music", theme)
                for mini in [True, False]:
                    command("mini", "music", "on" if mini else "off")
                    wait("music", f"window.__musicMini === {str(mini).lower()} && innerHeight === {72 if mini else 720}")
                    value = js("music", GEOMETRY)
                    check(f"Music {theme} {'mini' if mini else 'full'}: alignment, 36 hit points, art, progress, labels", not value["errors"], "; ".join(value["errors"]))

            command("theme", "music", "glass")
            for index in range(6):
                mini = bool(js("music", "window.__musicMini"))
                js("music", "(() => { document.querySelector('ytmusic-app-layout > ytmusic-player-bar #right-controls .toggle-player-page-button button').click(); return true; })()")
                wait("music", f"window.__musicMini === {str(not mini).lower()}")
            check("Music size arrow: six successive switches", True)

            command("mini", "music", "on")
            js("music", "(() => { document.querySelector('ytmusic-app-layout > ytmusic-player-bar .thumbnail-image-wrapper').click(); return true; })()")
            wait("music", "!window.__musicMini && document.querySelector('ytmusic-app-layout').hasAttribute('player-page-open')")
            for theme in ["glass", "dark", "light"]:
                command("theme", "music", theme)
                check(f"Now playing {theme}: no duplicate strip", js("music", "getComputedStyle(document.querySelector('ytmusic-app-layout > ytmusic-player-bar')).display === 'none'"))
                check(f"Now playing {theme}: Play glyph visible", js("music", "!['transparent','rgba(0, 0, 0, 0)'].includes(getComputedStyle(document.querySelector('ytmusic-player-controls #play-pause-button yt-icon')).color)"))
                check(f"Now playing {theme}: full Play target and centered glyph", js("music", "(() => {const h=document.querySelector('ytmusic-player-controls #play-pause-button'), b=h.querySelector('button'), r=b.getBoundingClientRect(), p=h.getBoundingClientRect(), i=b.querySelector('yt-icon').getBoundingClientRect();return r.width===72 && r.height===72 && Math.abs(r.width-p.width)<1 && i.width===40 && i.height===40 && Math.abs(r.x+r.width/2-i.x-i.width/2)<.5 && Math.abs(r.y+r.height/2-i.y-i.height/2)<.5})()"))
            js("music", "(() => { document.querySelector('ytmusic-player-page #collapse-button button').click(); return true; })()")
            wait("music", "window.__musicMini && !document.querySelector('ytmusic-app-layout').hasAttribute('player-page-open')")
            check("Now-playing down arrow returns to mini and browsing", True)
            before_hide = json.loads(command("state", "music"))
            command("hide", "music")
            check("Music hide", not json.loads(command("state", "music"))["visible"])
            command("show", "music")
            reopened = json.loads(command("state", "music"))
            check("Music reopen preserves mini mode", reopened["visible"] and not reopened["expanded"])
            check("Music reopen preserves size and top edge", all(abs(reopened[k]-before_hide[k])<.5 for k in ["width", "height", "top"]))
            x_before = json.loads(command("state", "x"))
            if x_before["visible"]:
                command("hide", "x")
                check("X hide", not json.loads(command("state", "x"))["visible"])
                command("show", "x")
                x_after = json.loads(command("state", "x"))
                check("X reopen preserves variable size and top edge", x_after["visible"] and all(abs(x_after[k]-x_before[k])<.5 for k in ["width", "height", "top"]))
        finally:
            command("theme", "music", original["theme"])
            command("mini", "music", "off" if original["expanded"] else "on")
            if not original["visible"]:
                command("hide", "music")
            report = Path(__file__).resolve().parent.parent / "verification" / "interaction-report.txt"
            report.parent.mkdir(exist_ok=True)
            report.write_text("\n".join(results) + "\n")
    print(f"Completed {len(results)} live checks. Native click and navigation checks are documented in handoff.md.")


if __name__ == "__main__":
    main()
