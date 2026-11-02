// HalfoldKit (hf_kit.h): postures, regions, fill modes, control profiles and the upside-down check, in plain C
#include "hf_kit.h"
#include <math.h>
#include <string.h>
#include <stdio.h>

hf_posture hf_posture_of(double w, double h, int hinge) {
    if (h <= w) return HF_LANDSCAPE;
    return hinge == 2 ? HF_TABLETOP : HF_PORTRAIT;
}
const char *hf_posture_name(hf_posture p) { return p == HF_TABLETOP ? "tabletop" : p == HF_PORTRAIT ? "portrait" : "landscape"; }

int hf_division_of(double w, double h, hf_rect r, hf_rect *out) {
    if (!(r.w > r.h) || w <= 0 || h <= 0) return 0;
    double x = fmax(0, r.x), y = fmax(0, r.y), right = fmin(w, r.x + r.w), bottom = fmin(h, r.y + r.h);
    if (right - x < w * 0.9 || bottom < y || y <= 0 || bottom >= h) return 0;   // a zero-height (inactive) fold is kept
    *out = (hf_rect){x, y, right - x, bottom - y}; return 1;
}
hf_layout hf_layout_make(hf_posture p, double w, double h, hf_insets safe, int hinge, double aspect) { return hf_layout_make_at(p, w, h, safe, hinge, aspect, 0); }
hf_layout hf_layout_make_at(hf_posture p, double w, double h, hf_insets safe, int hinge, double aspect, const hf_rect *division) {
    hf_layout l; memset(&l, 0, sizeof l); l.posture = p;
    if (p == HF_LANDSCAPE || h <= w) {   // the picture fills the window, the pad lies over it
        l.posture = HF_LANDSCAPE; l.picture = l.controls = (hf_rect){0, 0, w, h}; l.controls_insets = safe;
        return l;
    }
    // The picture: from the top safe area (the camera strip, at most half of the upper half) to the fold. The controls: from below the fold, or in tabletop from below the
    // hinge band. The fold: the division region when known, else a zero-height line at the window's middle
    hf_rect d; int known = division && hf_division_of(w, h, *division, &d);
    double ft = known ? floor(d.y) : floor(h / 2), fb = known ? ceil(d.y + d.h) : ft;   // the fold's top and bottom edges
    double pad = p == HF_TABLETOP ? fmax(0, HF_HINGE_BAND - (fb - ft) / 2) : 0;   // tabletop: the band reaches HF_HINGE_BAND from the fold's middle
    double mid = ft, top = fmin(safe.top, mid / 2), c0 = fb + pad;
    if (p == HF_PORTRAIT && hinge != 2 && hinge != 3 && !known && aspect > 0) mid = c0 = top + fmin(floor(w / aspect), mid - top);   // no hinge across: the picture's own height at the top
    l.picture = (hf_rect){0, top, w, mid - top};
    l.controls = (hf_rect){0, c0, w, h - c0};
    if (p == HF_TABLETOP) l.hinge_band = (hf_rect){0, ft - pad, w, fb - ft + 2 * pad};
    l.controls_insets = (hf_insets){fmax(0, safe.top - c0), safe.left, safe.bottom, safe.right};
    return l;
}

hf_fill hf_fill_parse(const char *s) {
    if (s && !strcmp(s, "stretch")) return HF_STRETCH;
    if (s && !strcmp(s, "crop")) return HF_CROP;
    return HF_FIT;
}
static hf_rect centred(hf_rect a, double w, double h) { return (hf_rect){a.x + (a.w - w) / 2, a.y + (a.h - h) / 2, w, h}; }
hf_rect hf_view_frame(hf_rect a, double aspect, hf_fill f) {
    if (f != HF_FIT || a.w <= 0 || a.h <= 0 || aspect <= 0) return a;
    hf_rect r = a.w / a.h > aspect ? centred(a, a.h * aspect, a.h) : centred(a, a.w, a.w / aspect);
    r.x = floor(r.x); r.y = floor(r.y); return r;
}
hf_rect hf_picture_rect(hf_rect a, double aspect, hf_fill f) {
    if (f != HF_CROP || a.w <= 0 || a.h <= 0 || aspect <= 0) return f == HF_FIT ? hf_view_frame(a, aspect, f) : a;
    return a.w / a.h > aspect ? centred(a, a.w, a.w / aspect) : centred(a, a.h * aspect, a.h);
}

