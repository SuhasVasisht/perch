#!/usr/bin/env python3
"""Debug build only: start a passive scroll-writer trace, or save it with --report.

Run this, navigate Back once through the native UI, then run with --report.
No navigation or account actions are performed by this script.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TRACE = r'''(() => {
  window.__returnTrace = [];
  if (window.__tfTraceInstalled) return true;
  window.__tfTraceInstalled = true;
  const log = (kind, data={}) => {
    if (window.__returnTrace.length < 200) window.__returnTrace.push({kind,
      t: performance.now(), y: scrollY, url: location.href,
      snap: getComputedStyle(document.documentElement).scrollSnapType, ...data});
  };
  for (const name of ['scrollTo', 'scrollBy']) {
    const original = window[name].bind(window);
    window[name] = (...args) => { log(name, {args, stack:new Error().stack}); return original(...args); };
  }
  const intoView = Element.prototype.scrollIntoView;
  Element.prototype.scrollIntoView = function(...args) {
    log('scrollIntoView', {args, stack:new Error().stack});
    return intoView.apply(this, args);
  };
  new MutationObserver(() => log('restore-flag', {
    flag:document.documentElement.hasAttribute('data-tf-restoring')}))
    .observe(document.documentElement, {attributes:true, attributeFilter:['data-tf-restoring']});
  addEventListener('popstate', () => log('popstate', {key:history.state?.key}));
  for (const type of ['wheel','pointerdown','touchstart','keydown'])
    addEventListener(type, () => log(type), true);
  addEventListener('scroll', () => log('scroll'), {passive:true});
  return true;
})()'''

spec = importlib.util.spec_from_file_location('music_checks', ROOT / 'scripts/verify-interactions.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='perch-trace-') as directory:
    source = Path(directory) / 'post.swift'
    source.write_text(module.POSTER)
    poster = Path(directory) / 'post'
    subprocess.run(['swiftc', str(source), '-o', str(poster)], check=True)
    expression = 'JSON.stringify(window.__returnTrace || [])' if '--report' in sys.argv else TRACE
    value = subprocess.check_output([str(poster), 'js', 'x', expression], text=True).strip()
    if '--report' in sys.argv:
        events = json.loads(value)
        census = {'perch_scroll_writes': 0, 'site_scroll_writes': 0, 'scroll_events': 0}
        for event in events:
            if event['kind'] in ('scrollTo', 'scrollBy', 'scrollIntoView'):
                actor = 'perch' if 'user-script:' in event.get('stack', '') else 'site'
                census[actor + '_scroll_writes'] += 1
            if event['kind'] == 'scroll':
                census['scroll_events'] += 1
        report = {'census': census, 'events': events}
        (ROOT / 'verification/x-return-trace.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(census))
        for event in events:
            print(json.dumps({key:value for key,value in event.items() if key != 'stack'}))
    else:
        print('Scroll-writer trace installed. Navigate Back normally, then run --report.')
