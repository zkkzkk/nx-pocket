// HalfoldKit unit tests (dm/ios/Sources/Halfold/hf_kit.c): postures, regions on the iPhone Duo's screens, fill modes, profiles and the upside-down check. make -C halfold/tests
#include "../../dm/ios/Sources/Halfold/hf_kit.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)
static int eq(double a, double b) { return fabs(a - b) < 0.01; }
static int req(hf_rect r, double x, double y, double w, double h) { return eq(r.x, x) && eq(r.y, y) && eq(r.w, w) && eq(r.h, h); }

static void t_posture(void) {
    CHECK(hf_posture_of(951, 669, 3) == HF_LANDSCAPE, "landscape whatever the hinge");
    CHECK(hf_posture_of(669, 951, 3) == HF_PORTRAIT, "portrait, hinge fully open");
    CHECK(hf_posture_of(669, 951, 0) == HF_PORTRAIT, "portrait, no hinge reading");
    CHECK(hf_posture_of(669, 951, 2) == HF_TABLETOP, "portrait, hinge partially open = tabletop");
    CHECK(hf_posture_of(500, 500, 2) == HF_LANDSCAPE, "a square window counts as landscape");
}

static void t_layout(void) {
    hf_insets none = {0, 0, 0, 0}, duo = {0, 0, 34, 0}, cam = {59, 0, 34, 0};
    double k = 16.0 / 9;
    hf_layout l = hf_layout_make(HF_LANDSCAPE, 951, 669, duo, 3, k);
    CHECK(req(l.picture, 0, 0, 951, 669) && req(l.controls, 0, 0, 951, 669) && eq(l.controls_insets.bottom, 34), "landscape: picture and controls fill the window");
    l = hf_layout_make(HF_PORTRAIT, 669, 951, duo, 3, k);   // the Duo's inner screen held upright, hinge fully open
    CHECK(req(l.picture, 0, 0, 669, 475) && req(l.controls, 0, 475, 669, 476), "portrait on the inner screen: halves at the middle");
    CHECK(eq(l.controls_insets.top, 0) && eq(l.controls_insets.bottom, 34) && l.hinge_band.h == 0, "portrait: bottom inset only, no hinge band");
    l = hf_layout_make(HF_PORTRAIT, 466, 678, cam, 0, 0);   // the outer screen held upright, a camera strip at the top, stretch / crop
    CHECK(req(l.picture, 0, 59, 466, 280) && req(l.controls, 0, 339, 466, 339), "outer screen, filling fill mode: the upper half below the camera strip");
    l = hf_layout_make(HF_PORTRAIT, 466, 678, cam, 1, k);   // the outer screen (hinge closed), fit
    CHECK(req(l.picture, 0, 59, 466, 262) && req(l.controls, 0, 321, 466, 357), "outer screen, fit: a 16:9 picture region at the top, the controls take the rest");
    l = hf_layout_make(HF_PORTRAIT, 440, 956, (hf_insets){62, 0, 34, 0}, 0, k);   // an ordinary iPhone: no hinge reading
    CHECK(req(l.picture, 0, 62, 440, 247) && eq(l.controls.y, 309) && eq(l.controls_insets.top, 0), "an iPhone held upright: picture at the top, no black bar above it");
    l = hf_layout_make(HF_PORTRAIT, 400, 1000, none, 1, 0.5);
    CHECK(eq(l.picture.h, 500) && eq(l.controls.y, 500), "a tall picture ratio is held to the upper half");
    l = hf_layout_make(HF_PORTRAIT, 400, 800, (hf_insets){300, 0, 0, 0}, 3, k);
    CHECK(eq(l.picture.y, 200) && eq(l.picture.h, 200), "a top inset takes at most half of the upper half");
    l = hf_layout_make(HF_TABLETOP, 669, 951, duo, 2, k);
    CHECK(req(l.picture, 0, 0, 669, 475) && eq(l.controls.y, 475 + HF_HINGE_BAND) && eq(l.controls.y + l.controls.h, 951), "tabletop: controls start below the hinge band");
    CHECK(req(l.hinge_band, 0, 475 - HF_HINGE_BAND, 669, 2 * HF_HINGE_BAND), "tabletop: the band straddles the hinge");
    l = hf_layout_make(HF_PORTRAIT, 951, 669, none, 1, k);
    CHECK(l.posture == HF_LANDSCAPE && req(l.picture, 0, 0, 951, 669), "a landscape window never splits");
}

