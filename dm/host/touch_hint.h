// Touch hints: which buttons the current scene uses, told from the asset folders the game opens (hle_touchhint.c), for the iOS gamepad's Rhythm layout (DmGamepad.m).
// The rules are the profile's touch_scenes.tsv (dm/games/README.md), compiled into game_profile.h as DM_GAME_TOUCH_SCENES; a game without one keeps the menu hint.
// The design is MIT-licensed Touchable's (github.com/MZhao-ouo/Touchable, by mzhao: rh_touch.c, ss_touch.h): the right half of the controls area presses A, the left half follows the scene.
#pragma once
#include <stdint.h>

// How the left half of the controls area maps to buttons
enum {
    DM_HINT_DPAD = 0,   // four directions around the area's centre; `first` holds the DM_HINT_DIR_* the scene uses (0: unknown, all four)
    DM_HINT_ONE = 1,    // the whole area presses `first` (a button bit number, dm_input.h)
    DM_HINT_TWO = 2,    // the left part presses `first`, the right part `second`
    DM_HINT_MENU = 3,   // menus and results: the four directions, labelled smaller
    DM_HINT_PAD = 4,    // a scene that needs the whole controller: the gamepad shows its 3D layout
};
enum { DM_HINT_DIR_LEFT = 1, DM_HINT_DIR_UP = 2, DM_HINT_DIR_RIGHT = 4, DM_HINT_DIR_DOWN = 8 };
enum { DM_HINT_SHOW_DPAD = 1, DM_HINT_SHOW_X = 2, DM_HINT_SHOW_Y = 4 };   // `extra`: controls shown besides the two areas

// Packed: layout | first << 8 | second << 16 | extra << 24 | change count << 32
static inline int dm_hint_layout(uint64_t h) { return (int)(h & 0xff); }
static inline int dm_hint_first(uint64_t h) { return (int)(h >> 8 & 0xff); }
static inline int dm_hint_second(uint64_t h) { return (int)(h >> 16 & 0xff); }
static inline int dm_hint_extra(uint64_t h) { return (int)(h >> 24 & 0xff); }

uint64_t dm_touch_hint(void);   // any thread; DM_HINT_MENU until a rule matches

// The tracker itself, without the host (tests: t_touchhint.c)
typedef struct { int active; unsigned keys; } dm_hint_state;   // zero-initialized: a menu
// One guest path the game opened for reading; rules: the touch_scenes.tsv rows (see hle_touchhint.c). Returns 1 and sets *hint (the low 32 bits) when the hint changes
int dm_hint_path(const char *rules, dm_hint_state *s, const char *path, uint32_t *hint);
