#!/usr/bin/env python3
"""Build a game pack (<name>.nxpack) that NX Pocket imports and plays (dm/ios/pocket): the game's code as a signed library, and its files beside it.

A pack is a folder:
  pack.json        format, title ID, name, version, language, the shader chain, the library's path (NX Pocket reads it; main.m dm_pack_start too)
  icon.png         the game's icon (the home screen's tile and background)
  Game.framework/  the host and the game's rewritten modules (dm/ios/pack.yml), signed with the team's development certificate: iOS loads only a library signed by the
                   same team as the app that loads it. --unsigned leaves it ad hoc signed (no certificate, no team): NX Pocket signs it on the phone with the certificate it
                   holds (PackSign.c), so one pack plays in anyone's NX Pocket
  dm/              the rewriter tables, shader tables, launcher.json and font, as in the app (build_ipa.sh)
  romfs.img        the game files (or romfs/), aoc/ and pso/ when the game has them
  msl.aar          the shader libraries (msl/<chain>/: tens of thousands of small files, or msl/<chain>.img, one file) as one Apple Archive, lzfse-compressed (`aa archive`), which NX Pocket unpacks
                   on the phone before the game first starts (PackArchive.swift): a pack then copies to a phone as a few hundred files, not a hundred thousand
                   (format 2; --format 1 keeps msl/ as a folder, for an NX Pocket from before format 2)

--format 3 makes the pack one file instead (single_file below), to send with AirDrop or keep on a drive: the RomFS image as it is at the start (a clone of it on the same
volume, so making the pack copies nothing large), then pack.json, icon.png and extract.aar (everything else: Game.framework, dm/, msl/, aoc/, pso/, pack.json, lzfse), a table
of contents and a trailer at the end. NX Pocket unpacks extract.aar once and reads the game files from the pack file itself (DM_ROMFS_SIZE, hle_fs.c), so a phone needs
no second copy of them. --convert <pack folder> makes a format 3 file of a pack already made (format 1 or 2) without building it again.

It starts from the game's prepared Xcode project (build_ipa_from_nsp.py --prepare-xcode: <NSP folder>/<id>_build/xcode), whose Gen/ has the embedded modules and the resource
paths, and builds the library from this checkout's sources. The large files are APFS clones when the pack is on the same volume as the build (no space taken), copies otherwise.
Usage: build_pack.py --xcode <game's xcode dir> --output <dir>/<name>.nxpack [--team <team ID>] [--identity <SHA-1> | --unsigned] [--format 1|2|3] [--work <dir>]
       build_pack.py --convert <dir>/<name>.nxpack --output <dir>/<name>.nxpack   (a pack folder to one file, format 3)
"""
import argparse, concurrent.futures, hashlib, json, os, plistlib, re, shutil, struct, subprocess, sys, time
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]
DM = IOS.parent
FORMAT = 2   # pack.json's format: 2 = msl/ as msl.aar; NX Pocket reads 1 and 2 (GameLibrary.swift PackInfo)


class Progress:
    """The build's stages: 'step: <name>' lines, or with --progress json the NSP script's events (scripts/build_ipa_from_nsp.py, Progress) for a program
    that shows the build (NX Pocket for Mac): stage when one starts, stage_end when the next starts or the pack is written, say with "[RED] " when it fails"""
    def __init__(self): self.json, self.n, self.k, self.cur = False, 0, 0, None
    def _emit(self, obj): print(json.dumps(obj, ensure_ascii=False), flush=True)
    def end(self, ok=True):
        if self.json and self.cur:
            self._emit({'ev': 'stage_end', 'k': self.k, 'name': self.cur[0], 'ok': ok, 'summary': '', 'elapsed': round(time.time() - self.cur[1], 3)})
        self.cur = None
    def step(self, name, detail=''):
        if not self.json: print(f'step: {name}' + (f' ({detail})' if detail else ''), flush=True); return
        self.end(); self.k += 1; self.cur = (name, time.time())
        self._emit({'ev': 'stage', 'k': self.k, 'n': self.n, 'name': name, 'step': detail, 't': round(time.time(), 3)})
    def progress(self, done, total, t0):   # how far the current stage is (the NSP script's progress event: frac, eta)
        if not self.json or not self.cur or total <= 0: return
        frac = min(done / total, 1); el = time.time() - t0
        self._emit({'ev': 'progress', 'k': self.k, 'name': self.cur[0], 'step': '', 'frac': round(frac, 4), **({'eta': round(el / frac - el, 1)} if frac > 0.02 else {})})
    def fail(self, msg):
        if self.json: self.end(False); self._emit({'ev': 'say', 'msg': '[RED] ' + msg.splitlines()[0]})
        sys.exit(msg)


