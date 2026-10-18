"""Install a verified build without changing the app's privacy identity."""
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def identity(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable'):
        if info.get(key) != 'Shiori':
            raise RuntimeError('Unexpected application name: ' + key)
    if info.get('CFBundleIdentifier') != 'local.sai.Shiori':
        raise RuntimeError('Unexpected application identifier')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    signature = run('/usr/bin/codesign', '-d', '-r-', str(app))
    lines = (signature.stdout + signature.stderr).decode().splitlines()
    return next(line for line in lines if line.startswith('designated =>'))


def main():
    source = Path(__file__).resolve().parents[1] / 'build/Shiori.app'
    destination = Path('/Applications/Shiori.app')
    requirement = identity(source)
    if destination.exists() and identity(destination) != requirement:
        raise RuntimeError('签名身份发生变化，已保留当前安装。请先检查构建签名。')
    if subprocess.run(['/usr/bin/pgrep', '-x', 'Shiori'], stdout=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError('请先退出 Shiori，再运行安装。')
    with tempfile.TemporaryDirectory(prefix='.shiori-install-', dir=destination.parent) as folder:
        stage = Path(folder) / 'Shiori.app'
        previous = Path(folder) / 'previous.app'
        run('/usr/bin/ditto', str(source), str(stage))
        if identity(stage) != requirement:
            raise RuntimeError('Staged application identity changed')
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
            identity(destination)
        except Exception:
            if destination.exists():
                destination.rename(stage)
            if previous.exists():
                previous.rename(destination)
            raise
    run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(destination))
    print('Installed: ' + str(destination))


if __name__ == '__main__':
    main()
