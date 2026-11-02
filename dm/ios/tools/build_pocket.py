#!/usr/bin/env python3
"""Build NX Pocket (dm/ios/pocket): the one app that imports game packs (build_pack.py) and plays them.

It is signed with the team's development certificate (automatic signing); every pack it loads must be signed by the same team. The app asks for the Increased Memory Limit
entitlement, which needs a profile made for its bundle ID (Xcode with the team's account signed in, -allowProvisioningUpdates); --no-memory-limit leaves it out, so the team's
wildcard profile signs it (enough for a Mac, too little memory for a large game on an iPhone).
--mac also runs it on this Mac (an Apple silicon Mac runs the iPhone app; it must be in the team's profile): wrapped as macOS installs an iPhone app, and opened with
DM_POCKET_SYSLOG=1 (its log and the game's in the system log: log stream --predicate 'subsystem == "nxpocket"'). --pack <pack> puts that pack inside the app and imports and
plays it at start (DM_POCKET_PACK / DM_POCKET_PLAY): the Mac's sandbox lets the app read no other folder without the file picker. The Mac must be unlocked: macOS suspends an
iPhone app whose window is not on screen.
--device <UDID> installs it on that iPhone (xcrun devicectl).
--certificate <file.p12> --certificate-password-file <file> builds the team's developer certificate into the app (EmbeddedCertificate.p12 and .txt): NX Pocket moves it into the
Keychain on its first launch and signs packs with it, so a build made for a friend's phone (its device in the team's profile) needs no import there. Whoever has the app has
the certificate and its private key: give such a build only to people you would give the certificate to. It must be of --team (NX Pocket checks it when it adopts it).
Usage: build_pocket.py --team <team ID> --bundle-id <ID> --output <dir> [--no-memory-limit] [--certificate <p12> --certificate-password-file <file>] [--mac [--pack <dir>.nxpack]] [--device <UDID>]
"""
import argparse, json, os, plistlib, re, shutil, struct, subprocess, sys
from pathlib import Path

POCKET = Path(__file__).resolve().parents[1] / 'pocket'


def run(cmd, **kw):
    print('$ ' + ' '.join(str(c) for c in cmd), flush=True)
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


def mac_destination():   # this Mac as a "Designed for iPad" destination (xcodebuild -showdestinations)
    out = subprocess.run(['xcodebuild', '-showdestinations', '-project', 'NXPocket.xcodeproj', '-scheme', 'NXPocket'], cwd=POCKET, capture_output=True, text=True).stdout
    m = re.search(r'platform:macOS, arch:arm64, variant:Designed for (?:\[[^\]]*\]|[^,]*), id:([0-9A-F-]+)', out)   # "Designed for [iPad,iPhone]" has a comma in it
    if not m: sys.exit('this Mac is not an iPhone-app destination (an Apple silicon Mac, in the team\'s profile)')
    return f'id={m.group(1)},arch=arm64'


