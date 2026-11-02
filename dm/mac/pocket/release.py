#!/usr/bin/env python3
"""Make a release of NX Pocket for Mac that the app's updater (Model/Updater.swift) takes: the app zipped, and a manifest signed with the maker's Ed25519 key.

    release.py keygen <private key file>                      a key pair: the private key into the file (kept by the maker, never committed), the public key printed;
                                                              put it in dm/mac/pocket/update-key.pub, which build.sh builds into the app (NXPocketUpdateKey)
    release.py make <private key file> <output dir> [--notes FILE] [--bundle-id ID]
                                                              builds the app (build.sh), zips it (NX-Pocket-Mac-<build>.zip, ditto) and writes nx-pocket-mac.json beside it

Upload both files to a GitHub release of the repository set in the app (Settings › Updates); the app reads releases/latest/download/nx-pocket-mac.json. This script
writes nothing anywhere but the output folder. The manifest: version, build (the commit count, the app's CFBundleVersion), commit, the zip's name, size and SHA-256, the
release notes, and an Ed25519 signature of the zip's bytes (base64). The app installs a release only when the signature checks out against the key built into it.
The app is signed ad hoc and not notarized: the updater tells the player how to open it if macOS asks, and leaves macOS's own checks as they are."""
import argparse, base64, hashlib, json, os, plistlib, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Ed25519 through CryptoKit (Swift ships with Xcode; the system's LibreSSL and this Python have no Ed25519)
SWIFT = r'''
import CryptoKit
import Foundation
let a = CommandLine.arguments
if a[1] == "keygen" {
    let k = Curve25519.Signing.PrivateKey()
    print(k.rawRepresentation.base64EncodedString()); print(k.publicKey.rawRepresentation.base64EncodedString())
} else {
    let text = try String(contentsOfFile: a[2], encoding: .utf8)   // the key file's path, not the key: arguments show in the process list
    let k = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))!)
    let data = try Data(contentsOf: URL(fileURLWithPath: a[3]))
    print(try k.signature(for: data).base64EncodedString()); print(k.publicKey.rawRepresentation.base64EncodedString())
}
'''


def swift(*args):
    with tempfile.TemporaryDirectory() as t:
        src = Path(t) / 'ed.swift'; src.write_text(SWIFT)
        r = subprocess.run(['xcrun', 'swift', str(src), *args], capture_output=True, text=True)
        if r.returncode: sys.exit(r.stderr.strip() or 'swift failed')
        return r.stdout.split()


def keygen(path):
    path = Path(path).expanduser()
    if path.exists(): sys.exit(f'{path}: exists (a new key would make the releases signed with the old one unverifiable by apps built with the new one)')
    priv, pub = swift('keygen')
    path.write_text(priv + '\n'); path.chmod(0o600)
    print(f'private key: {path} (keep it, and out of the repository)')
    print(f'public key:  {pub}')
    print(f'put the public key in {HERE / "update-key.pub"}: build.sh builds it into the app')


def make(key, out, notes, bundle_id=None):
    dirty = subprocess.run(['git', '-C', str(HERE), 'status', '--porcelain', '--untracked-files=no'], capture_output=True, text=True).stdout.strip()
    if dirty: print(f'warning: the checkout has changes not committed; the release is built with them, but its build number and commit name the last commit:\n{dirty}', file=sys.stderr)
    out = Path(out).expanduser().resolve(); out.mkdir(parents=True, exist_ok=True)
    build = out / 'build'
    subprocess.run([str(HERE / 'build.sh'), str(build), *([bundle_id] if bundle_id else [])], check=True)
    app = build / 'NX Pocket.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    pub_built = info.get('NXPocketUpdateKey', '')
    zip_name = f'NX-Pocket-Mac-{info["CFBundleVersion"]}.zip'; z = out / zip_name
    z.unlink(missing_ok=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(z)], check=True)
    sig, pub = swift('sign', str(Path(key).expanduser()), str(z))
    if pub_built != pub: sys.exit(f'the app was built with update key {pub_built or "(none)"}, the private key given is for {pub}: put {pub} in {HERE / "update-key.pub"}')
    manifest = {'version': info.get('CFBundleShortVersionString', '1.0'), 'build': int(info['CFBundleVersion']), 'commit': info.get('NXPocketCommit', ''),
                'zip': zip_name, 'size': z.stat().st_size, 'sha256': hashlib.sha256(z.read_bytes()).hexdigest(), 'signature': sig,
                'notes': Path(notes).read_text() if notes else '', 'minimumSystemVersion': info.get('LSMinimumSystemVersion', '26.0')}
    (out / 'nx-pocket-mac.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    print(f'release: {z}\nmanifest: {out / "nx-pocket-mac.json"}\nupload both to a GitHub release of the repository set in the app')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    k = sub.add_parser('keygen'); k.add_argument('key')
    m = sub.add_parser('make'); m.add_argument('key'); m.add_argument('out'); m.add_argument('--notes'); m.add_argument('--bundle-id', help='another bundle ID (a test build)')
    a = ap.parse_args()
    keygen(a.key) if a.cmd == 'keygen' else make(a.key, a.out, a.notes, a.bundle_id)


if __name__ == '__main__':
    main()