// The fold from UIKit's division region (upstream PR #683): its real place instead of the window's middle
static void t_division(void) {
    hf_rect d;
    CHECK(hf_division_of(669, 951, (hf_rect){0, 470, 669, 12}, &d) && req(d, 0, 470, 669, 12), "a fold across the window");
    CHECK(hf_division_of(669, 951, (hf_rect){-5, 480, 680, 0}, &d) && req(d, 0, 480, 669, 0), "a zero-height (inactive) fold, clipped to the window");
    CHECK(!hf_division_of(669, 951, (hf_rect){300, 0, 12, 951}, &d), "an upright region is no fold across the window");
    CHECK(!hf_division_of(669, 951, (hf_rect){0, 470, 400, 12}, &d), "a region under 90 % of the width");
    CHECK(!hf_division_of(669, 951, (hf_rect){0, 0, 669, 12}, &d) && !hf_division_of(669, 951, (hf_rect){0, 951, 669, 4}, &d), "a region at the window's edge");
    hf_insets duo = {0, 0, 34, 0}; double k = 16.0 / 9;
    hf_rect fold = {0, 460, 669, 20};
    hf_layout l = hf_layout_make_at(HF_PORTRAIT, 669, 951, duo, 3, k, &fold);
    CHECK(req(l.picture, 0, 0, 669, 460) && req(l.controls, 0, 480, 669, 471), "portrait: the picture ends at the fold's top, the controls start at its bottom");
    l = hf_layout_make_at(HF_TABLETOP, 669, 951, duo, 2, k, &fold);
    CHECK(eq(l.picture.h, 460) && eq(l.controls.y, 480 + HF_HINGE_BAND - 10) && req(l.hinge_band, 0, 460 - (HF_HINGE_BAND - 10), 669, 20 + 2 * (HF_HINGE_BAND - 10)), "tabletop: the band reaches HF_HINGE_BAND from the fold's middle");
    hf_rect wide = {0, 400, 669, 100};
    l = hf_layout_make_at(HF_TABLETOP, 669, 951, duo, 2, k, &wide);
    CHECK(eq(l.controls.y, 500) && eq(l.hinge_band.h, 100), "a fold wider than the band: the fold itself");
    hf_rect bogus = {0, 0, 10, 10};
    hf_layout a = hf_layout_make_at(HF_PORTRAIT, 669, 951, duo, 3, k, &bogus), b = hf_layout_make(HF_PORTRAIT, 669, 951, duo, 3, k);
    CHECK(req(a.picture, b.picture.x, b.picture.y, b.picture.w, b.picture.h) && req(a.controls, b.controls.x, b.controls.y, b.controls.w, b.controls.h), "no usable fold: the middle, as before");
    l = hf_layout_make_at(HF_PORTRAIT, 466, 678, (hf_insets){59, 0, 34, 0}, 1, k, 0);
    CHECK(req(l.picture, 0, 59, 466, 262), "no fold and no hinge (outer screen): the fit picture at the top, as before");
}

static void t_fill(void) {
    hf_rect a = {0, 0, 669, 475}; double k = 16.0 / 9;
    CHECK(hf_fill_parse("crop") == HF_CROP && hf_fill_parse("stretch") == HF_STRETCH && hf_fill_parse("x") == HF_FIT && hf_fill_parse(0) == HF_FIT, "fill names");
    hf_rect v = hf_view_frame(a, k, HF_FIT);
    CHECK(eq(v.w, 669) && eq(v.h, 669 / k) && eq(v.y, floor((475 - 669 / k) / 2)), "fit: full width, centred vertically");
    CHECK(req(hf_view_frame(a, k, HF_STRETCH), 0, 0, 669, 475) && req(hf_view_frame(a, k, HF_CROP), 0, 0, 669, 475), "stretch and crop: the view takes the region");
    hf_rect p = hf_picture_rect(a, k, HF_CROP);
    CHECK(eq(p.h, 475) && eq(p.w, 475 * k) && eq(p.x, (669 - 475 * k) / 2), "crop: the picture overflows both sides");
    CHECK(req(hf_picture_rect(a, k, HF_STRETCH), 0, 0, 669, 475), "stretch: the picture is the region");
    hf_rect wide = {0, 0, 951, 400};
    CHECK(eq(hf_view_frame(wide, k, HF_FIT).h, 400) && eq(hf_picture_rect(wide, k, HF_CROP).w, 951), "a region wider than 16:9");
}

