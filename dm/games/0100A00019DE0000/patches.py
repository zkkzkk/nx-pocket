# Hades II (0100A00019DE0000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS as described there ("Registered patches")
CUTS = {
  # Hades II 1.0.137848 (v589824) main: draw 1920x1080. Right after nn::vi::CreateLayer (main+0x2a604c) the window setup writes a fixed 1280x720, in both operation modes, into
  # the window object (+0x8) and the swap chain description (+0x10 of [this+0x28]); nvnWindowInitialize then gets three 1280x720 window textures. The engine sizes its render targets
  # from it and lays its UI out in 1920x1080 units scaled by the screen size (main+0x2abfbc: 1/1920 and 1/1080), so a 1920x1080 window draws every pass and the UI at full size
  # (title, opening and Erebus checked on the Mac). GetOperationMode (main+0x28dc64) and the operation mode notification do not change the size
  '8ce1ac48e9fa74479051f3520e632df4': [
    (0x2a6080, '08a080d2085ac0f2', '08f080d20887c0f2', 'window size 1280x720 → 1920x1080: mov x8,#0x500; movk x8,#0x2d0,lsl #32 → mov x8,#0x780; movk x8,#0x438,lsl #32'),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'window size 1280x720 → 1920x1080', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'checked': 'title, opening and Erebus on the Mac, 1.0.137848 (Halfold, 2026-10-26)',
     'why': "the game's own window setup writes a fixed 1280x720; a function-matched rule could carry it over the game's updates"},
]