P = Progress()
def step(name, detail=''): P.step(name, detail)


# The single-file pack (format 3). Its trailer, the file's last TRAILER bytes: MAGIC, the format (u32) and a spare u32, the file's whole length, the table of contents'
# offset and length and its SHA-256, zeros, and MAGIC again in the last 8 bytes. The table (JSON) lists the members (name, offset, size, kind; an archive's folder, the
# SHA-256 of each but the game files) and the SHA-256 of every CHUNK bytes of the file before it, null for a chunk of the game files whose checksum was not worked out:
# NX Pocket checks the small members always (a quick check) and every chunk when they all have one (a full check: --verify full, or the image's checksums kept from the
# extraction, <image>.chunks.json, which nx_extract writes as it writes the image when NX_EXTRACT_CHUNK_SUMS is set)
MAGIC, TRAILER, CHUNK = b'NXPACK3\0', 4096, 64 << 20
ALIGN_ROMFS, ALIGN = 64 << 10, 16 << 10


def msl_archive(shaders, msldir, dst):
    """msl/<msldir>/ as one Apple Archive, straight from the build's shader folder (aa renames its paths): no copy of its tens of thousands of files is made.
    An NVN game's libraries can be one file instead, <msldir>.img (dm/tools/shader_lib.py), which the host reads as it is: the archive then holds that file,
    so NX Pocket unpacks it into msl/ as before"""
    if shaders.is_file():
        stage = dst.with_name('.' + dst.name + '.stage')
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir(parents=True)
        try:
            clone(shaders, stage / f'{msldir}.img')
            subprocess.run(['aa', 'archive', '-d', str(stage), '-o', str(dst), '-a', 'lzfse'], check=True)
        finally: shutil.rmtree(stage)
        return
    subprocess.run(['aa', 'archive', '-d', str(shaders.parent), '-subdir', shaders.name, '-rename', shaders.name, msldir, '-o', str(dst), '-a', 'lzfse'], check=True)


def upscale_icon(src, dst):
    """icon@4x.png (1024×1024) of the game's icon, made on this Mac (upscale_icon.swift: MetalFX's spatial scaler, else Lanczos); left out when it cannot be made"""
    r = subprocess.run(['xcrun', 'swift', str(IOS / 'tools/upscale_icon.swift'), str(src), str(dst)], capture_output=True, text=True)
    if r.returncode or not dst.is_file(): print(f'icon@4x.png not made: {(r.stderr or r.stdout).strip()[:200]}', flush=True); dst.unlink(missing_ok=True)