static void t_profile(void) {
    hf_profile l = hf_profile_default(HF_LANDSCAPE), p = hf_profile_default(HF_PORTRAIT), t = hf_profile_default(HF_TABLETOP);
    CHECK(l.lift == 0 && l.inset == 0 && !l.float_stick && eq(l.grab, 1.4), "landscape keeps upstream's layout");
    CHECK(eq(p.lift, 0.2) && eq(p.inset, 16) && p.float_stick && eq(p.grab, 1.8), "portrait: raised, inset, floating stick");
    CHECK(t.lift < p.lift && t.float_stick, "tabletop rises less");
    CHECK(eq(l.alpha, 1) && eq(p.off[HF_GROUP_FACE].dx, 0), "defaults: opaque, nothing moved");
    // The editor's saved form
    hf_profile e = p; e.scale = 1.25; e.alpha = 0.6; e.off[HF_GROUP_STICK] = (hf_offset){12, -40}; e.off[HF_GROUP_DPAD] = (hf_offset){-3.5, 7};
    char buf[HF_PROFILE_TEXT]; hf_profile_format(&e, buf, sizeof buf);
    hf_profile r = hf_profile_default(HF_PORTRAIT);
    CHECK(hf_profile_parse(buf, &r) && eq(r.scale, 1.25) && eq(r.alpha, 0.6) && eq(r.off[HF_GROUP_STICK].dy, -40) && eq(r.off[HF_GROUP_DPAD].dx, -3.5), "format then parse gives the edits back");
    CHECK(eq(r.lift, 0.2) && r.float_stick, "parse keeps the posture's defaults for the rest");
    CHECK(eq(r.size[HF_CTL_ZL], 1) && !r.hidden, "an hf2 form keeps sizes and hidden");
    // Per control: sizes, hidden controls, the eight keys' moves
    e.size[HF_CTL_ZL] = 1.4; e.size[HF_GROUP_FACE] = 0.8; e.hidden = 1u << HF_CTL_LS | 1u << HF_GROUP_DPAD; e.off[HF_CTL_PLUS] = (hf_offset){-20, 15.5};
    hf_profile_format(&e, buf, sizeof buf); r = hf_profile_default(HF_PORTRAIT);
    CHECK(!strncmp(buf, "hf2 ", 4) && hf_profile_parse(buf, &r) && eq(r.size[HF_CTL_ZL], 1.4) && eq(r.size[HF_GROUP_FACE], 0.8) && r.hidden == e.hidden && eq(r.off[HF_CTL_PLUS].dy, 15.5),
          "hf2: per-control sizes, hidden controls and moves");
    // The older form (the three groups only) still loads; the other controls keep their defaults
    r = hf_profile_default(HF_LANDSCAPE);
    CHECK(hf_profile_parse("hf1 1.200 0.700 5.0 -6.0 0.0 0.0 10.0 2.0", &r) && eq(r.scale, 1.2) && eq(r.off[HF_GROUP_STICK].dy, -6) && eq(r.off[HF_GROUP_DPAD].dx, 10)
          && eq(r.size[HF_CTL_R], 1) && !r.hidden && eq(r.off[HF_CTL_ZR].dx, 0), "hf1 forms load into hf2 profiles");
    hf_profile k = r;
    CHECK(!hf_profile_parse("hf1 1 1", &k) && !hf_profile_parse("hf2 1 1 0 0 0 0 0 0", &k) && !hf_profile_parse("hf1 1 1 0 0 0 0 0 0 x", &k) && !hf_profile_parse(0, &k) && eq(k.scale, 1.2), "bad saved forms leave the profile alone");
    e.scale = 9; e.alpha = 0; e.off[HF_GROUP_FACE] = (hf_offset){500, -500};
    hf_profile c = hf_profile_clamp(e, 200);
    CHECK(eq(c.scale, HF_SCALE_MAX) && eq(c.alpha, HF_ALPHA_MIN) && eq(c.off[HF_GROUP_FACE].dx, 200) && eq(c.off[HF_GROUP_FACE].dy, -200) && eq(c.off[HF_GROUP_STICK].dx, 12), "clamp: scale, alpha and moves within range");
    e.size[HF_CTL_RS] = 9; e.size[HF_CTL_L] = 0; e.hidden = ~0u; c = hf_profile_clamp(e, 200);
    CHECK(eq(c.size[HF_CTL_RS], HF_SIZE_MAX) && eq(c.size[HF_CTL_L], HF_SIZE_MIN) && c.hidden == (1u << HF_GROUPS) - 1, "clamp: sizes, and only known controls hidden");
    char shortbuf[8]; hf_profile_format(&e, shortbuf, sizeof shortbuf);
    CHECK(strlen(shortbuf) < sizeof shortbuf, "format into a short buffer stays terminated");
}

