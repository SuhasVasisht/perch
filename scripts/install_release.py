#!/usr/bin/env python3
"""Install Perch without changing a running executable's inode."""
import argparse
import ctypes
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
INSTALLED = Path('/Applications/Perch.app')
LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')


def exchange(left, right):
    """Atomically exchange names, leaving open files and mapped code intact."""
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(bytes(left), bytes(right), 0x00000002):  # RENAME_SWAP in sys/stdio.h
        error = ctypes.get_errno()
        raise OSError(error, 'Cannot exchange release paths', str(right))


def replace_preserving(replacement, destination, retired):
    if destination.exists() or destination.is_symlink():
        exchange(replacement, destination)
        replacement.rename(retired)
    else:
        replacement.rename(destination)


def retire_legacy(applications, workspace, applications_stage, retired):
    """Move pre-1.9 Shell bundles aside. Moves keep a running Shell's code mapped."""
    legacy = applications / 'Shell.app'
    if legacy.is_dir() and not legacy.is_symlink():
        info = plistlib.loads((legacy / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') == 'local.tweetframe':
            legacy.rename(applications_stage / 'Legacy-Shell.retired')
    workspace_legacy = workspace / 'Shell.app'
    if workspace_legacy.is_symlink() or workspace_legacy.exists():
        workspace_legacy.rename(retired / 'Workspace-Shell.retired')


def install_release(source, workspace=ROOT):
    source = source.resolve(strict=True)
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'local.tweetframe':
        raise ValueError('Expected a Perch release bundle')
    subprocess.run(['codesign', '--verify', '--strict', str(source)], check=True)
    binary = (source / 'Contents/MacOS/Perch').read_bytes()
    if b'local.perch.debug' in binary or b'OffscreenHost' in binary:
        raise ValueError('Install a release build without verification hooks')
    expected = hashlib.sha256(binary).hexdigest()
    retired = Path(tempfile.mkdtemp(prefix='release-', dir=_retired_directory(workspace)))
    applications_stage = Path(tempfile.mkdtemp(prefix='.Perch-update-', suffix='.noindex', dir=INSTALLED.parent))
    try:
        candidate = applications_stage / 'Next-Perch.retired'
        subprocess.run(['ditto', str(source), str(candidate)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(candidate)], check=True)
        assert hashlib.sha256((candidate / 'Contents/MacOS/Perch').read_bytes()).hexdigest() == expected
        # Unregister obsolete paths before replacing the workspace with a link,
        # while LaunchServices can still resolve each old bundle independently.
        registry = subprocess.check_output([str(LSREGISTER), '-dump'], text=True)
        for block in registry.split('--------------------------------------------------------------------------------'):
            if not re.search(r'^identifier:\s+local\.tweetframe\s*$', block, re.MULTILINE):
                continue
            match = re.search(r'^path:\s+(.+?) \(0x[0-9a-f]+\)\s*$', block, re.MULTILINE)
            if match and Path(match[1]) != INSTALLED:
                subprocess.run([str(LSREGISTER), '-u', match[1]], check=True)
        retire_legacy(INSTALLED.parent, workspace, applications_stage, retired)
        # Keep the old bundle on the same volume as Applications, so its code
        # stays mapped if the owner is still running it.
        replace_preserving(candidate, INSTALLED, applications_stage / 'Previous-Perch.retired')
        workspace_app = workspace / 'Perch.app'
        if workspace_app != INSTALLED:
            link = workspace / ('.Perch-link-' + uuid.uuid4().hex)
            link.symlink_to(INSTALLED, target_is_directory=True)
            replace_preserving(link, workspace_app, retired / 'Workspace-Perch.retired')
        subprocess.run([str(LSREGISTER), '-f', str(INSTALLED)], check=True)
        print(f'Installed Perch {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]}) at {INSTALLED}')
        print(f'Workspace Perch.app links to Applications. Previous bundles retained at {retired} and {applications_stage}.')
        return INSTALLED
    finally:
        if not any(applications_stage.iterdir()):
            applications_stage.rmdir()


def _retired_directory(workspace):
    directory = workspace / '.build.noindex' / 'retired'
    directory.mkdir(parents=True, exist_ok=True)
    return directory


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', type=Path, default=ROOT / 'Perch.app')
    args = parser.parse_args()
    install_release(args.app)
