"""Prevent legacy foreground checks from running accidentally."""
import sys


def require_interactive(*, allow_compile_only=False):
    if allow_compile_only and '--compile-only' in sys.argv:
        return
    if '--interactive' not in sys.argv:
        print('This check changes desktop focus. It requires --interactive and an agreed idle window. '
              'X navigation/session/scroll verification runs without taking focus by default.', file=sys.stderr)
        raise SystemExit(2)
    sys.argv.remove('--interactive')
