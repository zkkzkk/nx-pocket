// Touch hints (touch_hint.h): the scene the game is in, told from the asset folders it opens for reading (hle_fs.c's open observer), as the buttons the gamepad's Rhythm layout shows.
// The rules come from the profile's touch_scenes.tsv (game.py emits them as DM_GAME_TOUCH_SCENES, one row per line, fields separated by tabs):
//   root  <folder>                        the folder right under a mount whose subfolders tell the scene (Rhythm Heaven Groove: graph)
//   rule  <top> <name|*> <what> [<keys>]  a path <mount>:/<root>/<top>/<name>/... ; the first matching rule applies; * matches any name
//     what: menu = back to the menu hint; set = the scene's keys are <keys>; add = <keys> join the current ones (a remix reads several scenes after its title card); skip = no change
//   level <name> <keys>                   the keys of a level, for rules whose keys are @ (a level without a row: many)
// keys: A B left up right down, joined with +; many = more than two areas hold (the left half is four directions); pad = the whole controller; showdpad / showx / showy: shown besides the areas.
// After Touchable's rh_touch.c (MIT, github.com/MZhao-ouo/Touchable, by mzhao), whose table and rules touch_scenes.tsv carries over.
#include "dm.h"
#include "touch_hint.h"
#include <stdatomic.h>

enum { K_A = 1, K_B = 2, K_LEFT = 4, K_UP = 8, K_RIGHT = 16, K_DOWN = 32, K_MANY = 64, K_PAD = 128, K_SDPAD = 256, K_SX = 512, K_SY = 1024 };
enum { BTN_A = 0, BTN_B = 1, BTN_LEFT = 12, BTN_UP = 13, BTN_RIGHT = 14, BTN_DOWN = 15 };   // dm_input.h bit numbers

static int field(const char **p, const char *end, const char **f, size_t *n) {   // the next tab-separated field of a row (end: the row's end)
    if (*p >= end) return 0;
    const char *t = memchr(*p, '\t', (size_t)(end - *p)); if (!t) t = end;
    *f = *p; *n = (size_t)(t - *p); *p = t < end ? t + 1 : end; return 1;
}
static int is(const char *f, size_t n, const char *s) { return strlen(s) == n && !memcmp(f, s, n); }
static unsigned keys_parse(const char *f, size_t n) {
    static const struct { const char *s; unsigned k; } names[] = {{"A", K_A}, {"B", K_B}, {"left", K_LEFT}, {"up", K_UP}, {"right", K_RIGHT}, {"down", K_DOWN},
        {"many", K_MANY}, {"pad", K_PAD}, {"showdpad", K_SDPAD}, {"showx", K_SX}, {"showy", K_SY}, {"none", 0}};
    unsigned k = 0; const char *end = f + n;
    while (f < end) { const char *plus = memchr(f, '+', (size_t)(end - f)); if (!plus) plus = end;
        for (size_t i = 0; i < sizeof names / sizeof *names; i++) if (is(f, (size_t)(plus - f), names[i].s)) k |= names[i].k;
        f = plus + 1; }
    return k;
}
// One row: its kind and up to four fields; returns the start of the next row
static const char *row(const char *r, char kind[8], const char *f[4], size_t n[4]) {
    const char *end = strchr(r, '\n'); if (!end) end = r + strlen(r);
    const char *p = r, *k; size_t kn; kind[0] = 0;
    for (int i = 0; i < 4; i++) { f[i] = ""; n[i] = 0; }
    if (field(&p, end, &k, &kn) && kn < 8) { memcpy(kind, k, kn); kind[kn] = 0; }
    for (int i = 0; i < 4 && field(&p, end, &f[i], &n[i]); i++) {}
    return *end ? end + 1 : end;
}
static unsigned level_keys(const char *rules, const char *name, size_t len) {
    char kind[8]; const char *f[4]; size_t n[4];
    for (const char *r = rules; *r;) { r = row(r, kind, f, n); if (!strcmp(kind, "level") && n[0] == len && !memcmp(f[0], name, len)) return keys_parse(f[1], n[1]); }
    return K_MANY;
}
static uint32_t pack(int layout, int first, int second, int extra) { return (uint32_t)layout | (uint32_t)first << 8 | (uint32_t)second << 16 | (uint32_t)extra << 24; }
static uint32_t hint_of(const dm_hint_state *s) {
    if (!s->active) return pack(DM_HINT_MENU, 0, 0, 0);
    if (s->keys & K_PAD) return pack(DM_HINT_PAD, 0, 0, 0);
    int extra = (s->keys & K_SDPAD ? DM_HINT_SHOW_DPAD : 0) | (s->keys & K_SX ? DM_HINT_SHOW_X : 0) | (s->keys & K_SY ? DM_HINT_SHOW_Y : 0);
    unsigned d = s->keys & (K_LEFT | K_UP | K_RIGHT | K_DOWN);
    int dirs = (d & K_LEFT ? DM_HINT_DIR_LEFT : 0) | (d & K_UP ? DM_HINT_DIR_UP : 0) | (d & K_RIGHT ? DM_HINT_DIR_RIGHT : 0) | (d & K_DOWN ? DM_HINT_DIR_DOWN : 0);
    if (s->keys & K_MANY || (d & (d - 1))) return pack(DM_HINT_DPAD, s->keys & K_MANY ? 0 : dirs, 0, extra);   // two or more directions: four directions around a centre
    static const struct { unsigned key; int button; } order[] = {{K_LEFT, BTN_LEFT}, {K_B, BTN_B}, {K_DOWN, BTN_DOWN}, {K_UP, BTN_UP}, {K_RIGHT, BTN_RIGHT}};   // left to right in the area
    int found[5], count = 0;
    for (int i = 0; i < 5; i++) if (s->keys & order[i].key) found[count++] = order[i].button;
    if (count == 0) return s->keys & K_A ? pack(DM_HINT_ONE, BTN_A, 0, extra) : pack(DM_HINT_DPAD, 0, 0, extra);   // A alone: both halves press A
    if (count == 1) return pack(DM_HINT_ONE, found[0], 0, extra);
    if (count == 2) return pack(DM_HINT_TWO, found[0], found[1], extra);
    return pack(DM_HINT_DPAD, dirs, 0, extra);
}

