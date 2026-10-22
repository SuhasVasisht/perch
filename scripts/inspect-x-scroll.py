#!/usr/bin/env python3
"""List every host-owned scroll adjustment before and after a change."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
patterns = {
    'Native wheel takeover': r'onScroll\s*=',
    'Feed window size requests': r'(?:resize\(to:|fitWindow\(to:)',
    'Native frame animation': r'animator\(\)\.setFrame\(',
    'Page scroll writes': r'window\.scroll(?:To|By)\(',
    'Browser post alignment': r'\.scrollIntoView\(',
    'Keyboard animation requests': r'fitPost\(true(?:,|\))|requestAnimationFrame\(step\)',
    'Gesture and fit debounce': r'setTimeout\(fitPost, 200\)|}, 150\)',
    'Post pin requests': r'\bpin\(row\)',
    'Repeating page timer': r'setInterval\(',
}
for label, pattern in patterns.items():
    matches = []
    for name in ['XWidget.swift', 'CropScript.swift']:
        path = root / 'Sources/Perch' / name
        for line, text in enumerate(path.read_text().splitlines(), 1):
            if re.search(pattern, text):
                matches.append(f'  {name}:{line}: {text.strip()}')
    print(f'{label}: {len(matches)}')
    print('\n'.join(matches))
