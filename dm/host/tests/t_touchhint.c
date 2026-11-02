// Touch hints (hle_touchhint.c) with Rhythm Heaven Groove's rules (dm/games/0100D9F01D474000/touch_scenes.tsv): the scenes after Touchable's test_touch.c (MIT, by mzhao)
#include "../hle_touchhint.c"
#include <assert.h>
void (*g_dm_fs_open_hook)(const char *path);   // hle_fs.c's, not linked here

static char rules[16384];
static dm_hint_state st;
static uint32_t hint = DM_HINT_MENU;
static int fails;
static void open_path(const char *p) { dm_hint_path(rules, &st, p, &hint); }
static void expect(int line, int layout, int first, int second, int extra) {
    if (dm_hint_layout(hint) == layout && dm_hint_first(hint) == first && dm_hint_second(hint) == second && dm_hint_extra(hint) == extra) return;
    fprintf(stderr, "t_touchhint:%d: got layout %d %d %d extra %d, want %d %d %d extra %d\n", line, dm_hint_layout(hint), dm_hint_first(hint), dm_hint_second(hint), dm_hint_extra(hint),
            layout, first, second, extra);
    fails++;
}
#define EXPECT(...) expect(__LINE__, __VA_ARGS__)
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "t_touchhint:%d: %s\n", __LINE__, #c); fails++; } } while (0)

int main(void) {
    FILE *f = fopen("../../games/0100D9F01D474000/touch_scenes.tsv", "r");
    if (!f) { perror("touch_scenes.tsv"); return 1; }
    char line[512]; size_t n = 0;
    while (fgets(line, sizeof line, f)) if (line[0] != '#' && line[0] != '\n') { size_t k = strlen(line); assert(n + k < sizeof rules); memcpy(rules + n, line, k); n += k; }
    fclose(f);
    uint32_t out;
    // no rules: nothing changes
    CHECK(!dm_hint_path("", &st, "data:/graph/prologue/flydisc/type_00/prologue.spr", &out));
    // paths outside graph/ and the shared scene folders change nothing
    CHECK(!dm_hint_path(rules, &st, "data:/mesg/CN/CNzh/stage_parasol_00.msbt", &out));
    CHECK(!dm_hint_path(rules, &st, "data:/graph/scene/common/info.spr", &out));
    CHECK(!dm_hint_path(rules, &st, "data:/graph", &out));
    open_path("data:/graph/menu/main_menu/main.spr");
    EXPECT(DM_HINT_MENU, 0, 0, 0);
    // an A-only minigame: both halves press A
    open_path("data:/graph/prologue/flydisc/type_00/prologue.spr");
    EXPECT(DM_HINT_ONE, BTN_A, 0, 0);
    open_path("data:/graph/scene/common/pause.spr");
    open_path("data:/graph/scene/flydisc/type_00/main.spr");
    EXPECT(DM_HINT_ONE, BTN_A, 0, 0);
    CHECK(!dm_hint_path(rules, &st, "data:/graph/scene/flydisc/type_00/bg.spr", &out));
    open_path("data:/graph/menu/main_menu/main.spr");
    EXPECT(DM_HINT_MENU, 0, 0, 0);
    // one direction, entered without a title card
    open_path("data:/graph/scene/parasol/type_00/main.spr");
    EXPECT(DM_HINT_ONE, BTN_DOWN, 0, 0);
    open_path("data:/graph/result/result.spr");
    EXPECT(DM_HINT_MENU, 0, 0, 0);
    // left and right steps: four directions
    open_path("data:/graph/prologue/dancer/type_00/prologue.spr");
    EXPECT(DM_HINT_DPAD, DM_HINT_DIR_LEFT | DM_HINT_DIR_RIGHT, 0, 0);
    // a B minigame
    open_path("data:/graph/prologue/foot_race/type_00/prologue.spr");
    EXPECT(DM_HINT_ONE, BTN_B, 0, 0);
    // a remix combines its scenes; a new title card starts over
    open_path("data:/graph/prologue/remix/type_00/prologue.spr");
    EXPECT(DM_HINT_DPAD, 0, 0, 0);
    open_path("data:/graph/scene/ring/type_00/main.spr");
    EXPECT(DM_HINT_ONE, BTN_A, 0, 0);
    open_path("data:/graph/scene/hurdle/type_00/main.spr");
    EXPECT(DM_HINT_ONE, BTN_DOWN, 0, 0);
    open_path("data:/graph/scene/wiper/type_00/main.spr");
    EXPECT(DM_HINT_DPAD, DM_HINT_DIR_LEFT | DM_HINT_DIR_DOWN, 0, 0);
    open_path("data:/graph/scene/rolling/type_00/main.spr");
    EXPECT(DM_HINT_DPAD, DM_HINT_DIR_LEFT | DM_HINT_DIR_RIGHT | DM_HINT_DIR_DOWN, 0, 0);
    open_path("data:/graph/prologue/wiper/type_00/prologue.spr");
    EXPECT(DM_HINT_ONE, BTN_LEFT, 0, 0);
    // a remix of a B scene and a left scene: two areas, left then B
    open_path("data:/graph/prologue/remix/type_01/prologue.spr");
    open_path("data:/graph/scene/quiz/type_00/main.spr");
    EXPECT(DM_HINT_ONE, BTN_B, 0, 0);
    open_path("data:/graph/scene/brush/type_00/main.spr");
    EXPECT(DM_HINT_TWO, BTN_LEFT, BTN_B, 0);
    // Drum Lessons: the whole controller; many buttons and unknown scenes: four directions
    open_path("data:/graph/scene/drummer/type_00/main.spr");
    open_path("data:/graph/prologue/drummer/type_00/prologue.spr");
    EXPECT(DM_HINT_PAD, 0, 0, 0);
    open_path("data:/graph/scene/audio_tile/type_00/main.spr");
    open_path("data:/graph/prologue/audio_tile/type_00/prologue.spr");
    EXPECT(DM_HINT_DPAD, 0, 0, 0);
    open_path("data:/graph/prologue/new_game/type_00/prologue.spr");
    EXPECT(DM_HINT_DPAD, 0, 0, 0);
    open_path("data:/graph/menu/main_menu/main.spr");
    EXPECT(DM_HINT_MENU, 0, 0, 0);
    // BeatSpell: the left area steps with B; the four directions, X and Y are shown too
    open_path("data:/graph/beatspell/common/common.spr");
    EXPECT(DM_HINT_ONE, BTN_B, 0, DM_HINT_SHOW_DPAD | DM_HINT_SHOW_X | DM_HINT_SHOW_Y);
    CHECK(!dm_hint_path(rules, &st, "data:/graph/beatspell/bg/castle_00.spr", &out));
    open_path("data:/graph/menu/main_menu/main.spr");
    EXPECT(DM_HINT_MENU, 0, 0, 0);
    open_path("data:/graph/prologue/flydisc/type_00/prologue.spr");
    EXPECT(DM_HINT_ONE, BTN_A, 0, 0);
    if (fails) { fprintf(stderr, "t_touchhint: %d failed\n", fails); return 1; }
    puts("t_touchhint: all passed");
    return 0;
}
