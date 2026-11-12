#!/usr/bin/env python3
"""NX Pocket for Mac's tool kit: everything making a game pack needs beside Xcode, in one archive the app downloads into Application Support (Setup, ToolKit.swift),
so a player installs no Homebrew, no Python and no .NET, and types no password for them.

    make_tools.py <output dir>     writes nx-pocket-tools-<VERSION>.tar.gz, cut into parts of PART bytes (.00, .01, ...), and tools.lock beside this file (the
                                   parts' base URL and count, the whole archive's size and SHA-256, which build.sh builds into the app)

The archive holds, under nx-pocket-tools/:
    python/      a standalone CPython (python-build-standalone, relocatable) with requirements.txt installed into it
    bin/         zstd (built here from its source, arm64), glslangValidator (Khronos' macOS release), xcodegen (its release, with share/xcodegen)
Every download is pinned by its SHA-256 below. Upload the parts to the GitHub release tagged tools-<VERSION> of the repository the app updates from
(parts, so each stays under the 10 MB a browser upload in this setup takes; the app joins them and checks the whole);
a new VERSION only when the kit changes, so app releases do not carry it again."""
import hashlib, os, shutil, subprocess, sys, tarfile, tempfile, urllib.request, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERSION = '1'
REPO = 'zkkzkk/nx-pocket'
SOURCES = {   # name: (url, sha256)
    'python': ('https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.13.17+20261021-aarch64-apple-darwin-install_only.tar.gz', '9c985cbf327425873469896ce748c7134b6deca8edb81e93c589ad2fc5aff445'),
    'zstd': ('https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz', 'eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3'),
    'glslang': ('https://github.com/KhronosGroup/glslang/releases/download/16.6.0/glslang-16.6.0-macos-universal-release.tar.gz', '4f8c05f2888a73ed0b7b274bc524af9130e09ae94b43c0f3f9ed83cfae852834'),
    'xcodegen': ('https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip', '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806'),
}
MACOS_MIN = '26.0'
PART = 9_000_000


def fetch(name, dl):
    url, want = SOURCES[name]
    path = dl / url.rsplit('/', 1)[1]
    if not path.exists():
        print(f'downloading {name}: {url}', flush=True)
        with urllib.request.urlopen(url) as r, open(path, 'wb') as f: shutil.copyfileobj(r, f)
    got = hashlib.sha256(path.read_bytes()).hexdigest()
    if want and got != want: sys.exit(f'[RED] {name}: SHA-256 {got}, pinned {want} ({url})')
    if not want: print(f'{name}: sha256 {got} (not pinned yet)')
    return path


def run(*cmd, **kw):
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
    dl = out / 'downloads'; dl.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='nx-pocket-tools-') as t:
        root = Path(t) / 'nx-pocket-tools'; (root / 'bin').mkdir(parents=True)
        # Python, then the modules, from wheels only (nothing compiled on the player's Mac, nothing here either)
        with tarfile.open(fetch('python', dl)) as tf: tf.extractall(root, filter='tar')   # python/ at the top
        py = root / 'python/bin/python3'
        run(py, '-m', 'pip', 'install', '--no-cache-dir', '--only-binary', ':all:', '--no-warn-script-location', '-r', HERE / 'requirements.txt')
        for m in ('lz4', 'capstone', 'fontTools', 'nsz', 'zbic', 'backports.zstd'): run(py, '-c', f'import {m}')
        # zstd: built from its source, so it links nothing but the system's libraries
        src = Path(t) / 'zstd-src'; src.mkdir()
        with tarfile.open(fetch('zstd', dl)) as tf: tf.extractall(src, filter='tar')
        zdir = next(src.iterdir())
        env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=MACOS_MIN, CFLAGS=f'-O2 -arch arm64 -mmacosx-version-min={MACOS_MIN}')
        run('make', '-C', zdir / 'programs', '-j8', 'zstd-release', env=env, stdout=subprocess.DEVNULL)
        shutil.copy2(zdir / 'programs/zstd', root / 'bin/zstd')
        # glslangValidator: Khronos' universal release
        g = Path(t) / 'glslang'; g.mkdir()
        with tarfile.open(fetch('glslang', dl)) as tf: tf.extractall(g, filter='tar')
        shutil.copy2(next(g.rglob('bin/glslangValidator')), root / 'bin/glslangValidator')
        # xcodegen: its release (bin/xcodegen and share/xcodegen, the setting presets it reads beside its executable)
        x = Path(t) / 'xcodegen'; x.mkdir()
        with zipfile.ZipFile(fetch('xcodegen', dl)) as zf: zf.extractall(x)
        xg = next(x.rglob('bin/xcodegen')); (root / 'share').mkdir()
        shutil.copy2(xg, root / 'bin/xcodegen'); os.chmod(root / 'bin/xcodegen', 0o755)
        shutil.copytree(xg.parent.parent / 'share/xcodegen', root / 'share/xcodegen')
        for tool, arg in (('zstd', '--version'), ('glslangValidator', '--version'), ('xcodegen', '--version')):
            run(root / 'bin' / tool, arg, stdout=subprocess.DEVNULL)
        # no quarantine and no Python caches of this Mac's paths in the archive
        for p in root.rglob('__pycache__'): shutil.rmtree(p)
        name = f'nx-pocket-tools-{VERSION}.tar.gz'; arc = out / name
        with tarfile.open(arc, 'w:gz', compresslevel=9) as tf: tf.add(root, arcname='nx-pocket-tools')
    data = arc.read_bytes(); sha = hashlib.sha256(data).hexdigest(); size = len(data)
    parts = [data[i:i + PART] for i in range(0, size, PART)]
    for n, part in enumerate(parts): (out / f'{name}.{n:02d}').write_bytes(part)
    url = f'https://github.com/{REPO}/releases/download/tools-{VERSION}/{name}'
    (HERE / 'tools.lock').write_text(f'# NX Pocket for Mac\'s tool kit (make_tools.py): build.sh builds these into the app (NXPocketTools*); url is the parts\' base (url.00, url.01, ...)\n'
                                     f'version\t{VERSION}\nurl\t{url}\nparts\t{len(parts)}\nsize\t{size}\nsha256\t{sha}\n')
    print(f'tool kit: {arc} ({size / 1e6:.1f} MB, sha256 {sha}) in {len(parts)} parts\nupload {name}.00 to .{len(parts) - 1:02d} to the release tools-{VERSION} of {REPO}; tools.lock updated')


if __name__ == '__main__':
    main()