static hf_profile with_sizes(hf_profile p) { for (int g = 0; g < HF_GROUPS; g++) p.size[g] = 1; return p; }
hf_profile hf_profile_default(hf_posture p) {
    switch (p) {
    // Portrait: thumbs reach the middle of the lower half, and touches starting at the screen's bottom edge wait for the system's home-gesture check, so the corner controls rise
    // by a fifth of the region and move 16 points in; the left stick floats (iPhone Duo trials: buttons too low, the fixed stick hard to hold)
    case HF_PORTRAIT: return with_sizes((hf_profile){.lift = 0.2, .inset = 16, .scale = 1, .float_stick = 1, .grab = 1.8, .alpha = 1});
    // Tabletop: the controls region already starts below the hinge band and lies flat, so it rises less
    case HF_TABLETOP: return with_sizes((hf_profile){.lift = 0.12, .inset = 16, .scale = 1, .float_stick = 1, .grab = 1.8, .alpha = 1});
    default: return with_sizes((hf_profile){.lift = 0, .inset = 0, .scale = 1, .float_stick = 0, .grab = 1.4, .alpha = 1});
    }
}
static double clampd(double v, double lo, double hi) { return v != v ? lo : v < lo ? lo : v > hi ? hi : v; }
hf_profile hf_profile_clamp(hf_profile p, double max_move) {
    p.scale = clampd(p.scale, HF_SCALE_MIN, HF_SCALE_MAX); p.alpha = clampd(p.alpha, HF_ALPHA_MIN, 1);
    for (int g = 0; g < HF_GROUPS; g++) { p.off[g].dx = clampd(p.off[g].dx, -max_move, max_move); p.off[g].dy = clampd(p.off[g].dy, -max_move, max_move);
        p.size[g] = clampd(p.size[g], HF_SIZE_MIN, HF_SIZE_MAX); }
    p.hidden &= (1u << HF_GROUPS) - 1;
    return p;
}
int hf_profile_format(const hf_profile *p, char *buf, int n) {
    int k = snprintf(buf, n, "hf2 %.3f %.3f %u", p->scale, p->alpha, p->hidden);
    for (int g = 0; g < HF_GROUPS && k > 0 && k < n; g++) k += snprintf(buf + k, n - k, " %.1f %.1f %.3f", p->off[g].dx, p->off[g].dy, p->size[g]);
    return k;
}
int hf_profile_parse(const char *s, hf_profile *p) {
    if (!s) return 0;
    double v[2 + 3 * HF_GROUPS]; unsigned hidden; int used = 0;
    if (!strncmp(s, "hf1 ", 4)) {   // the three groups' moves only
        if (sscanf(s, "hf1 %lf %lf %lf %lf %lf %lf %lf %lf%n", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &used) != 8 || s[used]) return 0;
        p->scale = v[0]; p->alpha = v[1];
        for (int g = 0; g < HF_GROUPS_OLD; g++) { p->off[g].dx = v[2 + 2 * g]; p->off[g].dy = v[3 + 2 * g]; }
        return 1;
    }
    if (strncmp(s, "hf2 ", 4) || sscanf(s, "hf2 %lf %lf %u%n", &v[0], &v[1], &hidden, &used) != 3) return 0;
    const char *q = s + used;
    for (int i = 0; i < 3 * HF_GROUPS; i++) { int m = 0; if (sscanf(q, " %lf%n", &v[2 + i], &m) != 1) return 0; q += m; }
    if (*q) return 0;
    p->scale = v[0]; p->alpha = v[1]; p->hidden = hidden;
    for (int g = 0; g < HF_GROUPS; g++) { p->off[g].dx = v[2 + 3 * g]; p->off[g].dy = v[3 + 3 * g]; p->size[g] = v[4 + 3 * g]; }
    return 1;
}

int hf_quarter_of_gravity(double gx, double gy) {
    if (hypot(gx, gy) < 0.5) return -1;
    double a = atan2(-gx, -gy) * 180 / M_PI, q = round(a / 90);
    if (fabs(a - q * 90) > 30) return -1;
    return ((int)q % 4 + 4) % 4;
}

void hf_flip_init(hf_flip *f, int offset) { f->offset = offset; f->state = -2; f->flipped = 0; f->since = 0; }
// In portrait the interface never turns upside down (an app built with the iOS 27.1 SDK on the iPhone Duo, iOS 27.1 and 27.2), so gravity half a turn from the offset (given, or
// the first portrait reading's) is the phone held by its other end. A quarter off is on the way to landscape and changes nothing
int hf_flip_update(hf_flip *f, int bq, int iq, double now) {
    int state = bq < 0 || iq < 0 ? -1 : (bq - iq + 8) % 4 + 10 * iq;   // the reading: gravity relative to the interface, and the interface
    if (state != f->state) { f->state = state; f->since = now; return 0; }
    if (state < 0 || now - f->since < HF_FLIP_HOLD) return 0;
    int rel = state % 10, out = 0, flip = f->flipped;
    if (iq == 1 || iq == 3) flip = 0;
    else if (iq == 2) flip = 0;   // iOS turned the interface itself
    else if (f->offset < 0) { f->offset = rel; out |= HF_FLIP_OFFSET_FIRST; }
    else if ((rel - f->offset + 4) % 4 == 0) flip = 0;
    else if ((rel - f->offset + 4) % 4 == 2) flip = 1;
    if (flip != f->flipped) { f->flipped = flip; out |= HF_FLIP_CHANGED; }
    return out;
}
