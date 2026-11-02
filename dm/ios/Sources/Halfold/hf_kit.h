// HalfoldKit: the foldable layer of Halfold (docs/nx-pocket/foldable.zh-CN.md). Plain C with no Apple framework, so the layout and self-rotation rules run in unit tests on the Mac
// (halfold/tests). The iOS front end (front_ios.m, DmGamepad.m) feeds it the window size, safe area, hinge state and gravity, and places views from what it returns.
// Units are UIKit points; rectangles have a top-left origin.
#pragma once

typedef struct { double x, y, w, h; } hf_rect;
typedef struct { double top, left, bottom, right; } hf_insets;

// Postures. Landscape: the picture fills the window and the pad lies over it (upstream's layout). Portrait: picture above the screen's middle, controls below.
// Tabletop: portrait with the hinge partly open, as a laptop: the picture stands on the upper half, the controls lie on the lower half clear of the hinge band.
typedef enum { HF_LANDSCAPE = 0, HF_PORTRAIT = 1, HF_TABLETOP = 2 } hf_posture;
// hinge: the hinge status (UIHingeStatus: 0 unknown or no hinge, 1 closed, 2 partially open, 3 fully open)
hf_posture hf_posture_of(double w, double h, int hinge);
const char *hf_posture_name(hf_posture p);

// The regions of one posture. hinge_band is empty except in tabletop; controls_insets are the safe-area insets that reach into the controls region
typedef struct { hf_posture posture; hf_rect picture, controls, hinge_band; hf_insets controls_insets; } hf_layout;
// Portrait with the hinge open (status 2 or 3): the picture ends at the fold and the controls start below it. The fold is the screen's division region when UIKit reports one
// (UIViewReservedRegionKind.divisionRegionKind, iOS 27.1: hf_layout_make_at's division), else the window's middle (iPhone Duo: each half of the inner screen has the outer screen's
// proportions). Portrait with no hinge across the screen (status 0 or 1: the outer screen, an ordinary iPhone): with aspect > 0 (the fit mode's picture ratio) the picture region is
// exactly that ratio at the top and the controls take the rest, so no black bar sits above the picture; with aspect 0 (stretch / crop fill the region) the upper half as with a hinge
hf_layout hf_layout_make(hf_posture p, double w, double h, hf_insets safe, int hinge, double aspect);
// The same with the fold's rectangle in window points (division: NULL or not across the window = unknown, the middle). A fold of some height keeps controls off itself; in tabletop
// the band stays at least HF_HINGE_BAND on each side of the fold's middle
hf_layout hf_layout_make_at(hf_posture p, double w, double h, hf_insets safe, int hinge, double aspect, const hf_rect *division);
// A division region (UIKit's frame, window points) as a fold across the window: it must be wider than tall, span 90 % of the width and lie inside the window's height. Returns 1 and
// the clipped rectangle in *out, or 0 (from upstream PR #683's dm_horizontal_division)
int hf_division_of(double w, double h, hf_rect r, hf_rect *out);
#define HF_HINGE_BAND 28.0   // points kept free of controls on each side of the hinge in tabletop (the crease)

// Fill modes of the picture in its region (the launcher's DM_FIT)
typedef enum { HF_FIT = 0, HF_STRETCH = 1, HF_CROP = 2 } hf_fill;
hf_fill hf_fill_parse(const char *s);   // "fit" / "stretch" / "crop"; anything else is fit
// The game view's frame in the region: fit = the aspect-fitted, centred rectangle; stretch and crop = the whole region (the present fills it)
hf_rect hf_view_frame(hf_rect area, double aspect, hf_fill f);
// Where the game picture's pixels land: as the view frame, except crop, whose aspect-filled rectangle overflows the region (for mapping touches onto the picture)
hf_rect hf_picture_rect(hf_rect area, double aspect, hf_fill f);

// Control profile of a posture: how the controls sit in the controls region, and how the left stick behaves.
// lift: fraction of the region's height the corner controls rise by; inset: points moved inward from the sides; scale: size factor of the three corner groups (stick, diamond,
// D-pad); float_stick: the left stick centres where the touch lands; grab: how far from its home the left stick grabs (times its ring radius); alpha: opacity factor of the controls.
// Each control (the three groups and the eight keys around them) has the player's move (off, in the pad's units), size factor (size) and can be hidden (the hidden bit mask): from
// the layout editor. A hidden control is not drawn and takes no touches
enum { HF_GROUP_STICK = 0, HF_GROUP_FACE = 1, HF_GROUP_DPAD = 2, HF_GROUPS_OLD = 3,   // the three groups of the hf1 form
       HF_CTL_ZL = 3, HF_CTL_L = 4, HF_CTL_ZR = 5, HF_CTL_R = 6, HF_CTL_MINUS = 7, HF_CTL_PLUS = 8, HF_CTL_LS = 9, HF_CTL_RS = 10, HF_GROUPS = 11 };
typedef struct { double dx, dy; } hf_offset;
typedef struct { double lift, inset, scale; int float_stick; double grab, alpha; hf_offset off[HF_GROUPS]; double size[HF_GROUPS]; unsigned hidden; } hf_profile;
hf_profile hf_profile_default(hf_posture p);
#define HF_SCALE_MIN 0.6
#define HF_SCALE_MAX 1.6
#define HF_SIZE_MIN 0.5
#define HF_SIZE_MAX 1.6
#define HF_ALPHA_MIN 0.2
// Keeps an edited profile usable: scale, sizes and alpha within their ranges, each control's move within max_move units, only known controls hidden
hf_profile hf_profile_clamp(hf_profile p, double max_move);
// The saved form of a profile's edits: "hf2 <scale> <alpha> <hidden> <dx dy size> x11". parse also reads the older "hf1 <scale> <alpha> <dx dy> x3" (the three groups; the
// other controls keep their defaults). It fills only those fields of *p (keep the defaults for the rest) and returns 0, leaving *p untouched, on anything else
#define HF_PROFILE_TEXT 512   // a buffer that holds any hf2 form
int hf_profile_format(const hf_profile *p, char *buf, int n);
int hf_profile_parse(const char *s, hf_profile *p);

// ---- Self-rotation (docs/nx-pocket/foldable.zh-CN.md 3.3) ----
// Quarter turns counter-clockwise: 0 portrait, 1 landscape left, 2 upside down, 3 landscape right (UIDeviceOrientation's turns for the gravity; for the interface, landscape right
// is 1 and landscape left 3). -1: lying flat (in-plane gravity under 0.5 G) or more than 30 degrees from a quarter
int hf_quarter_of_gravity(double gx, double gy);
// The upside-down check. offset: the screen's gravity-to-interface offset in quarters, -1 unknown; a reading must hold for HF_FLIP_HOLD seconds before anything changes
#define HF_FLIP_HOLD 0.4
typedef struct { int offset, state, flipped; double since; } hf_flip;
void hf_flip_init(hf_flip *f, int offset);
// One reading: the gravity's and the interface's quarters at time now (seconds). Returns a set of HF_FLIP_* bits: the flip changed (read f->flipped), or the offset was taken
// from the first held portrait reading (counted as upright). Landscape readings only end a flip: on the iPhone Duo two landscape readings gave offsets a quarter apart, and an
// offset kept from landscape stopped the check working in portrait
enum { HF_FLIP_CHANGED = 1, HF_FLIP_OFFSET_FIRST = 4 };
int hf_flip_update(hf_flip *f, int gravity_q, int interface_q, double now);
