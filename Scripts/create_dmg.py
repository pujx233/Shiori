#!/usr/bin/env python3
"""Package a signed Shiori.app with an Applications shortcut."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(arguments):
    subprocess.run(arguments, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if app.name != 'Shiori.app' or info.get('CFBundleIdentifier') != 'local.sai.Shiori':
        raise RuntimeError('Expected Shiori.app')
    version = info['CFBundleShortVersionString']
    output = (args.output or Path(__file__).resolve().parents[1] / 'Releases' /
              f'Shiori-{version}-macOS-arm64.dmg').resolve()
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    with tempfile.TemporaryDirectory(prefix='shiori-dmg-') as temporary:
        stage = Path(temporary) / 'contents'
        stage.mkdir()
        run(['/usr/bin/ditto', str(app), str(stage / 'Shiori.app')])
        (stage / 'Applications').symlink_to('/Applications')
        run(['/usr/bin/hdiutil', 'create', '-srcfolder', str(stage), '-volname', f'Shiori {version}',
             '-fs', 'HFS+', '-format', 'UDZO', '-nospotlight', '-quiet', str(output)])
    run(['/usr/bin/hdiutil', 'verify', '-quiet', str(output)])
    print(output)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr.decode(errors='replace').strip()) from error
