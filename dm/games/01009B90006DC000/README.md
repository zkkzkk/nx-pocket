# Super Mario Maker 2 (`01009B90006DC000`)

Update 3.0.3 (v458752) over the base game; Nintendo sead / agl / gsys on SDK 7.3.2 and NVN. Main build `c2dc405ac414c37c8b1c50219c7a0f0c`, SDK build `fcf93a41b08c5193a1410d262602dc62`. Only these update modules have been surveyed and rewritten; the base game alone is untested.

## What it needs

- `op_mode handheld`: exposes the touchscreen for course editing on the phone.
- `pad_layout full`: all buttons, D-pad and both sticks remain available. The layout selector also offers the simple and touch layouts.
- Conditional rendering: the game records it during boot; the host evaluates every game's conditions at replay ([Conditional rendering evaluated at replay](../../../docs/reference/rendering.md#conditional-rendering-evaluated-at-replay); until 2026-11-12 the profile key `render_cond`).
- The NPDM declares no system resource. The 4 GB guest layout and pool follow the static heap calculation. Boot sets a 3.14 GB heap; the Mac title/editor run used about 1.5–1.9 GiB resident.
- Modules `main sdk`; RomFS marker `Pack/QuestModel.pack`.

## Files and shaders

The RomFS has 3,801 files: Yaz0 archives, zstd-compressed models, SARC packs, BNSH / BAHS shader containers and BWAV audio. The complete split yields 10,561 shaders: 4,112 vertex, 6,439 pixel, nine compute and one geometry; 6,375 variation pairs. All 429 loose model files decode after the image-input fix below. Traversing zstd members inside SARC packs adds a further 3,920 shader variants; all 80 keys captured missing in the title route are now in the map.

## Local Duo integration (2026-10-27)

Based on upstream `75065df` in an isolated checkout, preserving the original nxnative checkout's existing changes. Reuses the user's HalfoldKit front end: portrait upper picture and lower controls, hinge-aware tabletop mode, outer-screen layout, floating stick, per-posture control editor, and gravity-based upside-down correction. Fit is the default; stretch and center crop are available. Upstream MetalFX remains opt-in.

Only actual picture pixels can start game touchscreen input; unused lower-screen space and letterboxes cannot paint the editor's bottom edge. Portrait picture touches take priority over the lower controls' grab regions.

Validation: HalfoldKit 52 checks; present/crop GPU regression 98 checks; iOS compile check 178 files; launcher storage one test; the complete Python tool suite, 350 tests with 16 environment-dependent skips. All executed checks pass. The iPhone Release target compiles and links unsigned with Xcode 27.1, including `hf_kit.c`, and advertises both portrait orientations. At the user's explicit request, the verified test package was development-signed, installed on the wired physical iPhone Duo (iOS 27.1), and launched successfully on 2026-10-27. This confirms installation and launch only; iPhone gameplay and folding are still unverified.

The unsigned development artifact `SuperMarioMaker2-Duo-test.ipa` is 3,065,784,189 bytes (2.86 GiB), with 26,694 ZIP entries and 10,561 iOS shader libraries. A full ZIP CRC check passes; the package contains the handheld Chinese-language profile, the portrait orientation declarations and the prewarm seed, with no signing files. SHA-256: `9869e38e37762ce60e8699266e72802398022ed113e6bb0aeedb432c9e19bcf4`. The prepared project is registered in the existing shared Xcode workspace.

The required local `scripts/regress.py check --baseline HEAD --candidate worktree --quick --no-smoke` static comparison passes: 10,561/10,561 shaders in both revisions, no newly failing shaders or changed MSL. It uses the new title's same extracted packages/profile for both revisions; there is no upstream playable baseline for this title. This result checks the shared translation chain, not gameplay stability.

## Mac validation (2026-10-27, incomplete)

The title, Chinese creation/play menu, editor and tutorial prompts render. Touch dismisses the prompts, selects items, places question blocks and drags/resizes a pipe. Super Mario World course play accepts movement; switching the editor to Super Mario 3D World loads the models, background, water and editor controls, and its course play accepts movement/jump input. A non-probed `DM_PSO_MTL4=0 DM_PSO_PREBUILD=0` session reached these scenes and ran for about six minutes. This tests the pipeline path used by default on iOS. The bundled prewarm list contains 771 distinct records from these routes.