static void t_quarter(void) {
    CHECK(hf_quarter_of_gravity(0, -1) == 0 && hf_quarter_of_gravity(-1, 0) == 1 && hf_quarter_of_gravity(0, 1) == 2 && hf_quarter_of_gravity(1, 0) == 3, "the four quarters");
    CHECK(hf_quarter_of_gravity(0.64, 0) == 3, "the Duo held by its other end (gravity 0.64 0.00 -0.45)");
    CHECK(hf_quarter_of_gravity(0.1, 0.2) == -1, "lying flat");
    CHECK(hf_quarter_of_gravity(0.7, -0.7) == -1 && hf_quarter_of_gravity(0.3, -0.9) == 0, "between two quarters / within 30 degrees");
}

static void t_flip(void) {
    hf_flip f; hf_flip_init(&f, -1);
    // Upright on the Duo's inner screen: gravity quarter 1 with a portrait interface. The first held reading sets the offset
    CHECK(hf_flip_update(&f, 1, 0, 0.0) == 0, "a new reading is only timed");
    CHECK(hf_flip_update(&f, 1, 0, 0.2) == 0, "before the hold time nothing changes");
    CHECK(hf_flip_update(&f, 1, 0, 0.5) == HF_FLIP_OFFSET_FIRST && f.offset == 1 && !f.flipped, "first portrait reading taken as upright");
    // Held by the other end: gravity quarter 3, the interface stays portrait
    hf_flip_update(&f, 3, 0, 1.0);
    CHECK(hf_flip_update(&f, 3, 0, 1.5) == HF_FLIP_CHANGED && f.flipped, "upside down: the stage turns");
    CHECK(hf_flip_update(&f, -1, 0, 2.0) == 0 && hf_flip_update(&f, -1, 0, 3.0) == 0 && f.flipped, "lying flat keeps the state");
    hf_flip_update(&f, 2, 0, 3.1); hf_flip_update(&f, 2, 0, 3.6);
    CHECK(f.flipped, "a quarter off (on the way to landscape) changes nothing");
    hf_flip_update(&f, 1, 0, 4.0);
    CHECK(hf_flip_update(&f, 1, 0, 4.5) == HF_FLIP_CHANGED && !f.flipped, "upright again: back");
    // Landscape only ends a flip: it never changes the offset (two landscape readings on the Duo gave offsets a quarter apart)
    hf_flip_update(&f, 3, 0, 5.0); hf_flip_update(&f, 3, 0, 5.5);
    hf_flip_update(&f, 0, 1, 6.0);
    CHECK(f.flipped && hf_flip_update(&f, 0, 1, 6.5) == HF_FLIP_CHANGED && !f.flipped && f.offset == 1, "landscape ends a flip and leaves the offset alone");
    hf_flip_update(&f, 2, 3, 7.0);
    CHECK(hf_flip_update(&f, 2, 3, 7.5) == 0 && f.offset == 1, "the other landscape too");
    // iOS turning the interface itself (a newer SDK): no second turn
    hf_flip_init(&f, 1); f.flipped = 1;
    hf_flip_update(&f, 3, 2, 8.0);
    CHECK(hf_flip_update(&f, 3, 2, 8.5) == HF_FLIP_CHANGED && !f.flipped, "an upside-down interface is left to iOS");
    // An ordinary iPhone: offset 0, upright portrait reads quarter 0
    hf_flip_init(&f, -1); hf_flip_update(&f, 0, 0, 0); hf_flip_update(&f, 0, 0, 1);
    hf_flip_update(&f, 2, 0, 2);
    CHECK(f.offset == 0 && hf_flip_update(&f, 2, 0, 3) == HF_FLIP_CHANGED && f.flipped, "an iPhone: offset 0, upside down turns");
}

int main(void) {
    t_posture(); t_layout(); t_division(); t_fill(); t_profile(); t_quarter(); t_flip();
    printf("HalfoldKit: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
