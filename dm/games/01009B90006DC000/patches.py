# Open Course World 0.3 client adaptation, based on opencourseworld/ocw-mod.
# Exact SMM2 3.0.3 build only. Networking remains opt-in through private ocw-config.json.
CUTS = {
    "c2dc405ac414c37c8b1c50219c7a0f0c": [
        (0x1cb7620, "306a0090116245f910022b9120021fd6", "c85f99d2080000f900008052c0035fd6", "OCW account ID 0xCAFE; identity is authenticated by OCW token"),
        (0x1cb75f0, "306a0090115645f9", "00008052c0035fd6", "OCW token cache is replaced by WebSocket authentication"),
        (0x1cb75a0, "306a0090114245f9", "00008052c0035fd6", "OCW token cache init is replaced by WebSocket authentication"),
        (0x2f43c, "61207294e07b00b9", "0000805205000014", "OCW skip Nintendo token cache wait"),
        (0x2f538, "36207294", "1f2003d5", "OCW skip unused Nintendo token context destruction"),
        (0x60e794, "3bae5a94", "00008052", "OCW skip Nintendo service account requirement"),
        (0xfcab10, "ffc303d1ea3b00fd", "00008052c0035fd6", "OCW mod course validation policy; community server data differs from Nintendo ownership"),
        (0x17b8020, "ff8306d1fc6f14a9", "20008052c0035fd6", "OCW uses community moderation instead of Nintendo profanity service"),
    ],
}
OBS = {
    "c2dc405ac414c37c8b1c50219c7a0f0c": [
        (0xaf564, 27, "911583e0", "OCW: replace the completed WebSocket header in guest memory; registers unchanged"),
    ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'Open Course World 0.3: account, token and moderation cuts and the WebSocket header gate', 'now': 'build', 'goal': 'build', 'purpose': 'runtime',
     'checked': 'Course World on the Mac with 3.0.3 (2026-10-29)',
     'why': "the community server's client adaptation (opencourseworld/ocw-mod) targets exactly this build"},
]