**Status: experimental, stability not established.** Several ordinary Mac starts remain black after the loading animation or crash in the title's 3D scene. A diagnostic run reached the editor and lasted ten minutes, but probes change timing and do not establish a fix. Metal 4 runs faulted at `main+0x25f4f0` (NULL shape), `mtl_exec+0x150` (invalid recorded handle), or through a stale stack command-buffer context (`main+0x2ef50c`, callback `0x14`). The non-probed Metal 3 session later faulted at `main+0x59d3a0`, constructing an object at a code address on a UI job thread. Therefore this is not proven to be specific to Metal 4. The bad writer/lifetime boundary has not been identified; no timing delay, feature-disable profile rule or guest cut is applied to hide it. `DM_PREEMPT=1` also reproduced a crash and is not a fix.

The reproducible Mac route uses the handheld profile, `DM_ROMFS=<build>/extract/v458752/RomFS.img`, the build's font and shader-cache folders, and its patched update modules. Wait for the full title before L+R, then A for Create. Touch the displayed dialog buttons, the style selector at the upper left and the play/create button at the lower left. In the editor, the most recently selected palette items move to the right, so their coordinates are not stable across selections. Leave a release interval between scripted taps. The saved Mac diagnostic logs and screenshots are in the NSP folder's `01009B90006DC000-work/`, outside this checkout.

## OCW phone candidate (2026-10-27)

The user requested direct community Course World access and supplied the official OCW 0.3 mod and personal config. The native adaptation uses that config as private `Documents/ocw-config.json`, separate from the save and from repository/package resources. The mod targets this exact main build. It replaces Nintendo account/token requirements and applies OCW's community course-validation/profanity policy. The HTTP header gate and transport are described in [Opt-in Open Course World transport](../../../docs/reference/services.md#opt-in-open-course-world-transport).

The prior six-course offline import was rejected as damaged by the game on the user's phone. File integrity checks did not establish game compatibility. Further imports are stopped; no new import or save replacement is part of this candidate. It preserves the existing save. All new checks on the computer are standalone interface/static/build checks; the user explicitly requested no further computer gameplay tests.

The final candidate builds successfully for physical iOS, passes the OCW standalone checks (including verified TLS/HTTP), loader symbol/NRO tests, 350 Python tool tests with 16 skips, and the 10,561-shader static comparison without new failures or changed MSL. A fresh Clang/Swift module cache avoids the reproduced Xcode build-service crash on incremental compilation. At the user's explicit request it was development-signed, installed on the wired iPhone Duo, and launched. Read-back verifies the personal config, all 17 save files match the pre-install backup byte-for-byte, and the phone startup log confirms `OCW 0.3 enabled`. No computer gameplay was run. Authenticated Course World navigation/download/play remains for the user's phone test.

The phone log's previous session ends at frame 1248 with SIGSEGV in `mtl_exec` immediately after lending its first 256 KB command segment. The candidate also contains the independently reproduced [overlapping grant lifetime fix](../../../docs/reference/nvn-objects.md#command-memory-grants-overlap-live-neighboring-recordings). The precise writer behind that phone crash and the other object-lifetime failures remain unverified.

## OCW follow-up after the first phone attempt

