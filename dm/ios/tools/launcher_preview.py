#!/usr/bin/env python3
"""Build the launcher preview app (dm/ios/preview) for the iOS Simulator, and optionally install and start it on a booted simulator.

The preview app is the iOS launcher's own sources (Launcher.swift, LauncherHome.swift, GameLibrary.swift, ...) with no game host, so it runs where the game cannot.
It takes a game's dm/launcher.json and icon from that game's prepared Xcode project (<NSP folder>/<id>_build/xcode), and adds LAUNCHER_DEMO's made-up games; --demo-icon
<title ID>=<image> gives one of them a real icon (copied into the preview's Gen/, which git ignores: game art stays out of the repository).
Usage: launcher_preview.py --xcode <game's xcode dir> --output <new or earlier output dir> [--name N] [--version V] [--demo-icon ID=IMG ...] [--device UDID]
"""
import argparse, json, os, plistlib, shutil, subprocess, sys
from pathlib import Path

PREVIEW = Path(__file__).resolve().parents[1] / 'preview'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--xcode', required=True, type=Path, help="a game's prepared Xcode project directory (Gen/dm/launcher.json, Gen/Assets.xcassets)")
    ap.add_argument('--output', required=True, type=Path, help='build products and DerivedData (keep it on the scratch drive)')
    ap.add_argument('--name', help='the game name shown (default: the project\'s DM_DISPLAY_NAME)')
    ap.add_argument('--version', default='', help='the game version shown (default: the build\'s DM_RESOURCE_VERSION)')
    ap.add_argument('--demo-icon', action='append', default=[], metavar='ID=IMAGE', help="a demo game's icon (GameLibrary.swift demoGames)")
    ap.add_argument('--device', help='a booted simulator\'s UDID: install the app and start it')
    a = ap.parse_args()

    launcher = a.xcode / 'Gen/dm/launcher.json'
    if not launcher.is_file(): sys.exit(f'{launcher}: not found (prepare the game\'s Xcode project first)')
    json.loads(launcher.read_text())   # stop on a broken file here rather than in the app
    gen = PREVIEW / 'Gen'
    shutil.rmtree(gen, ignore_errors=True)
    (gen / 'dm').mkdir(parents=True); (gen / 'demo').mkdir()
    shutil.copy(launcher, gen / 'dm/launcher.json')
    icons = a.xcode / 'Gen/Assets.xcassets'
    if (icons / 'AppIcon.appiconset/icon.png').is_file(): shutil.copytree(icons, gen / 'Assets.xcassets')
    else: (gen / 'Assets.xcassets').mkdir(); print('no game icon: the preview shows a blank one')
    for pair in a.demo_icon:
        tid, _, img = pair.partition('=')
        subprocess.run(['sips', '-s', 'format', 'png', '-z', '256', '256', img, '--out', str(gen / 'demo' / f'{tid}.png')], check=True, stdout=subprocess.DEVNULL)

    # The name and version the game's build gave its app (Gen/Info.plist, Gen/resources.env)
    plist = a.xcode / 'Gen/Info.plist'
    name = a.name or (plistlib.loads(plist.read_bytes()).get('CFBundleDisplayName') if plist.is_file() else None) or 'Game'
    res = a.xcode / 'Gen/resources.env'
    version = a.version or next((l.split('=', 1)[1].strip() for l in (res.read_text().splitlines() if res.is_file() else []) if l.startswith('DM_RESOURCE_VERSION=')), '1.0')
    env = {'DM_DISPLAY_NAME': name, 'DM_APP_VERSION': version}
    subprocess.run(['xcodegen', 'generate', '--spec', 'project.yml', '--quiet'], cwd=PREVIEW, check=True, env={**os.environ, **env})
    out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcodebuild', '-project', 'LauncherPreview.xcodeproj', '-scheme', 'LauncherPreview', '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={a.device}' if a.device else 'generic/platform=iOS Simulator',
                    '-derivedDataPath', str(out / 'DerivedData'), '-quiet', 'build'], cwd=PREVIEW, check=True)
    app = out / 'DerivedData/Build/Products/Debug-iphonesimulator/LauncherPreview.app'
    print(app)
    if a.device:
        bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
        subprocess.run(['xcrun', 'simctl', 'install', a.device, str(app)], check=True)
        subprocess.run(['xcrun', 'simctl', 'terminate', a.device, bundle], stderr=subprocess.DEVNULL)
        subprocess.run(['xcrun', 'simctl', 'launch', a.device, bundle], check=True)


if __name__ == '__main__':
    main()