def build_number():
    """CFBundleVersion and NXPocketCommit: the checkout's commit count and its commit (NX Pocket for Mac compares the count with the one installed on an iPhone)"""
    git = lambda *a: subprocess.run(['git', '-C', str(POCKET), *a], capture_output=True, text=True).stdout.strip()
    return {'DM_POCKET_BUILD': git('rev-list', '--count', 'HEAD') or '1', 'DM_POCKET_COMMIT': git('rev-parse', '--short=12', 'HEAD') or 'unknown'}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--team', required=True, help='the development team (the packs must be signed by it too)')
    ap.add_argument('--bundle-id', required=True)
    ap.add_argument('--output', required=True, type=Path, help='build products (keep them on the scratch drive)')
    ap.add_argument('--no-memory-limit', action='store_true', help='leave out the Increased Memory Limit entitlement (the wildcard profile signs the app)')
    ap.add_argument('--mac', action='store_true', help='build for this Mac and open it')
    ap.add_argument('--pack', type=Path, help='with --mac: a pack to put in the app and play at start')
    ap.add_argument('--device', help='install on this iPhone (UDID)')
    ap.add_argument('--certificate', type=Path, help='a .p12 of the team to build into the app (signs packs on the phone)')
    ap.add_argument('--certificate-password-file', type=Path, help="a file holding the .p12's password (none: no password)")
    a = ap.parse_args()
    out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DM_BUNDLE_ID=a.bundle_id, DM_TEAM_ID=a.team, DM_POCKET_ENTITLEMENTS='' if a.no_memory_limit else 'NXPocket.entitlements', **build_number())
    run(['xcodegen', 'generate', '--spec', 'project.yml', '--quiet'], cwd=POCKET, env=env)
    dest = mac_destination() if a.mac else 'generic/platform=iOS'
    run(['xcodebuild', '-project', 'NXPocket.xcodeproj', '-scheme', 'NXPocket', '-configuration', 'Release', '-destination', dest, '-allowProvisioningUpdates',
         '-derivedDataPath', out / 'dd', '-quiet', 'build'], cwd=POCKET)
    app = out / 'dd/Build/Products/Release-iphoneos/NXPocket.app'
    if a.certificate:   # into the built app, which is signed again over it (its profile and entitlements kept)
        shutil.copyfile(a.certificate, app / 'EmbeddedCertificate.p12')
        pw = a.certificate_password_file.read_text().strip() if a.certificate_password_file else ''
        (app / 'EmbeddedCertificate.txt').write_text(pw)
        ident = re.search(r'Authority=(Apple Development: [^\n]+)', subprocess.run(['codesign', '-dvv', app], capture_output=True, text=True).stderr).group(1)
        run(['codesign', '--force', '--sign', ident, '--preserve-metadata=entitlements,identifier', app])
        print('certificate: built in (EmbeddedCertificate.p12)')
    print(f'app: {app}')
    if a.device:
        run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', a.device, app])
    if a.mac:
        wrap = out / 'mac/NX Pocket.app'   # how macOS installs an iPhone app: <name>.app/Wrapper/<app>, WrappedBundle → it
        subprocess.run(['pkill', '-f', 'Wrapper/NXPocket.app/NXPocket'])
        if wrap.exists(): shutil.rmtree(wrap)
        (wrap / 'Wrapper').mkdir(parents=True)
        run(['ditto', app, wrap / 'Wrapper/NXPocket.app'])
        (wrap / 'WrappedBundle').symlink_to('Wrapper/NXPocket.app')
        opts = ['--env', 'DM_POCKET_SYSLOG=1']
        if a.pack:
            inside = wrap / 'Wrapper/NXPocket.app/Packs'
            inside.mkdir()
            run(['cp', '-cR', a.pack.resolve(), inside])   # an APFS clone on the same volume
            sha = re.search(r'Authority=(Apple Development: [^\n]+)', subprocess.run(['codesign', '-dvv', app], capture_output=True, text=True).stderr).group(1)
            run(['codesign', '--force', '--sign', sha, '--preserve-metadata=entitlements,identifier', wrap / 'Wrapper/NXPocket.app'])   # the pack is part of the app now
            title = json.loads(pack_json(a.pack))['titleID']
            opts += ['--env', f'DM_POCKET_PACK=Packs/{a.pack.name}', '--env', f'DM_POCKET_PLAY={title}']
        run(['open', *opts, wrap])


def pack_json(pack):
    """A pack's pack.json: a folder's file, or a single file's member (build_pack.py single_file: the trailer's table of contents says where it is)"""
    if pack.is_dir(): return (pack / 'pack.json').read_text()
    with open(pack, 'rb') as f:
        f.seek(-4096, 2); t = f.read(4096)
        if t[:8] != b'NXPACK3\0': sys.exit(f'{pack}: not a game pack (no trailer: cut off?)')
        toc_off, toc_len = struct.unpack('<QQ', t[24:40])
        f.seek(toc_off); m = next(x for x in json.loads(f.read(toc_len))['members'] if x['name'] == 'pack.json')
        f.seek(m['offset']); return f.read(m['size']).decode()


if __name__ == '__main__':
    main()
