# Mario Tennis Aces (`0100BDE00862A000`)

Update 3.1.1 (v851968) over the base game, SDK 4.5.0, NVN. Camelot's engine with NintendoWare (G3d, Ui2d, Vfx, Atk, Font) and NEX / Pia networking. Modules `main`, `subsdk0` (the SDK's movie library: the WebM / VP9 movies) and `sdk`. RomFS is mostly Camelot's NARC archives, which the game reads itself.

Brought up on the Mac from 3.1.1: the title, the opening movies (VP9 with subtitles), the start of Adventure, the main menu and a Free Play singles match (Quick Play, Mario against a random COM, a random Marina Stadium court) to its end screen. Not yet tested on the iPhone. Online play is not looked at.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | no virtual address memory: the game sets a 3.14 GB heap in the 3.25 GB heap region |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `modules main subsdk0 sdk` | `game.tsv` | every module `main` imports from |

No patches; everything it needed is general host or tool behaviour (below).

## Bring-up

- **Resolved: crash at address 0x38 at `main+0x599e14` right after `nnMain`.** The glyph lookup for "?" found no font: the game loads the shared standard font into a 512 KB glyph engine and into 50 KB per-thread engines (`main+0x59b0a0`, `main+0x59b0f8`), and the stand-in font did not fit in 50 KB (`LoadFont` error 201): [Font engine heap sized for the console's own shared font](../../../docs/reference/services.md#font-engine-heap-sized-for-the-consoles-own-shared-font).
- **Resolved: a call through a null pointer in the host's `movie::Decoder::Configure` at the first movie.** `main` imports only SDK 4's base-object constructor: [The base-object `movie::Decoder` constructors](../../../docs/reference/movies.md#the-base-object-moviedecoder-constructors).
- **Resolved: abort in the game's allocator (`main+0x62aac`) as a court loads.** About 7,400 per-object command buffers sized by `GetCommandMemoryUsed` in a 16 MB command pool (`main+0x96824`; the pool is set up at `main+0x8760`, flags 0x12): [Per-object command buffers sized by the count](../../../docs/reference/nvn-objects.md#per-object-command-buffers-sized-by-the-count). Now 14.95 MB at the peak on Marina Stadium; other courts are not measured.
- **Resolved: 1,388 shaders found, most draws missing from the map.** Models and effects keep their BNSH in packed NARC members: [Camelot's NARC archives and their packed members](../../../docs/reference/shaders.md#camelots-narc-archives-and-their-packed-members). 21,703 shaders now.
- **Resolved: matches and the Adventure map showed only the HUD.** Two causes, one after the other: [`CopyCommands` copies the commands](../../../docs/reference/nvn-objects.md#copycommands-copies-the-commands) (the court and players were missing from the G-buffer) and [sRGB and linear texture objects on one storage](../../../docs/reference/rendering.md#srgb-and-linear-texture-objects-on-one-storage) (the tone-mapped picture never reached the window).

## Input

- Menu cursors move on the D-pad; a press of 0.15 s registers once, 0.35 s can repeat.
- Pause in a match is Plus; the pause menu leads back to the main menu.

## Local play

- `local_play lan` (hle_ldn.c, hle_sock.c). Checked on the Mac (2026-10-31) with two instances, one on `lo0` and one on `en0`, unicast only as on an iPhone (the work folder's `run/lan_pair.sh`, `run/lan_to_room.sh`): Free Play → Local Play → Solo; the host creates a room (Plus), the other updates the list (Y) and joins (A); both pick a character and a court, and a Quick Play match ran to its result screen (Mac-B 1 win, Mac-A 1 loss) and into a second match, with no disconnect.
- When the host presses Start, every player has to press A (OK) within the countdown under the player list. A player who has not is taken out of the room when it runs out: its room screen returns -1 (`main+0x1a5700`) and the game leaves the Pia session and the ldn network (`main+0x1600a0` queues the scene, `main+0x217a50`). This is the game's own rule, not a disconnect.
- Two consoles each need their own player name (`DM_NICK`) and device ID (`DM_DEVICE_ID` on one Mac); the same save copied to both instances works.

- **Resolved: a station that had been in a room whose host went away aborted when it created its own room** (iPhone, reproduced on the Mac): [`ldn::AttachStateChangeEvent` initializes its event each time](../../../docs/reference/services.md#ldnattachstatechangeevent-initializes-its-event-each-time).
- **Resolved: the host crashed in `vpt_walk` as it started a match 893 s into a session** (iPhone): [A pool's sparse record checked against the live ones](../../../docs/reference/nvn-objects.md#a-pools-sparse-record-checked-against-the-live-ones).

## Mac routes

- From a fresh save, L+R at the title (about frame 2,400) starts three opening movies (about 3.5 minutes, not skippable) and the first Adventure dialogue (A); the Adventure pause menu (Plus) → Main Menu → Yes reaches the main menu and saves.
- From that save, L+R at the title goes straight to the main menu. Free Play is the fourth entry (three times Down), then A for Single-Console Play, A for Select Character (Change Rules → Play Time → Quick Play for a short match), A for Mario, A for a random COM, A for a random stadium, A to start and A at the tips screen. The work folder's `run/to_match.sh` does this through `DM_CTL`.

## Checks

- 2026-10-31, the host changes against other local Mac builds: baseline d3f7433 and this branch, the same build folders, 60-115 s boots without and with presses. Super Smash Bros. Ultimate, Hades II and Rhythm Heaven Groove: no crash, the same presented frames and the same set of `[RED]` lines on both sides; Rhythm Heaven Groove's screenshots match. Smash and Hades II stay black on both sides, as those builds miss some of their Mac shader libraries, so their pictures are not compared. `scripts/regress.py` was not run to the end (it translates every game's shaders again first).

## Found on this game

- [Font engine heap sized for the console's own shared font](../../../docs/reference/services.md#font-engine-heap-sized-for-the-consoles-own-shared-font) (`hle_sdk16.c`).
- [The base-object `movie::Decoder` constructors](../../../docs/reference/movies.md#the-base-object-moviedecoder-constructors) (`hle_movie.c`).
- [Per-object command buffers sized by the count](../../../docs/reference/nvn-objects.md#per-object-command-buffers-sized-by-the-count) and [`CopyCommands` copies the commands](../../../docs/reference/nvn-objects.md#copycommands-copies-the-commands) (`hle_nvn.c`).
- [Camelot's NARC archives and their packed members](../../../docs/reference/shaders.md#camelots-narc-archives-and-their-packed-members) (`shader_split.py`).
- [sRGB and linear texture objects on one storage](../../../docs/reference/rendering.md#srgb-and-linear-texture-objects-on-one-storage) (`nvn_mtl.m`).

## Open

- 122 shaders fail Metal compilation: their translation writes `ViewportMaskNV` (`gl_BuiltIn_5253`) outside the geometry reader that `dmsh_geometry.reader` lowers. Which draws use them is not checked; a fix is a chain change.
- The pipeline prebuild stopped once with a crash inside Metal's binary cache (`MultiLevelAirntBinaryCache::getElementAtDestination`, 26,000 of 27,659 pairs); the game builds the rest at draw time.
- The character select shows no 3D character models (the left and right panels draw only their backgrounds). Not traced.
- The command pool peaks 1 MB under its 16 MB on Marina Stadium; courts with more objects may need the render-target record compacted too.
- `[RED] geometry draw cannot capture this pipeline` (thousands of lines in a match, one geometry shader with tessellation). Not traced.
- iOS: not built.