def discard(path):
    """Removes a folder of many files (an old pack folder) in the background: renamed aside at once, deleted by a process of its own that outlives this one (a USB drive
    deletes a few thousand files a second)"""
    if not path.exists(): return
    aside = path.with_name(f'.{path.name}.old-{os.getpid()}-{int(time.time())}')
    path.rename(aside)
    subprocess.Popen(['rm', '-rf', str(aside)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def single_file(folder, out, romfs_source=None, full=False):
    """Writes the pack folder `folder` (format 1 or 2) as one file at `out` (format 3). Its shader archive (format 2) goes in as it is, a shader folder (format 1) is
    archived straight from where it is; the rest but the game files becomes extract.aar. romfs_source: the RomFS image its romfs.img was cloned from, beside which the
    image's checksums are kept. full: every chunk's checksum, reading the game files when they are not kept (a USB drive may take minutes)"""
    romfs = folder / 'romfs.img'
    if not romfs.is_file(): P.fail(f'{folder}: a single-file pack needs the game files as one RomFS image (romfs.img), not a folder')
    pack = json.loads((folder / 'pack.json').read_text())
    # the game files are read from the pack file by the pack's own host (Game.framework: hle_fs.c img_open, DM_ROMFS_SIZE); a host from before that finds no game files
    if not pack.get('romfsInPack'): P.fail(f'{folder}: its library is from before single-file packs (its host cannot read the game files from the pack file); make the pack again: build_pack.py --xcode <game\'s xcode dir> --format 3')
    archives = pack.pop('archives', None) or []
    pack['format'] = 3
    part = out.with_name(out.name + '.partial'); part.unlink(missing_ok=True)
    stage = out.with_name('.' + out.name + '.stage')
    if stage.exists(): shutil.rmtree(stage)
    made = []   # archives made here, removed at the end
    try:
        step('single file')
        # extract.aar: the small parts (the library, dm/, the icon, aoc/, pso/, pack.json), cloned into a stage of a few hundred files
        stage.mkdir(parents=True)
        for c in folder.iterdir():
            if c.name in ('romfs.img', 'pack.json', 'msl') or c.suffix == '.aar': continue
            clone(c, stage / c.name)
        meta = (json.dumps(pack, indent=2, ensure_ascii=False) + '\n').encode()
        (stage / 'pack.json').write_bytes(meta)
        extract = out.with_name('.' + out.name + '.extract.aar'); made.append(extract)
        subprocess.run(['aa', 'archive', '-d', str(stage), '-o', str(extract), '-a', 'lzfse'], check=True)
        shutil.rmtree(stage)
        shaders = [(folder / a['file'], a['folder']) for a in archives]   # format 2: its archives as they are
        icon4x = folder / 'icon@4x.png'
        if not icon4x.is_file() and (folder / 'icon.png').is_file():   # a pack made before icon@4x: made now, from its icon
            icon4x = out.with_name('.' + out.name + '.icon@4x.png'); made.append(icon4x); upscale_icon(folder / 'icon.png', icon4x)
        if not shaders and (folder / 'msl' / (pack['shaders'] + '.img')).is_file():   # format 1 with the libraries as one file
            m = out.with_name('.' + out.name + '.msl.aar'); made.append(m)
            msl_archive(folder / 'msl' / (pack['shaders'] + '.img'), pack['shaders'], m); shaders = [(m, 'msl')]
        if not shaders and (folder / 'msl' / pack['shaders']).is_dir():   # format 1: its shader folder, archived from where it is
            m = out.with_name('.' + out.name + '.msl.aar'); made.append(m)
            msl_archive(folder / 'msl' / pack['shaders'], pack['shaders'], m); shaders = [(m, 'msl')]
        clone(romfs, part)   # the game files first, as they are: a clone on the same volume
        size = part.stat().st_size
        members = [{'name': 'romfs.img', 'offset': 0, 'size': size, 'kind': 'romfs'}]
        with open(part, 'r+b') as f:
            f.seek(0, 2)
            items = [('pack.json', None, 'file', ALIGN_ROMFS, None), ('icon.png', folder / 'icon.png', 'file', ALIGN, None), ('icon@4x.png', icon4x, 'file', ALIGN, None),
                     ('extract.aar', extract, 'archive', ALIGN, '')]
            items += [(f'{d}.aar', src, 'archive', ALIGN, d) for src, d in shaders]
            for name, src, kind, align, into in items:
                if src is not None and not src.is_file(): continue
                f.write(b'\0' * (-f.tell() % align)); off = f.tell(); h = hashlib.sha256()
                if src is None: f.write(meta); h.update(meta)
                else:
                    with open(src, 'rb') as i:
                        while b := i.read(8 << 20): f.write(b); h.update(b)
                members.append({'name': name, 'offset': off, 'size': f.tell() - off, 'kind': kind, 'sha256': h.hexdigest(), **({'folder': into} if into is not None else {})})
            f.write(b'\0' * (-f.tell() % ALIGN)); toc_off = f.tell()
        step('checksum')
        sums = chunk_sums(part, toc_off, Path(romfs_source or romfs), size, full)
        toc = (json.dumps({'format': 3, 'members': members, 'chunk': CHUNK, 'sha256': sums}, ensure_ascii=False) + '\n').encode()
        with open(part, 'r+b') as f:
            f.seek(toc_off); f.write(toc)
            total = f.tell() + TRAILER
            t = MAGIC + struct.pack('<II QQQ', 3, 0, total, toc_off, len(toc)) + hashlib.sha256(toc).digest()
            f.write(t + b'\0' * (TRAILER - len(t) - len(MAGIC)) + MAGIC)
        if out.is_dir(): discard(out)   # the game's pack folder from before (formats 1 and 2), replaced by the file; deleted in the background
        else: out.unlink(missing_ok=True)
        part.rename(out)
    finally:
        if stage.exists(): shutil.rmtree(stage)
        for m in made: m.unlink(missing_ok=True)
        part.unlink(missing_ok=True)


def cached_sums(romfs, whole):
    """The image's kept checksums (<image>.chunks.json) when they were made for it as it is now (its size and modification time: nanoseconds as this script writes
    them, microseconds as nx_extract does), else []"""
    cache = romfs.with_name(romfs.name + '.chunks.json'); st = romfs.stat()
    try: c = json.loads(cache.read_text())
    except (OSError, ValueError): return []
    k = c.get('key') or {}
    same = k.get('size') == st.st_size and k.get('chunk') == CHUNK and (k.get('mtime_ns') == st.st_mtime_ns or k.get('mtime_us') == st.st_mtime_ns // 1000)
    return c['sha256'][:whole] if same and len(c.get('sha256', [])) >= whole else []


def chunk_sums(path, end, romfs=None, romfs_size=0, full=False):
    """SHA-256 of each CHUNK bytes of the file's first `end` bytes. The chunks wholly inside the RomFS image (the start of the file) come from its kept checksums; without
    them they are null, or with `full` worked out and kept for the next time. The rest (the pack's other members, small) are read. The file is read front to back by one
    reader (a USB drive reads far slower when several readers seek around it) while the chunks already read are hashed on other threads"""
    n = (end + CHUNK - 1) // CHUNK; t0 = time.time()
    whole = romfs_size // CHUNK   # chunks with nothing but the image in them
    out = cached_sums(romfs, whole) if romfs else []
    if not out and not full: out = [None] * whole
    with open(path, 'rb', buffering=0) as f, concurrent.futures.ThreadPoolExecutor(max_workers=min(4, os.cpu_count() or 2)) as ex:
        pending = []
        f.seek(len(out) * CHUNK)
        for i in range(len(out), n):
            b = f.read(min(CHUNK, end - i * CHUNK))
            if len(b) != min(CHUNK, end - i * CHUNK): raise OSError(f'{path}: ends early')
            pending.append(ex.submit(lambda b: hashlib.sha256(b).hexdigest(), b))
            while len(pending) > 4 or (i == n - 1 and pending): out.append(pending.pop(0).result())
            P.progress(i + 1, n, t0)
    if romfs and whole and None not in out[:whole]:
        st = romfs.stat()
        try: romfs.with_name(romfs.name + '.chunks.json').write_text(json.dumps({'key': {'size': st.st_size, 'mtime_ns': st.st_mtime_ns, 'chunk': CHUNK}, 'sha256': out[:whole]}) + '\n')
        except OSError: pass
    return out


def env_file(path):   # Gen/resources.env: KEY=VALUE lines, values possibly quoted
    out = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1); out[k] = v.strip().strip("'\"")
    return out


def clone(src, dst):   # cp -c: an APFS clone on the same volume, else a plain copy
    dst.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(['cp', '-cR', str(src), str(dst)], capture_output=True).returncode:
        if src.is_dir(): shutil.copytree(src, dst, symlinks=True)
        else: shutil.copy2(src, dst)


def signing_identity(team):
    """The SHA-1 of a valid Apple Development identity of this team (its certificate's OU), or None"""
    out = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout
    for sha, name in re.findall(r'\)\s+([0-9A-F]{40})\s+"(Apple Development:[^"]*)"', out):
        pem = subprocess.run(['security', 'find-certificate', '-c', name, '-p'], capture_output=True, text=True).stdout
        subj = subprocess.run(['openssl', 'x509', '-noout', '-subject'], input=pem, capture_output=True, text=True).stdout
        if f'OU={team}' in subj.replace(' = ', '='): return sha
    return None


def prepare_project(xcode, work, team, bundle_id):
    """The pack's Xcode project: this checkout's Sources and tools, the game's Gen/ with its source links and header paths moved to this checkout"""
    gen_src = xcode / 'Gen'
    old_ios = (xcode / 'Sources').resolve().parent   # the checkout that prepared the game (<repo>/dm/ios)
    old_dm = old_ios.parent
    proj = work / 'project'
    if proj.exists(): shutil.rmtree(proj)
    gen = proj / 'Gen'; gen.mkdir(parents=True)
    for name in ('Sources', 'tools'): (proj / name).symlink_to(IOS / name, target_is_directory=True)
    shutil.copy(IOS / 'pack.yml', proj / 'pack.yml')
    for item in gen_src.iterdir():
        if item.name in ('src', 'main', 'dm.xcconfig'): continue
        (shutil.copytree(item, gen / item.name, symlinks=True) if item.is_dir() else shutil.copy2(item, gen / item.name))
    # Source links: the same files in this checkout (the file list is the Makefile's; a source this checkout lacks stops here)
    for sub in ('src', 'main'):
        (gen / sub).mkdir()
        for link in (gen_src / sub).iterdir():
            target = Path(os.readlink(link))
            mine = DM / target.relative_to(old_dm) if target.is_relative_to(old_dm) else target
            if not mine.exists(): sys.exit(f'{mine}: not in this checkout (prepare the game from this checkout: build_ipa_from_nsp.py --prepare-xcode)')
            (gen / sub / link.name).symlink_to(mine)
    # Header paths: this checkout's, but the game profile header the prepare step generated (its profile may be a derived one outside the repository)
    profile = gen / 'profile'; profile.mkdir()
    cfg = (gen_src / 'dm.xcconfig').read_text()
    m = re.search(r'"([^"]*/dm/host/gen/[0-9A-Fa-f]{16})"', cfg)
    if not m or not (Path(m.group(1)) / 'game_profile.h').is_file(): sys.exit(f'{gen_src}/dm.xcconfig: no game profile header path')
    shutil.copy(Path(m.group(1)) / 'game_profile.h', profile / 'game_profile.h')
    cfg = cfg.replace(f'"{m.group(1)}"', f'"{profile}"').replace(f'{old_dm}/', f'{DM}/')
    cfg = re.sub(r'^DM_XCODE_OUTPUT_ROOT = .*$', f'DM_XCODE_OUTPUT_ROOT = {work / "dd"}', cfg, flags=re.M)
    (gen / 'dm.xcconfig').write_text(cfg)
    env = dict(os.environ, DM_BUNDLE_ID=bundle_id, DM_TEAM_ID=team)
    subprocess.run(['xcodegen', 'generate', '--spec', 'pack.yml', '--quiet'], cwd=proj, check=True, env=env)
    return proj


def commit():   # this checkout's commit, which the library was built from
    r = subprocess.run(['git', '-C', str(DM), 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ''


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--xcode', type=Path, help="the game's prepared Xcode project directory (<NSP folder>/<id>_build/xcode)")
    ap.add_argument('--output', required=True, type=Path, help='the pack to write, <dir>/<name>.nxpack (replaced when it exists)')
    ap.add_argument('--team', help="the development team that signs the library: NX Pocket's own (default: the game project's)")
    ap.add_argument('--identity', help="the signing identity (default: the keychain's Apple Development certificate of the team)")
    ap.add_argument('--format', type=int, choices=(1, 2, 3), default=FORMAT, help='2 (default): the shader libraries as one archive; 1: as a folder; 3: the whole pack as one file')
    ap.add_argument('--convert', type=Path, help='a pack folder already made (format 1 or 2): write it as one file (format 3) at --output, building nothing')
    ap.add_argument('--unsigned', action='store_true', help='sign the library ad hoc only: NX Pocket signs it on the phone')
    ap.add_argument('--work', type=Path, help='the pack project and its build products (default: <xcode>/../pack)')
    ap.add_argument('--progress', choices=('text', 'json'), default='text', help="json: the stages as JSON events, one per line (for NX Pocket for Mac)")
    ap.add_argument('--verify', choices=('quick', 'full'), default='quick', help="format 3: full puts every part's checksum in the pack, reading the game files when their checksums were not kept (minutes on a USB drive); quick (default) the small parts' always, the game files' when kept: NX Pocket then checks them fully only when all are there")
    a = ap.parse_args()
    if a.output.suffix != '.nxpack': sys.exit(f'{a.output}: a pack is named <name>.nxpack')
    if a.convert:
        P.json = a.progress == 'json'; P.n = 2
        if not (a.convert / 'pack.json').is_file(): sys.exit(f'{a.convert}: not a pack folder (no pack.json)')
        single_file(a.convert.resolve(), a.output.resolve(), full=a.verify == 'full'); P.end(); print(f'pack: {a.output.resolve()}'); return
    if not a.xcode: sys.exit('--xcode is needed (or --convert)')
    P.json = a.progress == 'json'; P.n = 4 + (a.format >= 2) + 2 * (a.format == 3)
    xcode = a.xcode.resolve(); gen_src = xcode / 'Gen'
    for f in ('Info.plist', 'resources.env', 'embed.S', 'dm/launcher.json', 'dm.xcconfig'):
        if not (gen_src / f).exists(): sys.exit(f'{gen_src / f}: not found (prepare the game first: build_ipa_from_nsp.py --prepare-xcode)')
    info = plistlib.loads((gen_src / 'Info.plist').read_bytes())
    res = env_file(gen_src / 'resources.env')
    settings = json.loads((gen_src / 'dm/launcher.json').read_text())
    title = settings.get('game') or res.get('DM_RESOURCE_TITLE')
    if not title: sys.exit('no title ID (launcher.json game, resources.env DM_RESOURCE_TITLE)')
    team = a.team
    if not team:
        m = re.search(r'DEVELOPMENT_TEAM = (\w+);', next(xcode.glob('*.xcodeproj')).joinpath('project.pbxproj').read_text())
        team = m.group(1) if m else None
    if not team or team == '0000000000':
        if not a.unsigned: sys.exit('no development team: pass --team (the team NX Pocket is signed with), or --unsigned')
        team = ''

    # The shader libraries are one chain's; the host is compiled from this checkout and loads only msl/b-<its chain> (stage_resources.sh checks the same)
    msldir = res['DM_RESOURCE_MSLDIR']
    if msldir.startswith('b-'):
        chain = re.search(r'#define DMSH_CHAIN "(.*)"', (DM / 'gfx/nvn/dmsh_chain.h').read_text()).group(1)
        if msldir != f'b-{chain}': sys.exit(f'the prepared shaders are chain {msldir}, this checkout is at b-{chain}: prepare the game again (build_ipa_from_nsp.py --prepare-xcode)')
    for k in ('DM_RESOURCE_ROMFS', 'DM_RESOURCE_SHADERS'):
        if not Path(res[k]).exists(): sys.exit(f'{res[k]}: not found ({k}; is the drive connected?)')

    work = (a.work or xcode.parent / 'pack').resolve(); work.mkdir(parents=True, exist_ok=True)
    step('library project')
    proj = prepare_project(xcode, work, team, f'org.nxnative.pack.{title.lower()}')
    step('library build')
    log = work / 'build.log'
    with open(log, 'w') as f:
        r = subprocess.run(['xcodebuild', '-project', 'GamePack.xcodeproj', '-target', 'Game', '-configuration', 'Release', '-sdk', 'iphoneos',
                            '-allowProvisioningUpdates', f'DEVELOPMENT_TEAM={team}', 'build'], cwd=proj, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        tail = log.read_text().splitlines()
        P.fail('library build failed:\n' + '\n'.join([l for l in tail if 'error:' in l][:20] or tail[-30:]) + f'\n(full log: {log})')
    fw = work / 'dd/Build/Products/Release-iphoneos/Game.framework'
    # Xcode signs a framework only when an app embeds it; the pack's library is signed here with the team's development certificate
    ident = '-' if a.unsigned else a.identity or signing_identity(team)
    if not ident: P.fail(f'no Apple Development certificate of team {team} in the keychain (pass --identity, or --unsigned)')
    step('sign', '' if a.unsigned else ident)
    subprocess.run(['codesign', '--force', '--sign', ident, '--timestamp=none', str(fw)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(fw)], check=True)

    step('pack')
    final = a.output.resolve()
    out = final if a.format < 3 else final.with_name('.' + final.stem + '.folder.nxpack')   # format 3: a format 2 folder first (a few hundred files), then the one file made of it
    part = out.with_name(out.name + '.partial')
    if part.exists(): shutil.rmtree(part)
    part.mkdir(parents=True)
    subprocess.run(['ditto', str(fw), str(part / 'Game.framework')], check=True)   # keeps the signature as it is
    shutil.copytree(gen_src / 'dm', part / 'dm')
    romfs = Path(res['DM_RESOURCE_ROMFS'])
    clone(romfs, part / ('romfs.img' if romfs.is_file() else 'romfs'))
    archives = []
    if a.format >= 2:   # msl/<chain>/ as one archive, its root msl/'s contents (NX Pocket unpacks it into msl/), straight from the build's shader folder
        step('shader archive')
        msl_archive(Path(res['DM_RESOURCE_SHADERS']), msldir, part / 'msl.aar')
        archives.append({'file': 'msl.aar', 'folder': 'msl'})
    else:
        sh = Path(res['DM_RESOURCE_SHADERS']); clone(sh, part / 'msl' / (f'{msldir}.img' if sh.is_file() else msldir))
    if res.get('DM_RESOURCE_AOC'): clone(Path(res['DM_RESOURCE_AOC']), part / 'aoc')
    if res.get('DM_RESOURCE_PSO'): clone(Path(res['DM_RESOURCE_PSO']), part / 'pso')
    # the icon: the game's own (its control data's 256×256, saved by the extraction beside the game files) as it is, and icon@4x.png, 1024×1024, made from it on this
    # Mac for the screens that show it large (upscale_icon.swift: MetalFX); the app icon's 1024 (a plain resize of the same 256) when the original is not there
    own = Path(res['DM_RESOURCE_ROMFS']).parent / 'icon.jpg'
    icon = own if own.is_file() else gen_src / 'Assets.xcassets/AppIcon.appiconset/icon.png'
    if icon.is_file():
        subprocess.run(['sips', '-s', 'format', 'png', *([] if icon == own else ['-Z', '512']), str(icon), '--out', str(part / 'icon.png')], check=True, stdout=subprocess.DEVNULL)
        upscale_icon(icon, part / 'icon@4x.png')
    pack = {
        'format': min(a.format, 2), 'titleID': title, 'name': info.get('CFBundleDisplayName') or title,
        'version': res.get('DM_RESOURCE_VERSION', ''), 'build': res.get('DM_RESOURCE_BUILD', ''),
        'language': info.get('DMLanguage', 'en-US'), 'showFPS': info.get('DMShowFPS') == 'YES',
        'shaders': msldir, 'library': 'Game.framework/Game', **({'archives': archives} if archives else {}), 'team': None if a.unsigned else team, 'commit': commit(),
        'romfsInPack': True,   # its host reads the game files from a single-file pack (DM_ROMFS_SIZE): --convert makes format 3 only of such a pack
    }
    (part / 'pack.json').write_text(json.dumps(pack, indent=2, ensure_ascii=False) + '\n')
    if out.is_dir(): discard(out)   # the pack from before (deleted in the background)
    part.rename(out)
    if a.format == 3:
        try: single_file(out, final, romfs, full=a.verify == 'full')
        finally: shutil.rmtree(out, ignore_errors=True)   # a format 2 folder: a few hundred files
    P.end()
    print(f'pack: {final}')


if __name__ == '__main__':
    main()
