#!/usr/bin/env python3
"""Package buildable Perch sources and publish a source-only Homebrew tap."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = 'SuhasVasisht/perch'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def github(path, missing_ok=False):
    result = subprocess.run(['gh', 'api', path], capture_output=True, text=True)
    if result.returncode:
        if missing_ok and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def repository(value):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value):
        raise argparse.ArgumentTypeError('Use a GitHub repository in owner/name form')
    return value


def package(root, destination, repo):
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+(?:\.\d+)*', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Info.plist must contain a numeric release version and build')
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / f'Perch-{version}-source.tar.gz'
    # An allowlist keeps local accounts, recordings, and prebuilt apps out of releases.
    paths = [Path(name) for name in (
        'build.sh', 'Info.plist', 'LICENSE',
        'Assets/AppIcon.png', 'scripts/make-icon.swift',
    )]
    paths += sorted(path.relative_to(root) for path in (root / 'Sources/Perch').glob('*.swift'))
    if not any(path.name == 'AppMain.swift' for path in paths):
        raise ValueError('Perch sources are missing')
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, filename='', mode='wb', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as tar:
            for path in sorted(paths):
                source = root / path
                if source.is_symlink() or not source.is_file():
                    raise ValueError(f'Expected a regular release source file: {path}')
                entry = tar.gettarinfo(str(source), f'Perch-{version}/{path.as_posix()}')
                entry.uid = entry.gid = entry.mtime = 0
                entry.uname = entry.gname = ''
                entry.mode = 0o755 if path.as_posix() == 'build.sh' else 0o644
                with source.open('rb') as stream:
                    tar.addfile(entry, stream)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = destination / (archive.name + '.sha256')
    checksum.write_text(f'{digest}  {archive.name}\n')
    formula = (root / 'packaging/homebrew/perch.rb.in').read_text()
    values = {
        'REPO': repo, 'VERSION': version, 'BUILD': build, 'SHA256': digest,
        'SOURCE_URL': f'https://github.com/{repo}/releases/download/v{version}/{archive.name}',
    }
    for key, value in values.items():
        formula = formula.replace(f'@{key}@', value)
    formula_path = destination / 'perch.rb'
    formula_path.write_text(formula)
    print(f'Source: {archive}\nSHA256: {digest}\nFormula: {formula_path}', flush=True)
    return version, archive, checksum, formula_path


def publish(root, destination, repo, tap_repo):
    if shutil.which('gh') is None:
        raise RuntimeError('Install GitHub CLI and run gh auth login before publishing')
    if output('git', 'status', '--porcelain', '--untracked-files=normal', cwd=root):
        raise RuntimeError('Commit your release changes before publishing. The checkout must be clean.')
    source = github(f'repos/{repo}', missing_ok=True)
    if source is None:
        raise RuntimeError(f'Create the public {repo} repository and push your release commit first. See README.md.')
    if source['private']:
        raise RuntimeError('The source repository must be public for this public Homebrew tap')
    tap = github(f'repos/{tap_repo}', missing_ok=True)
    if tap and tap['private']:
        raise RuntimeError('The Homebrew tap repository must be public')
    commit = output('git', 'rev-parse', 'HEAD', cwd=root)
    github(f'repos/{repo}/commits/{commit}')  # Require the exact release commit to be pushed.
    # Read the pinned commit, so another worker's later edits cannot enter this release.
    snapshot = subprocess.check_output([
        'git', 'archive', '--format=tar', commit, '--', 'build.sh', 'Info.plist', 'LICENSE',
        'Assets/AppIcon.png', 'scripts/make-icon.swift', 'Sources/Perch', 'packaging/homebrew/perch.rb.in',
    ], cwd=root)
    with tempfile.TemporaryDirectory(prefix='perch-release-source-') as directory:
        with tarfile.open(fileobj=io.BytesIO(snapshot)) as tar:
            tar.extractall(directory)
        version, archive, checksum, formula = package(Path(directory), destination, repo)
    tag = f'v{version}'
    tagged_commit = github(f'repos/{repo}/commits/{tag}', missing_ok=True)
    if tagged_commit and tagged_commit['sha'] != commit:
        raise RuntimeError(f'{tag} already points to another commit. Bump the version in Info.plist.')
    release = github(f'repos/{repo}/releases/tags/{tag}', missing_ok=True)
    if release:
        if release['draft']:
            raise RuntimeError(f'{tag} is a draft release. Publish it before updating the tap.')
        existing = {asset['name'] for asset in release['assets']}
        pending = []
        for artifact in (archive, checksum):
            if artifact.name in existing:
                with tempfile.TemporaryDirectory(prefix='perch-release-check-') as directory:
                    run('gh', 'release', 'download', tag, '--repo', repo, '--pattern', artifact.name, '--dir', directory)
                    if (Path(directory) / artifact.name).read_bytes() != artifact.read_bytes():
                        raise RuntimeError(f'Refusing to replace published {artifact.name}. Bump the version in Info.plist.')
            else:
                pending.append(artifact)
        for artifact in pending:
            run('gh', 'release', 'upload', tag, str(artifact), '--repo', repo)
    else:
        with tempfile.TemporaryDirectory(prefix='perch-release-notes-') as directory:
            notes = Path(directory) / 'notes.md'
            notes.write_text('Build Perch locally with Homebrew. Requires macOS 26 or later on Apple silicon and Xcode command line tools.\n\n'
                             f'```sh\nbrew install {tap_repo.replace("/homebrew-", "/")}/perch\nperch\n```\n')
            run('gh', 'release', 'create', tag, str(archive), str(checksum), '--repo', repo,
                '--target', commit, '--title', f'Perch {version}', '--notes-file', str(notes))
    if tap is None:
        run('gh', 'repo', 'create', tap_repo, '--public', '--description', 'Homebrew source builds for Perch')
    with tempfile.TemporaryDirectory(prefix='perch-tap-publish-') as directory:
        checkout = Path(directory) / 'tap'
        run('gh', 'repo', 'clone', tap_repo, str(checkout))
        (checkout / 'Formula').mkdir(exist_ok=True)
        shutil.copy2(formula, checkout / 'Formula/perch.rb')
        # Add only our formula, preserving any other packages in an existing tap.
        run('git', 'add', 'Formula/perch.rb', cwd=checkout)
        diff = subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=checkout)
        if diff.returncode == 1:
            run('git', 'commit', '-m', f'perch {version}', cwd=checkout)
            run('git', 'push', 'origin', 'HEAD', cwd=checkout)
        else:
            diff.check_returncode()
    tap_name = tap_repo.replace('/homebrew-', '/')
    print(f'Published https://github.com/{repo}/releases/tag/{tag}\n'
          f'Tap: https://github.com/{tap_repo}\nInstall: brew install {tap_name}/perch', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('package', 'publish'))
    parser.add_argument('--repo', type=repository, default=DEFAULT_REPO, help='source GitHub repository')
    parser.add_argument('--tap-repo', type=repository, help='defaults to <source owner>/homebrew-tap')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/homebrew')
    args = parser.parse_args()
    tap_repo = args.tap_repo or f'{args.repo.split("/")[0]}/homebrew-tap'
    if not tap_repo.split('/')[1].startswith('homebrew-'):
        parser.error('--tap-repo must be named owner/homebrew-name')
    try:
        if args.command == 'package':
            package(ROOT, args.output.resolve(), args.repo)
        else:
            publish(ROOT, args.output.resolve(), args.repo, tap_repo)
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Homebrew release failed: {error}\n')


if __name__ == '__main__':
    main()