int dm_hint_path(const char *rules, dm_hint_state *s, const char *path, uint32_t *hint) {
    if (!rules || !*rules) return 0;
    const char *m = strstr(path, ":/"); if (!m) return 0;
    m += 2;
    char kind[8]; const char *f[4]; size_t n[4];
    const char *rest = NULL;
    for (const char *r = rules; *r && !rest;) { r = row(r, kind, f, n);
        if (!strcmp(kind, "root") && n[0] && !strncmp(m, f[0], n[0]) && m[n[0]] == '/') rest = m + n[0] + 1; }
    if (!rest) return 0;
    const char *slash = strchr(rest, '/'); if (!slash) return 0;
    const char *top = rest, *name = slash + 1, *end = strchr(name, '/');
    size_t tn = (size_t)(slash - top), nn = end ? (size_t)(end - name) : 0;   // a file right under <top> has no scene name
    uint32_t before = hint_of(s);
    for (const char *r = rules; *r;) { r = row(r, kind, f, n);
        if (strcmp(kind, "rule") || n[0] != tn || memcmp(f[0], top, tn)) continue;
        if (!is(f[1], n[1], "*") && (n[1] != nn || memcmp(f[1], name, nn))) continue;
        const char *what = f[2]; size_t wn = n[2];
        if (is(what, wn, "skip")) return 0;
        if (is(what, wn, "menu")) { s->active = 0; s->keys = 0; break; }
        unsigned k;
        if (is(f[3], n[3], "@")) { if (!nn) return 0; k = level_keys(rules, name, nn); }   // a level's keys need its name
        else k = keys_parse(f[3], n[3]);
        if (is(what, wn, "set")) { s->active = 1; s->keys = k; break; }
        if (is(what, wn, "add")) { if (!s->active) { s->active = 1; s->keys = 0; } s->keys |= k; break; }
        return 0;   // an unknown rule
    }
    uint32_t after = hint_of(s);
    if (after == before) return 0;
    *hint = after; return 1;
}

#ifdef DM_GAME_TOUCH_SCENES
static const char k_rules[] = DM_GAME_TOUCH_SCENES;
#else
static const char k_rules[] = "";
#endif
static _Atomic uint64_t g_hint = DM_HINT_MENU;
static pthread_mutex_t g_hint_lock = PTHREAD_MUTEX_INITIALIZER;
static dm_hint_state g_hint_state;
uint64_t dm_touch_hint(void) { return atomic_load(&g_hint); }
static void hint_open(const char *path) {   // hle_fs.c, on a guest thread, after each successful read-only open
    uint32_t h;
    pthread_mutex_lock(&g_hint_lock);
    int changed = dm_hint_path(k_rules, &g_hint_state, path, &h);
    if (changed) atomic_store(&g_hint, (uint64_t)h | ((atomic_load(&g_hint) >> 32) + 1) << 32);   // the change count: the gamepad releases a held area on every change
    pthread_mutex_unlock(&g_hint_lock);
    if (changed) LOG("touch hint: layout %d, buttons %d %d, extra %#x (%s)", dm_hint_layout(h), dm_hint_first(h), dm_hint_second(h), dm_hint_extra(h), path);
}
extern void (*g_dm_fs_open_hook)(const char *path);
__attribute__((constructor)) static void hint_init(void) { if (k_rules[0]) g_dm_fs_open_hook = hint_open; }