The user reported no response to the Course World button. The 374-line phone log confirms the OCW configuration was loaded, but contains no DNS, socket or TLS activity. Static inspection finds a definite ABI error in the first candidate: SDK `+0x319790` returns the boolean from `NetworkConnection::HandleNetworkRequestErrorResult`, masking w0 with one, and main `+0x60e7c4` stores that bit at manager `+0xdc`. The OCW binding incorrectly returned Result success (zero). [Network request confirmation returns a boolean](../../../docs/reference/services.md#network-request-confirmation-returns-a-boolean) records the correction. This is a verified binding error; the failed button's full path still needs runtime verification.

The user subsequently authorized local gameplay testing to reduce phone iterations, superseding the earlier no-computer-gameplay request. Local attempts reached the title/menu but still reproduced invalid command replay pointers while switching scenes. These crashes remain a separate obstacle to online validation; they are not evidence that the OCW server rejected authentication.

The follow-up also verifies [wholly host-backed recording lifetime](../../../docs/reference/nvn-objects.md#a-wholly-host-backed-recording-has-no-guest-origin). The expanded NVN suite passes 165 checks; restoring the previous origin rule fails two of the new checks. This does not resolve the independently observed null cached scope and invalid replay pointer crashes.

The stock OCW mod makes `IsNetworkServiceAccountAvailable` return Result success without writing its boolean output. This host has no linked Nintendo account to supply the surrounding state. The native OCW overlay now writes true for its community identity instead, with Result success, and removes that no-op PLT cut. An import-binding regression verifies both the status and output value. Runtime entry behavior is still under investigation.

## Course World working on the Mac (2026-10-28)

Course World now opens, lists and plays community courses on the Mac with the user's OCW account. Three host fixes were needed, in this order:

- The online login stopped silently at its parental-control check: the offline `pctl::CheckFreeCommunicationPermission` answers "never", and `State::cCheckParentalControl` (`main+0x15320e4`) returns to idle before any network call. Next, `main+0xd44c8` formats `https://%s/` from `nsd::ResolveEx`'s output without checking its Result. The OCW overlay answers both ([Online login stops at the parental-control check](../../../docs/reference/services.md#online-login-stops-at-the-parental-control-check)).
- Entering Course World registers the player's Mii mask texture, which the host's Mii stand-in never built (no hat texture): every stand-in texture part is now a blank 16 × 16 image ([System data stand-in for the MiiModel archive](../../../docs/reference/services.md#system-data-stand-in-for-the-miimodel-archive)).
- Scene changes crashed in render jobs, ui2d and command replay at nearly every change: `core_lock all` runs one guest thread at a time ([One guest thread at a time](../../../docs/reference/threads.md#one-guest-thread-at-a-time-core_lock)), which also exposed and fixed an `NvPkg` texture lookup.

Scripted sessions (boot, Course World, two downloaded courses played and left, Story Mode, back): 9 of 9 clean with the final host, 3 of them with the phone's Metal 4 and encoder-thread settings. The iPhone Duo candidate built from these sources is installed; it has not been launched there yet.

## Found on this game

- [Zstd shader files inside a RomFS image](../../../docs/reference/shaders.md#zstd-shader-files-inside-a-romfs-image).
- [Zstd members inside SARC archives](../../../docs/reference/shaders.md#zstd-members-inside-sarc-archives). Runtime keys including `07d46d66eab6e24f` and `92195dc2f6398221` are stored in `3W_Model.pack` members (`3W_Player_KinopioMini.Nin_NX_NVN.zs` and `3W_Object_jumpstep.Nin_NX_NVN.zs`, respectively), inside their `Block_UBER.Nin_NX_NVN.bfsha`. The old scan missed these compressed members; similar loose model shaders have different control hashes and are distinct programs.
- [An archive inside a compressed member is not overlap](../../../docs/reference/shaders.md#an-archive-inside-a-compressed-member-is-not-overlap). Six layout packs (`Pack/Layout*.pack`) were left out of the split by the nesting budget until it stopped counting each level again.
- [Game touches confined to the visible picture](../../../docs/reference/services.md#game-touches-confined-to-the-visible-picture).
- [Missing private-use symbols in the shared-font stand-in](../../../docs/reference/services.md#missing-private-use-symbols-in-the-shared-font-stand-in). Font loads report no error; U+E06B fails `CheckGlyphExist` on both eligible faces, then the glyph cache returns NULL. The generated replacement passes this boot failure; unsupported symbols retain a visible placeholder.

## Open

- Validate the `core_lock all` build on the Duo (boot, Course World, course play, editor); the Mac sessions do not cover the editor or long play.
- Verify explicit course save/reload and sustained play after that fix.
- Validate audio output beyond the non-silent renderer counters seen during the Mac title run.
- The unsigned Duo test IPA and prepared Xcode project are development artifacts; phone gameplay stability is unverified.
- User validation on the Duo: folding, outer screen, upside-down handling, multitouch editing and controls.
- OCW Course World browsing, downloading and play work on the Mac; phone validation is pending.
- Mii heads use the existing host stand-in; unsupported system-font symbols use a visible replacement.
