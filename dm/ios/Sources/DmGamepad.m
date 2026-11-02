// Virtual gamepad (Nintendo button positions, or Xbox / PlayStation with DM_PAD_AB=xbox) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults per game (PAD_KEY); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch), and not to a Rhythm game.
//   Rhythm (♪, only for a profile with pad_layout rhythm, Rhythm Heaven Groove): two touch areas side by side; anywhere in the right half presses A, the left half presses what the current
//     scene uses (touch_hint.h: one button, two side by side, two opposite directions as its halves, or four as the triangles between its diagonals), told by the host from
//     the asset folders the game reads (touch_scenes.tsv). The areas' outlines, dashed split lines and labels show for 3 s on each new scene (its title card), then fade.
//     − and + stay at the top centre, B in the top-left corner, X and Y in the top-right one when the scene uses them; a scene that needs the whole controller (Drum Lessons) shows the 3D layout.
//     After the touch design of Touchable (MIT, github.com/MZhao-ouo/Touchable, by mzhao).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys; DM_PAD_AB=xbox (the launcher's A/B buttons) puts A at the bottom and B on the right (Xbox / PlayStation). Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); DM_PAD_AB=xbox swaps A and B, so bottom = A and right = B (Xbox / PlayStation).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include <stdatomic.h>
#include "Halfold/hf_kit.h"
#include "DmSwipeLook.h"       // swipe camera and touch-control settings (from upstream PR #258)
#include "DmTouchControls.h"
#include "touch_hint.h"         // the Rhythm layout's scene hints (hle_touchhint.c)

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME, C_EDIT, C_EXIT, C_ZONE };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8); C_ZONE: a Rhythm area (0 left, 1 right, << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static double g_grav[3]; static BOOL g_grav_ok;   // the low-passed gravity (G, the device's own axes) for front_ios.m's upside-down check, under g_mu
int dm_gravity(double g[3]) { pthread_mutex_lock(&g_mu); int ok = g_grav_ok; memcpy(g, g_grav, sizeof g_grav); pthread_mutex_unlock(&g_mu); return ok; }
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; g_grav[0] = gx; g_grav[1] = gy; g_grav[2] = gz; g_grav_ok = YES; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static _Atomic int g_stage_turned;          // front_ios.m turned the stage (the pad's parent) half a turn: dm_gamepad_set_turned
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        // ... except for a turn of the app's own: Core Motion's body frame follows the window, not the view's transform (measured on iPhone Duo, iOS 27.1 and 27.2), so with
        // the stage upside down the samples are half a turn from the picture
        if (o == 1 && atomic_load(&g_stage_turned)) o = 2;   // the stage turns only in a portrait interface
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_CLICK_X = 102, K_CLICK_R = 17,                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
    K_MIN_HIT = 22;                                 // the smallest grab radius of a key, in points (Apple's 44-point target; from upstream PR #683)
// Per posture (raised and inset corner controls, a floating left stick and its grab distance): HalfoldKit's control profile, hf_profile_default
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
// A game pack shares NX Pocket's preferences with the other games: its keys start with its title ID. An app is one game: the plain key, as before
#if DM_PACK
#define PAD_KEY(k) @DM_GAME_ID "." k
#else
#define PAD_KEY(k) k
#endif
static NSString *const k_layout_key = PAD_KEY(@"DmPadLayout");   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap, 3 = Rhythm (DM_GAME_PAD_LAYOUT's numbers)
static int g_ab_xbox;   // DM_PAD_AB=xbox: A at the bottom and B on the right (Xbox / PlayStation), not Nintendo's A right / B bottom
int dm_opmode(void);   // hle_oe.c: 0 = handheld

hf_layout front_ios_layout(CGRect bounds, UIEdgeInsets safe);   // front_ios.m: the posture's picture and controls regions (HalfoldKit)

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    CGPoint _lCentre;                              // portrait: the left stick's centre, likewise (stickHome while not held)
    UIEdgeInsets _insets; BOOL _haveInsets;
    hf_profile _prof[3]; BOOL _profLoaded[3];      // each posture's control profile: HalfoldKit's default with the player's saved edits (layout editor)
    BOOL _editing; int _editGroup, _editSel; CGPoint _editLast; UIView *_editBar; UILabel *_editHint;   // the layout editor: on, the control being dragged and where, the selected control (-1 none), its toolbar
    UIButton *_editHide;                           // the toolbar's Hide / Show button (its title follows the selected control)
    int _lastPosture;                              // the posture at the last layout: a change releases every touch (a held key or stick would stay held across it)
    BOOL _swapLong;                                // the layout button was held long enough to open the editor (its release does not change the layout)        // the safe area as front_ios.m measures it in its stage (turned upside down, UIKit's own insets would not match)
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    CAShapeLayer *_editKey; CATextLayer *_editLabel; BOOL _editHeld;   // the Edit pill right of + (editRect): opens the layout editor
    CAShapeLayer *_exitKey; CATextLayer *_exitLabel; BOOL _exitHeld;   // a game from NX Pocket: the Home pill left of − (exitRect): NX Pocket's home screen, the game paused
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    UIImpactFeedbackGenerator *_releaseFeedback;     // a softer one per release edge (DM_TOUCH_HAPTICS=2), so a key feels pressed and let go (upstream PR #433)
    CGFloat _pressIntensity, _releaseIntensity;      // DM_TOUCH_HAPTICS_GAIN (0.2..2, default 1): up to 1 scales the light tap (0.6 at 1); past 1 the press uses the medium style, 0.5 → 1
    BOOL _floatAny;                                // DM_TOUCH_STICK=float (the launcher's Left stick "Anywhere on the left", upstream PR #500): the left half of the controls area holds a floating left stick in every posture
    DmTouchControls _touchSettings;                // DM_TOUCH_SWIPE, DM_TOUCH_SWIPE_GAIN, DM_TOUCH_LEFT_DEADZONE, DM_TOUCH_RIGHT_AREA (upstream PR #258)
    DmSwipeLook _look; CADisplayLink *_lookLink; int32_t _lookX, _lookY;   // the swipe camera: finger velocity resampled each display frame, gone within 40 ms of the last move
    double _diag;                                  // D-pad diagonal zone, 0..1 of the 90° between two directions (DM_DPAD_DIAGONAL; 0.5 = 45°, 0 = four directions)
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current (in the Rhythm layout _full is a scene that needs the whole controller)
    BOOL _rhythm;                                  // the Rhythm layout is current
    uint64_t _hint;                                // the scene hint last applied (touch_hint.h, with its change count)
    uint64_t _zoneBits; BOOL _zoneHeld[2];         // the Rhythm areas' keys and which area a finger holds
    CAShapeLayer *_zone[2]; CATextLayer *_zoneLabel[5];   // the two areas (left, right) and their labels (four on the left; the right one, A, stays hidden)
    CAShapeLayer *_zoneLines; CFTimeInterval _zoneShownAt;   // the left area's dashed split lines; when the areas were last shown (they fade 3 s later)
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout
// The layout editor's controls (hf_kit.h HF_GROUP_* / HF_CTL_*): the three corner groups and the eight keys around them; each key belongs to one
static int ctl_of_key(int b) {
    switch (b) { case B_ZL: return HF_CTL_ZL; case B_L: return HF_CTL_L; case B_ZR: return HF_CTL_ZR; case B_R: return HF_CTL_R; case B_MINUS: return HF_CTL_MINUS;
                 case B_PLUS: return HF_CTL_PLUS; case B_LS: return HF_CTL_LS; case B_RS: return HF_CTL_RS; case B_A: case B_B: case B_X: case B_Y: return HF_GROUP_FACE; default: return HF_GROUP_DPAD; }
}
static BOOL ctlFullOnly(int c) { return c == HF_GROUP_DPAD || c == HF_CTL_LS || c == HF_CTL_RS; }
static BOOL hf_zh(void);   // the layout editor's words in Chinese (defined with the editor)

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *ab = getenv("DM_PAD_AB");
        g_ab_xbox = ab && !strcmp(ab, "xbox");
        LOG("front end: A/B buttons: %s", g_ab_xbox ? "A at the bottom, B on the right" : "A on the right, B at the bottom");
        const char *feedback = getenv("DM_TOUCH_HAPTICS"); int fb = feedback ? atoi(feedback) : 1;   // 0 off, 1 on press, 2 on press and release
        const char *gain = getenv("DM_TOUCH_HAPTICS_GAIN"); CGFloat g = gain && *gain ? fmin(fmax(atof(gain), 0.2), 2) : 1;
        _pressIntensity = g <= 1 ? 0.6 * g : 0.5 + 0.5 * (g - 1); _releaseIntensity = fmin(0.35 * g, 1);
        if (fb) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:g <= 1 ? UIImpactFeedbackStyleLight : UIImpactFeedbackStyleMedium];
            [_touchFeedback prepare];
        }
        if (fb >= 2) { _releaseFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft]; [_releaseFeedback prepare]; }
        const char *ls = getenv("DM_TOUCH_STICK"); _floatAny = ls && !strcmp(ls, "float");
        _touchSettings = dm_touch_controls(getenv("DM_TOUCH_SWIPE"), getenv("DM_TOUCH_SWIPE_GAIN"), getenv("DM_TOUCH_LEFT_DEADZONE"), getenv("DM_TOUCH_RIGHT_AREA"));
        LOG("touch controls: swipe %d, sensitivity %.0f%%, left dead zone %.0f%%, camera area %s", _touchSettings.swipe, _touchSettings.swipe_gain * 100, _touchSettings.left_deadzone * 100, _touchSettings.right_fraction == 0.5 ? "right half" : "right third");
        const char *dg = getenv("DM_DPAD_DIAGONAL"); _diag = dg && *dg ? fmin(fmax(atof(dg), 0), 1) : 0.5;
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        _editSel = -1; _lastPosture = -1;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        for (int i = 0; i < 2; i++) { _zone[i] = shape(_controls); _zone[i].shadowOpacity = 0; }   // below every key: a key over an area takes its touches first
        for (int i = 0; i < 5; i++) _zoneLabel[i] = label(_zone[i < 4 ? 0 : 1], @"");
        _zoneLines = shape(_zone[0]); _zoneLines.fillColor = nil; _zoneLines.shadowOpacity = 0; _zoneLines.lineWidth = 1; _zoneLines.lineDashPattern = @[@6, @6];
        _hint = dm_touch_hint();
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        _editKey = shape(_controls); _editLabel = label(_editKey, hf_zh() ? @"编辑" : @"Edit");
#if DM_PACK
        _exitKey = shape(_controls); _exitLabel = label(_exitKey, hf_zh() ? @"主页" : @"Home");
#else
        _exitKey = nil;   // a game's own app: the system's app switcher ends it
#endif
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && (dm_opmode() != 0 || DM_GAME_PAD_LAYOUT == 3)) l = DM_GAME_PAD_LAYOUT == 3 ? 3 : 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it), never for a Rhythm game (it reads no touch screen)
        if (l == 3 && DM_GAME_PAD_LAYOUT != 3) l = 0;   // Rhythm only for a profile that starts in it
        if (DM_GAME_PAD_LAYOUT == 3 && ![NSUserDefaults.standardUserDefaults boolForKey:PAD_KEY(@"DmPadRhythmShown")]) {   // an app updated from a build without it starts once in it too
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:PAD_KEY(@"DmPadRhythmShown")]; l = 3; }
        [self setLayoutNumber:l];
        [self applyLayout]; [self showZones];
        __weak DmGamepad *weak = self;   // the scene hint changes on a guest thread: read it 20 times a second (a scene's title card lasts seconds)
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) { DmGamepad *me = weak; if (me) [me pollHint]; else [timer invalidate]; }];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    hf_profile pr = self.profile;   // hidden controls: not drawn while playing, faint in the editor (so they can be shown again)
    BOOL z = self.zones; int ex = dm_hint_extra(_hint);
    for (int b = 0; b < B_N; b++) { BOOL off = pr.hidden >> ctl_of_key(b) & 1;
        _key[b].hidden = _tap || (z ? !beatKey(b, ex) : fullOnly(b) && !_full) || (off && !_editing); _key[b].opacity = off ? 0.35 : 1; }
    BOOL soff = pr.hidden >> HF_GROUP_STICK & 1;
    _ring.hidden = _knob.hidden = _tap || z || (soff && !_editing); _ring.opacity = _knob.opacity = soff ? 0.35 : 1;
    _editKey.hidden = _tap || z || _editing;   // nothing to edit in the Tap and Rhythm layouts; the editor's own toolbar replaces it
    _exitKey.hidden = _tap || _editing;   // no key row to sit in in the Tap layout; the Rhythm layout keeps it (the way home)
    _zone[0].hidden = _zone[1].hidden = !z;
    _swapLabel.string = _rhythm ? @"♪" : _tap ? @"Tap" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode, but not for a Rhythm profile: that game reads no touch screen) (→ Rhythm for its profile) → 2D: release every touch first (no key stays held), save, lay out again
    BOOL beat = DM_GAME_PAD_LAYOUT == 3;
    int l = _rhythm ? 0 : _tap ? (beat ? 3 : 0) : _full ? (beat ? 3 : dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    [self setLayoutNumber:l];
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self showZones]; [self setNeedsLayout];
}
- (void)showZones {   // the Rhythm areas' outlines and labels: shown on a new scene (its title card) or layout, faded 3 s later (pollHint); the areas work the same unseen
    _zoneShownAt = CACurrentMediaTime();
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _zone[0].opacity = _zone[1].opacity = 1; [CATransaction commit];
}
- (void)setLayoutNumber:(int)l { _rhythm = l == 3; _tap = l == 2; _full = l == 1 || (_rhythm && dm_hint_layout(_hint) == DM_HINT_PAD); }
- (BOOL)zones { return _rhythm && !_full; }   // the Rhythm layout's two areas are up (not a scene that needs the whole controller)
// The keys the Rhythm areas leave: − and + always, B, X and Y as the scene shows them, the D-pad when the scene shows it
static BOOL beatKey(int b, int extra) {
    return b == B_MINUS || b == B_PLUS || b == B_B || (b == B_X && extra & DM_HINT_SHOW_X) || (b == B_Y && extra & DM_HINT_SHOW_Y) || (b >= B_LEFT && extra & DM_HINT_SHOW_DPAD);
}
- (void)pollHint {   // a new scene: the left area changes, and a finger on it lets go (a held key of the old scene must not carry over); A stays held
    if (_zoneShownAt && CACurrentMediaTime() - _zoneShownAt > 3) {
        _zoneShownAt = 0; [CATransaction begin]; [CATransaction setAnimationDuration:0.6]; _zone[0].opacity = _zone[1].opacity = 0; [CATransaction commit]; }
    uint64_t h = dm_touch_hint(); if (h == _hint) return;
    BOOL wasPad = dm_hint_layout(_hint) == DM_HINT_PAD, pad = dm_hint_layout(h) == DM_HINT_PAD;
    _hint = h;
    if (!_rhythm || _editing) return;
    if (pad != wasPad) { [self reset]; _full = pad; }
    else { NSMutableArray<UITouch *> *left = [NSMutableArray array];
        for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; if ((v & 0xff) == C_ZONE && !(v >> 8)) [left addObject:t]; }
        for (UITouch *t in left) [_owner removeObjectForKey:t];
        [self recompute]; }
    [self applyLayout]; [self showZones]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
// The controls' region: the whole view in landscape; in portrait the half below the screen's middle, in tabletop below the hinge band (front_ios.m front_ios_layout).
// The view itself stays full screen, so touches on the picture still reach the game's touch screen
- (hf_layout)layout { return front_ios_layout(self.bounds, self.padInsets); }
- (CGRect)area { hf_rect r = self.layout.controls; return CGRectMake(r.x, r.y, r.w, r.h); }
// The posture's control profile: HalfoldKit's default with the player's edits, saved per posture in NSUserDefaults (per game: PAD_KEY)
static NSString *prof_key(hf_posture p) { return [NSString stringWithFormat:PAD_KEY(@"HalfoldProfile.%s"), hf_posture_name(p)]; }
#define HF_MAX_MOVE 300   // how far the editor moves a group, in pad units
- (hf_profile)profile {
    hf_posture p = self.layout.posture;
    if (!_profLoaded[p]) { hf_profile d = hf_profile_default(p); NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:prof_key(p)];
        if (saved) hf_profile_parse(saved.UTF8String, &d);
        _prof[p] = hf_profile_clamp(d, HF_MAX_MOVE); _profLoaded[p] = YES; }
    return _prof[p];
}
- (CGFloat)gu { return self.u * self.profile.scale; }   // the unit of the three movable groups (stick, diamond, D-pad): the pad unit times the profile's size
- (BOOL)floating { return _floatAny || self.profile.float_stick; }
- (BOOL)shown:(int)c { return !(self.profile.hidden >> c & 1); }   // a hidden control takes no touches
- (CGFloat)sz:(int)c { return self.profile.size[c]; }   // the control's own size factor (layout editor)
- (UIEdgeInsets)padInsets { return _haveInsets ? _insets : self.safeAreaInsets; }
- (void)setPadInsets:(UIEdgeInsets)i { if (_haveInsets && UIEdgeInsetsEqualToEdgeInsets(i, _insets)) return; _insets = i; _haveInsets = YES; [self setNeedsLayout]; }
- (UIEdgeInsets)areaInsets { hf_insets i = self.layout.controls_insets; return UIEdgeInsetsMake(i.top, i.left, i.bottom, i.right); }   // the view's insets that reach into the region
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.area, self.areaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.areaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN;   // the rectangle the bottom-corner controls use, raised and inset by the profile
    hf_profile p = self.profile; CGFloat in = p.inset * self.u; i.left += in; i.right += in; i.bottom += (self.area.size.height - i.bottom) * p.lift;
    return UIEdgeInsetsInsetRect(self.area, i); }
// 1 = 430 points tall (iPhone Pro Max landscape); a narrow region (the iPhone Duo's outer screen in portrait) also bounds it by its width, so the two bottom corners' controls
// (each about 175 units from its side with the portrait inset) keep a gap between them (after upstream PR #683's width-aware unit)
- (CGFloat)u { CGSize a = self.area.size; return MIN(MIN(a.height / 430.0, a.width / 420.0), 1.3); }
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
static CGPoint moved(CGPoint c, hf_offset o, CGFloat u) { return CGPointMake(c.x + o.dx * u, c.y + o.dy * u); }   // a group moved by the profile's edit
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return moved(side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u), self.profile.off[HF_GROUP_FACE], u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.gu * [self sz:HF_GROUP_FACE]; }
- (CGFloat)faceR { return K_FACE_R * self.gu * [self sz:HF_GROUP_FACE]; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    if (g_ab_xbox) b = b == B_A ? B_B : b == B_B ? B_A : b;   // Xbox / PlayStation: A at the bottom, B on the right
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome { CGRect s = self.corner; CGFloat u = self.u; return moved(side(s, 0, K_STICK_X * u, CGRectGetMaxY(s) - K_PAD_Y * u), self.profile.off[HF_GROUP_STICK], u); }   // the left stick's ring centre
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.floating && _stick[0] ? _lCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return i ? K_RSTICK_R * self.u : K_STICK_R * self.gu * [self sz:HF_GROUP_STICK]; }
- (BOOL)inLeftArea:(CGPoint)p { CGRect b = self.area; return CGRectContainsPoint(b, p) && p.x < CGRectGetMinX(b) + b.size.width / 2; }   // DM_TOUCH_STICK=float: the floating left stick's area
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.area; return CGRectContainsPoint(b, p) && dm_touch_right_area(&_touchSettings, p.x - CGRectGetMinX(b), b.size.width); }   // the camera area: the right third (or half, DM_TOUCH_RIGHT_AREA) of the controls area
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return moved(side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u), self.profile.off[HF_GROUP_DPAD], u); }
- (CGFloat)dpadR { return K_DPAD_R * self.gu * [self sz:HF_GROUP_DPAD]; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return moved(side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u), self.profile.off[ctl_of_key(b)], u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u * [self sz:ctl_of_key(b)]; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return moved(side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u), self.profile.off[ctl_of_key(b)], u); }
- (CGFloat)clickR:(int)b { return K_CLICK_R * self.u * [self sz:ctl_of_key(b)]; }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, k = [self sz:ctl_of_key(b)], w = K_PILL_W * u * k, h = K_PILL_H * u * k;
    CGPoint c = moved(CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u), self.profile.off[ctl_of_key(b)], u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }
// The Edit pill right of +, and in a game from NX Pocket the Home pill left of −: in the top row, off the picture, each as tall as its neighbour key and level with it (that
// key's size and place follow the player's layout edits), its grab area (8 points around it, inEdit / inExit) kept 8 points clear of the key's and of R3's / L3's. Where the
// row has no room (the iPhone Duo's narrow outer screen, where a pill there took taps meant for +), below the layout button in the free centre column, side by side
- (CGRect)sidePill:(BOOL)right {
    CGRect s = self.safe; CGFloat u = self.u;
    CGRect key = [self pillRect:right ? B_PLUS : B_MINUS];
    CGFloat h = key.size.height, w = MAX(key.size.width, K_PILL_W * u), reach = MAX(key.size.width / 2 + 8 * u, K_MIN_HIT) - key.size.width / 2;
    CGFloat x = right ? CGRectGetMaxX(key) + reach + 16 * u + w / 2 : CGRectGetMinX(key) - reach - 16 * u - w / 2, y = CGRectGetMidY(key);
    int click = right ? B_RS : B_LS; CGFloat cx = [self clickCenter:click].x, cr = MAX([self clickR:click] * 1.35, K_MIN_HIT) + 8 * u;
    if (right ? x + w / 2 + 8 * u > cx - cr : x - w / 2 - 8 * u < cx + cr) {
        w = K_PILL_W * u; h = K_PILL_H * u; y = CGRectGetMinY(s) + (K_PILL_Y + K_PILL_H + 16) * u;
        x = CGRectGetMidX(s) + (_exitKey ? (right ? 1 : -1) * (w / 2 + 8 * u) : 0);
    }
    return CGRectMake(x - w / 2, y - h / 2, w, h);
}
- (CGRect)editRect { return [self sidePill:YES]; }
- (CGRect)exitRect { return [self sidePill:NO]; }
- (CGPoint)beatCenter:(int)b { return [self dropCenter:b == B_B ? B_ZL : b == B_X ? B_ZR : B_R]; }   // the Rhythm layout's B (top left), X and Y (top right, X above)
- (CGFloat)beatR { return K_L_R * self.u; }
- (CGRect)zoneRect:(int)side { CGRect a = self.safe; CGFloat w = a.size.width / 2, g = 4 * self.u;   // the two areas: the halves of the controls region, a small gap between them
    return CGRectMake(a.origin.x + side * w + (side ? g : 0), a.origin.y, w - g, a.size.height); }
- (int)zoneSide:(CGPoint)p { return p.x >= CGRectGetMidX(self.area); }
- (int)zoneDirs { int l = dm_hint_layout(_hint), d = l == DM_HINT_DPAD ? dm_hint_first(_hint) : 0; return d ? d : DM_HINT_DIR_LEFT | DM_HINT_DIR_UP | DM_HINT_DIR_RIGHT | DM_HINT_DIR_DOWN; }   // the directions the left area offers (menus, unknown scenes: all four)
- (uint64_t)zoneBits:(int)side at:(CGPoint)p {   // the keys a finger on an area presses (it keeps the area it landed on)
    if (side) return 1ull << B_A;
    CGRect r = [self zoneRect:0]; int l = dm_hint_layout(_hint), first = dm_hint_first(_hint), dirs = self.zoneDirs;
    if (l == DM_HINT_ONE) return 1ull << first;
    if (l == DM_HINT_TWO) return 1ull << (p.x < CGRectGetMidX(r) ? first : dm_hint_second(_hint));
    CGFloat dx = p.x - CGRectGetMidX(r), dy = p.y - CGRectGetMidY(r);
    if (dirs == (DM_HINT_DIR_LEFT | DM_HINT_DIR_RIGHT)) return 1ull << (dx < 0 ? B_LEFT : B_RIGHT);   // two opposite directions: the area's halves
    if (dirs == (DM_HINT_DIR_UP | DM_HINT_DIR_DOWN)) return 1ull << (dy < 0 ? B_UP : B_DOWN);
    if (hypot(dx, dy) < 20 * self.u) return 0;   // four directions: the four triangles between the area's diagonals, none in a small circle at the centre
    return fabs(dx) * r.size.height > fabs(dy) * r.size.width ? 1ull << (dx < 0 ? B_LEFT : B_RIGHT) : 1ull << (dy < 0 ? B_UP : B_DOWN);
}
- (BOOL)inEdit:(CGPoint)p { return !_tap && !self.zones && !_editing && CGRectContainsPoint(CGRectInset(self.editRect, -8 * self.u, -8 * self.u), p); }
- (BOOL)inExit:(CGPoint)p { return _exitKey && !_tap && !_editing && CGRectContainsPoint(CGRectInset(self.exitRect, -8 * self.u, -8 * self.u), p); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
static CGFloat rectDist(CGRect r, CGPoint p) { return hypot(fmax(fmax(CGRectGetMinX(r) - p.x, p.x - CGRectGetMaxX(r)), 0), fmax(fmax(CGRectGetMinY(r) - p.y, p.y - CGRectGetMaxY(r)), 0)); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked): the nearest whose grab area holds the touch, each at least K_MIN_HIT points (upstream PR #683)
    CGFloat u = self.u, best = INFINITY; int hit = -1;
    if (self.zones) {   // the Rhythm layout: − / +, and B, X, Y in the top corners
        static const int beat[] = {B_MINUS, B_PLUS, B_B, B_X, B_Y};
        for (int i = 0; i < 5; i++) { int b = beat[i]; if (!beatKey(b, dm_hint_extra(_hint))) continue;
            CGFloat d, r;
            if (b == B_MINUS || b == B_PLUS) { CGRect rc = [self pillRect:b]; d = rectDist(rc, p); r = MAX(8 * u, K_MIN_HIT - MIN(rc.size.width, rc.size.height) / 2); }
            else { d = dist(p, [self beatCenter:b]); r = MAX(self.beatR * 1.35, K_MIN_HIT); }
            if (d <= r && d / r < best) { best = d / r; hit = b; } }
        return hit;
    }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if ((fullOnly(b) && !_full) || ![self shown:ctl_of_key(b)]) continue;
        CGFloat d, r;   // distance from the key, and its grab radius
        if (isDrop(b)) { d = dist(p, [self dropCenter:b]); r = MAX([self dropR:b] * 1.35, K_MIN_HIT); }
        else if (isClick(b)) { d = dist(p, [self clickCenter:b]); r = MAX([self clickR:b] * 1.35, K_MIN_HIT); }
        else { CGRect rc = [self pillRect:b]; d = rectDist(rc, p); r = MAX(8 * u, K_MIN_HIT - MIN(rc.size.width, rc.size.height) / 2); }
        if (d <= r && d / r < best) { best = d / r; hit = b; } }
    return hit;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= MAX(K_SWAP_R * self.u * 1.6, K_MIN_HIT); }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI, h = 45 + 45 * _diag; uint64_t m = 0;   // each direction holds ±h° around its axis: the diagonal zone between two is (2h − 90)°, 45° by default
    if (fabs(a) < h) m |= 1ull << B_RIGHT;
    if (fabs(a - 90) < h) m |= 1ull << B_UP;
    if (180 - fabs(a) < h) m |= 1ull << B_LEFT;
    if (fabs(a + 90) < h) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0, zone = 0; BOOL swap = NO, editWas = _editHeld, exitWas = _exitHeld; _editHeld = _exitHeld = NO;
    BOOL heldWas[2] = {_zoneHeld[0], _zoneHeld[1]}; _zoneHeld[0] = _zoneHeld[1] = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_ZONE) { zone |= [self zoneBits:(int)(v >> 8) at:[t locationInView:self]]; _zoneHeld[v >> 8 & 1] = YES; }
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES;
        else if (c == C_EDIT) _editHeld = YES;
        else if (c == C_EXIT) _exitHeld = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        if (i == 1 && _touchSettings.swipe) { ax[2] = _lookX; ax[3] = _lookY; continue; }   // the swipe camera: finger velocity, not a knob
        CGPoint o = [self knobOffset:i];   // outside the dead zone: 0 rising to full at 0.8 of the ring radius (dm_touch_axes); host: up is positive
        dm_touch_axes(o.x, o.y, [self stickR:i], i ? K_DEAD : _touchSettings.left_deadzone, &ax[i * 2], &ax[i * 2 + 1]);
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || zone != _zoneBits || swap != _swapHeld || editWas != _editHeld || exitWas != _exitHeld || heldWas[0] != _zoneHeld[0] || heldWas[1] != _zoneHeld[1];
    uint64_t was = _faceBits | _dpadBits | _btnBits | _zoneBits, now = face | dpad | btn | zone, pressed = now & ~was, released = was & ~now;
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:_pressIntensity]; [_touchFeedback prepare];
    } else if (released) {   // a press wins when a slide releases one key and presses the next
        [_releaseFeedback impactOccurredWithIntensity:_releaseIntensity]; [_releaseFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _zoneBits = zone; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = now; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    hf_rect pr = hf_picture_rect(self.layout.picture, 16.0 / 9, hf_fill_parse(getenv("DM_FIT")));   // where the picture's pixels land: its region and the fill mode (nvn_mtl.m present_fit_mode)
    CGFloat x0 = pr.x, y0 = pr.y, w = pr.w, h = pr.h;
    if (w <= 0 || h <= 0) return;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
// Only a touch on the picture goes to the game's touch screen: in portrait and tabletop a touch in the controls region or on the hinge that no control takes is dropped
// (it was clamped onto the picture's bottom edge, and the Tap layout tapped there; from upstream PR #683). In landscape the picture region is the whole view
- (BOOL)inPicture:(CGPoint)p { hf_rect r = self.layout.picture; return CGRectContainsPoint(CGRectMake(r.x, r.y, r.w, r.h), p); }
- (BOOL)gameBegin:(UITouch *)t {
    if (![self inPicture:[t locationInView:self]]) return NO;
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (_editing) { [self editBegan:ts]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        if ([self inEdit:p]) { [_owner setObject:@(C_EDIT) forKey:t]; continue; }   // before the keys: its grab area must not lose to a neighbour's
        if ([self inExit:p]) { [_owner setObject:@(C_EXIT) forKey:t]; continue; }
        int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; _swapLong = NO; [self performSelector:@selector(swapHeld) withObject:nil afterDelay:0.8]; continue; }   // held 0.8 s: the layout editor
        if (_tap) { game |= [self gameBegin:t]; continue; }
        if (self.zones) {   // the Rhythm layout: the D-pad when the scene shows it, then the area the finger lands on; outside the controls region (portrait's picture) the game's touch screen
            if (dm_hint_extra(_hint) & DM_HINT_SHOW_DPAD && dist(p, self.dpadCenter) <= self.dpadR * K_DPAD_GRAB) [_owner setObject:@(C_DPAD) forKey:t];
            else if (CGRectContainsPoint(self.area, p)) [_owner setObject:@(C_ZONE | (uint64_t)[self zoneSide:p] << 8) forKey:t];
            else game |= [self gameBegin:t];
            continue;
        }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        BOOL face = [self shown:HF_GROUP_FACE], pad = _full && [self shown:HF_GROUP_DPAD], stick = [self shown:HF_GROUP_STICK];   // a hidden control takes no touches
        if (face) { CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; } }
        if (pad) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (stick && !_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * self.profile.grab); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && stick && _floatAny && !_stick[0] && [self inLeftArea:p]) kind = C_STICK;   // anywhere on the left: centred where the touch lands (_lCentre below)
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; if (_touchSettings.swipe) [self beginLook:p time:t.timestamp]; else _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; if (!idx) _lCentre = p; }   // _lCentre: portrait's floating left stick
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (_editing) { [self editMoved:ts]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) {
                if (_touchSettings.swipe) dm_swipe_move(&_look, p.x, p.y, t.timestamp);   // the swipe camera: velocity, not position
                else { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                    if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
            else if (self.floating) { CGFloat d = dist(p, _lCentre), R = [self stickR:0];   // the floating left stick (profile), likewise
                if (d > R) _lCentre = CGPointMake(p.x - (p.x - _lCentre.x) * R / d, p.y - (p.y - _lCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    if (_editing) { if (_editGroup >= 0) [self saveProfile]; _editGroup = -1; return; }   // a drag is saved when the finger lifts
    BOOL swap = NO, game = NO, edit = NO, quit = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == C_SWAP) [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(swapHeld) object:nil];
        if (ended && (v & 0xff) == C_EDIT && [self inEdit:[t locationInView:self]]) edit = YES;   // the Edit pill: counts when released on it
        if (ended && (v & 0xff) == C_EXIT && [self inExit:[t locationInView:self]]) quit = YES;   // the Exit pill too
        if (ended && (v & 0xff) == C_SWAP && !_swapLong && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button, and not after opening the editor
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; if (t == _stick[1]) [self stopLook]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
    if (edit) [self enterEditor];
#if DM_PACK
    if (quit) { void front_ios_home(void); front_ios_home(); }   // front_ios.m: NX Pocket's home screen over the paused game
#endif
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
// Touch events and the display / game run at different rates: the swipe velocity is resampled each display frame rather than cleared on every callback (that would alternate tilt
// and neutral). The link exists only while a swipe is held; release, cancellation and focus loss end it (upstream PR #258)
- (void)beginLook:(CGPoint)p time:(NSTimeInterval)time {
    [self stopLook];
    dm_swipe_begin(&_look, p.x, p.y, time);
    _lookLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(lookFrame:)];
    [_lookLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)stopLook { [_lookLink invalidate]; _lookLink = nil; _look = (DmSwipeLook){0}; _lookX = _lookY = 0; }
- (void)lookFrame:(CADisplayLink *)link { dm_swipe_frame(&_look, CACurrentMediaTime(), self.u, _touchSettings.swipe_gain, &_lookX, &_lookY); [self recompute]; }
- (void)reset { [self stopLook]; [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    hf_posture ps = self.layout.posture;
    if (_lastPosture >= 0 && (int)ps != _lastPosture) { LOG("front end: posture %s: every touch released", hf_posture_name(ps)); [self reset]; }   // held keys do not carry over to the new places (upstream PR #683)
    _lastPosture = ps;
    [self applyLayout];   // the posture's hidden controls
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    [self applyAlpha:self.profile.alpha];
    CGFloat gu = self.gu;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * gu * [self sz:HF_GROUP_FACE]); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u * [self sz:ctl_of_key(b)]);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, [self clickR:b])); placeLabel(_label[b], c, 13 * u * [self sz:ctl_of_key(b)]);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u * [self sz:ctl_of_key(b)]);
        }
    }
    if (self.zones) {
        for (int b = B_B; b <= B_Y; b++) { CGPoint c = [self beatCenter:b]; setPath(_key[b], circlePath(c, self.beatR)); placeLabel(_label[b], c, 18 * u); }
        [self layoutZones];
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    CGFloat du = gu * [self sz:HF_GROUP_DPAD];
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * du, K_ARM_IN * du, arms[i].angle, 6 * du));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    CGRect er = self.editRect; setPath(_editKey, CGPathCreateWithRoundedRect(er, er.size.height / 2, er.size.height / 2, NULL));
    placeLabel(_editLabel, CGPointMake(CGRectGetMidX(er), CGRectGetMidY(er)), 14 * u);
    if (_exitKey) { CGRect xr = self.exitRect; setPath(_exitKey, CGPathCreateWithRoundedRect(xr, xr.size.height / 2, xr.size.height / 2, NULL));
        placeLabel(_exitLabel, CGPointMake(CGRectGetMidX(xr), CGRectGetMidY(xr)), 14 * u); }
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * gu * [self sz:HF_GROUP_STICK]; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    if (_editing) [self placeEditBar];
    [self refresh];
}
- (void)layoutZones {   // the two areas, the left one's dashed split lines and its labels, where it presses something besides A (the right area is always A: no label)
    static NSString *const sym[B_N] = {[B_A] = @"A", [B_B] = @"B", [B_X] = @"X", [B_Y] = @"Y", [B_LEFT] = @"◀", [B_UP] = @"▲", [B_RIGHT] = @"▶", [B_DOWN] = @"▼"};
    CGFloat u = self.u;
    for (int i = 0; i < 2; i++) { CGRect r = [self zoneRect:i]; setPath(_zone[i], CGPathCreateWithRoundedRect(r, 18 * u, 18 * u, NULL)); }
    _zoneLabel[4].hidden = YES;
    CGRect r = [self zoneRect:0]; int l = dm_hint_layout(_hint), dirs = self.zoneDirs;
    CGFloat x0 = CGRectGetMinX(r), x1 = CGRectGetMaxX(r), y0 = CGRectGetMinY(r), y1 = CGRectGetMaxY(r);
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    CGMutablePathRef lines = CGPathCreateMutable();
    for (int i = 0; i < 4; i++) _zoneLabel[i].hidden = YES;
    if (l == DM_HINT_ONE) { int b = dm_hint_first(_hint) & 15;
        if (b != B_A) { _zoneLabel[0].hidden = NO; _zoneLabel[0].string = sym[b] ?: @""; placeLabel(_zoneLabel[0], c, 30 * u); } }   // both areas A: nothing to tell
    else if (l == DM_HINT_TWO) {
        CGPathMoveToPoint(lines, NULL, c.x, y0 + 12 * u); CGPathAddLineToPoint(lines, NULL, c.x, y1 - 12 * u);
        for (int i = 0; i < 2; i++) { _zoneLabel[i].hidden = NO; _zoneLabel[i].string = sym[(i ? dm_hint_second(_hint) : dm_hint_first(_hint)) & 15] ?: @"";
            placeLabel(_zoneLabel[i], CGPointMake(x0 + r.size.width * (i ? 0.75 : 0.25), c.y), 30 * u); } }
    else if (dirs == (DM_HINT_DIR_LEFT | DM_HINT_DIR_RIGHT) || dirs == (DM_HINT_DIR_UP | DM_HINT_DIR_DOWN)) {   // two opposite directions: halves
        BOOL lr = dirs & DM_HINT_DIR_LEFT;
        if (lr) { CGPathMoveToPoint(lines, NULL, c.x, y0 + 12 * u); CGPathAddLineToPoint(lines, NULL, c.x, y1 - 12 * u); }
        else { CGPathMoveToPoint(lines, NULL, x0 + 12 * u, c.y); CGPathAddLineToPoint(lines, NULL, x1 - 12 * u, c.y); }
        for (int i = 0; i < 2; i++) { _zoneLabel[i].hidden = NO; _zoneLabel[i].string = sym[lr ? (i ? B_RIGHT : B_LEFT) : (i ? B_DOWN : B_UP)];
            placeLabel(_zoneLabel[i], lr ? CGPointMake(x0 + r.size.width * (i ? 0.75 : 0.25), c.y) : CGPointMake(c.x, y0 + r.size.height * (i ? 0.75 : 0.25)), 30 * u); } }
    else {   // four triangles between the diagonals, each direction's arrow in its own (the ones the scene uses; menus smaller)
        CGPathMoveToPoint(lines, NULL, x0, y0); CGPathAddLineToPoint(lines, NULL, x1, y1); CGPathMoveToPoint(lines, NULL, x1, y0); CGPathAddLineToPoint(lines, NULL, x0, y1);
        static const int dirs4[4] = {B_UP, B_DOWN, B_LEFT, B_RIGHT}, bit4[4] = {DM_HINT_DIR_UP, DM_HINT_DIR_DOWN, DM_HINT_DIR_LEFT, DM_HINT_DIR_RIGHT};
        CGFloat fs = (l == DM_HINT_MENU ? 20 : 28) * u, hx = r.size.width * 0.33, hy = r.size.height * 0.33;
        CGPoint at[4] = {{c.x, c.y - hy}, {c.x, c.y + hy}, {c.x - hx, c.y}, {c.x + hx, c.y}};
        for (int i = 0; i < 4; i++) if (dirs & bit4[i]) { _zoneLabel[i].hidden = NO; _zoneLabel[i].string = sym[dirs4[i]]; placeLabel(_zoneLabel[i], at[i], fs); } }
    setPath(_zoneLines, lines);
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    for (int i = 0; i < 2; i++) _zone[i].fillColor = (_zoneHeld[i] ? k_ringFill : UIColor.clearColor).CGColor;   // an area lights faintly while held
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    _editKey.fillColor = (_editHeld ? k_on : k_idle).CGColor; _editLabel.foregroundColor = (_editHeld ? k_textOn : k_text).CGColor;
    _exitKey.fillColor = (_exitHeld ? k_on : k_idle).CGColor; _exitLabel.foregroundColor = (_exitHeld ? k_textOn : k_text).CGColor;
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0];
    if (self.floating) setPath(_ring, circlePath(h, [self stickR:0]));   // the floating ring follows its centre
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    // the layout editor's selected control: a white outline (from upstream PR #630)
    CGColorRef sel = [UIColor colorWithWhite:1 alpha:0.95].CGColor;
    for (int b = 0; b < B_N; b++) { BOOL on = _editing && ctl_of_key(b) == _editSel; _key[b].strokeColor = on ? sel : k_line.CGColor; _key[b].lineWidth = on ? 3 : 1.5; }
    BOOL st = _editing && _editSel == HF_GROUP_STICK; _ring.strokeColor = st ? sel : k_line.CGColor; _ring.lineWidth = st ? 3 : 1.5;
    [CATransaction commit];
}

// ---- Layout editor (Halfold) ----
// The Edit pill (right of +, editRect), or the layout button held 0.8 s: the pad stops sending input. A tap selects a control (the stick, the diamond, the D-pad, ZL, L, ZR, R,
// −, +, L3, R3: outlined) and a drag moves it, kept inside the controls region; the toolbar sizes, hides / shows or resets the selected one (with none selected, Smaller / Larger size
// the three corner groups together), sets the controls' opacity, resets the whole posture to HalfoldKit's default, or closes (Done). Every change is saved at once; each posture
// (landscape, portrait, tabletop) keeps its own edits. Hidden controls are drawn faint in the editor and not at all while playing. After upstream PR #630's per-control editor.
// Chinese words when the device or game is Chinese
// DM_UI_LANG (zh or en: NX Pocket's Settings › Language, set before the game starts) wins; else the device's language or the packed game language
static BOOL hf_zh(void) {
    const char *u = getenv("DM_UI_LANG"), *l = getenv("DM_LANG");
    if (u && *u) return !strncmp(u, "zh", 2);
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] || (l && !strncmp(l, "zh", 2));
}
- (void)applyAlpha:(double)a {   // the colours' own opacities times the profile's alpha (no group opacity: it would add an off-screen pass)
    static double last = -1; if (a == last) return; last = a;
    k_idle = [UIColor colorWithWhite:1 alpha:0.14 * a]; k_on = [UIColor colorWithWhite:1 alpha:0.45 * a]; k_line = [UIColor colorWithWhite:1 alpha:0.38 * a];
    k_ringFill = [UIColor colorWithWhite:1 alpha:0.06 * a]; k_text = [UIColor colorWithWhite:1 alpha:0.6 * a];
    for (int b = 0; b < B_N; b++) _key[b].strokeColor = k_line.CGColor;
    _ring.strokeColor = _knob.strokeColor = _swap.strokeColor = _editKey.strokeColor = _exitKey.strokeColor = _zone[0].strokeColor = _zone[1].strokeColor = _zoneLines.strokeColor = k_line.CGColor; _ring.fillColor = k_ringFill.CGColor;
    ((CAShapeLayer *)_knob.sublayers.firstObject).strokeColor = k_line.CGColor;
}
- (void)swapHeld {
    if (_editing || _padOff || self.zones) return;   // the Rhythm areas have nothing to move
    BOOL held = NO; for (UITouch *t in _owner) if (([_owner objectForKey:t].unsignedLongLongValue & 0xff) == C_SWAP) held = YES;
    if (!held) return;
    _swapLong = YES; [self enterEditor];
}
- (void)enterEditor {   // from the Edit pill or a held layout button: release every touch, stop input, show the toolbar
    if (_editing || _padOff) return;
    [self reset]; _editing = YES; _editGroup = -1; _editSel = -1; _editKey.hidden = _exitKey.hidden = YES;
    [_touchFeedback impactOccurred];
    [self applyLayout]; [self showEditBar]; [self refresh];
    LOG("front end: layout editor on (%s)", hf_posture_name(self.layout.posture));
}
- (UIButton *)editButton:(NSString *)title action:(SEL)sel {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.title = title; c.baseForegroundColor = UIColor.whiteColor; c.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    c.cornerStyle = UIButtonConfigurationCornerStyleMedium; c.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 10);
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}
// Two rows, so a narrow screen (the iPhone Duo's outer screen in portrait) holds them: the selected control's (size, hide, reset), then the whole layout's (opacity, reset, done)
- (void)showEditBar {
    BOOL zh = hf_zh();
    _editHide = [self editButton:zh ? @"隐藏" : @"Hide" action:@selector(editHideShow)];
    UIStackView *r1 = [[UIStackView alloc] initWithArrangedSubviews:@[[self editButton:zh ? @"缩小" : @"Smaller" action:@selector(editSmaller)], [self editButton:zh ? @"放大" : @"Larger" action:@selector(editLarger)],
                                                                      _editHide, [self editButton:zh ? @"复位此键" : @"Reset key" action:@selector(editResetOne)]]];
    UIStackView *r2 = [[UIStackView alloc] initWithArrangedSubviews:@[[self editButton:zh ? @"更透明" : @"Fainter" action:@selector(editFainter)], [self editButton:zh ? @"更清楚" : @"Bolder" action:@selector(editBolder)],
                                                                      [self editButton:zh ? @"全部重置" : @"Reset all" action:@selector(editReset)], [self editButton:zh ? @"完成" : @"Done" action:@selector(editDone)]]];
    r1.spacing = r2.spacing = 8;
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[r1, r2]]; bar.axis = UILayoutConstraintAxisVertical; bar.spacing = 6; bar.alignment = UIStackViewAlignmentCenter;
    _editBar = bar; [self addSubview:bar];
    _editHint = [UILabel new]; _editHint.textColor = UIColor.whiteColor; _editHint.font = [UIFont systemFontOfSize:14]; _editHint.textAlignment = NSTextAlignmentCenter;
    _editHint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; _editHint.layer.cornerRadius = 6; _editHint.clipsToBounds = YES; _editHint.numberOfLines = 2;
    [self addSubview:_editHint];
    [self placeEditBar];
}
static NSString *ctl_name(int c, BOOL zh) {
    static NSString *const en[HF_GROUPS] = {@"left stick", @"ABXY", @"D-pad", @"ZL", @"L", @"ZR", @"R", @"−", @"+", @"L3", @"R3"};
    static NSString *const cn[HF_GROUPS] = {@"左摇杆", @"ABXY", @"十字键", @"ZL", @"L", @"ZR", @"R", @"−", @"+", @"L3", @"R3"};
    return c >= 0 && c < HF_GROUPS ? (zh ? cn : en)[c] : @"";
}
- (void)placeEditBar {
    BOOL zh = hf_zh(); hf_posture p = self.layout.posture;
    NSString *pn = zh ? (p == HF_TABLETOP ? @"半折" : p == HF_PORTRAIT ? @"竖屏" : @"横屏") : @(hf_posture_name(p));
    if (_editSel < 0) _editHint.text = [NSString stringWithFormat:zh ? @"  编辑按键（%@）：点选一个按键再拖动；不选时缩放作用于三组主按键  " : @"  Edit controls (%@): tap a control to select it, drag to move; with none selected, size changes the three corner groups  ", pn];
    else _editHint.text = [NSString stringWithFormat:zh ? @"  编辑按键（%@）：已选 %@%@  " : @"  Edit controls (%@): %@ selected%@  ", pn, ctl_name(_editSel, zh), [self shown:_editSel] ? @"" : (zh ? @"（已隐藏）" : @" (hidden)")];
    BOOL sel = _editSel >= 0, off = sel && ![self shown:_editSel];
    UIButtonConfiguration *c = _editHide.configuration; c.title = off ? (zh ? @"显示" : @"Show") : (zh ? @"隐藏" : @"Hide"); _editHide.configuration = c;
    _editHide.enabled = sel;
    // Placed in the controls region's upper middle, below the layout button, never on the hinge or the picture (the editor of upstream PR #630 centres it on the screen,
    // which on a folded Duo is the crease)
    CGRect s = self.safe; CGSize bs = [_editBar systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGFloat y = CGRectGetMinY(s) + 56 * self.u;
    _editBar.frame = CGRectMake(floor(CGRectGetMidX(s) - bs.width / 2), floor(y), bs.width, bs.height);
    CGSize hs = [_editHint sizeThatFits:CGSizeMake(s.size.width - 16, 60)];
    _editHint.frame = CGRectMake(floor(CGRectGetMidX(s) - hs.width / 2), floor(y + bs.height + 8), hs.width, hs.height + 8);
}
// Where each control sits and how far from it a touch picks it (layout editor)
- (CGPoint)centreOf:(int)c {
    switch (c) {
    case HF_GROUP_STICK: return self.stickHome; case HF_GROUP_FACE: return self.faceCenter; case HF_GROUP_DPAD: return self.dpadCenter;
    case HF_CTL_ZL: return [self dropCenter:B_ZL]; case HF_CTL_L: return [self dropCenter:B_L]; case HF_CTL_ZR: return [self dropCenter:B_ZR]; case HF_CTL_R: return [self dropCenter:B_R];
    case HF_CTL_LS: return [self clickCenter:B_LS]; case HF_CTL_RS: return [self clickCenter:B_RS];
    default: { CGRect r = [self pillRect:c == HF_CTL_PLUS ? B_PLUS : B_MINUS]; return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)); }
    }
}
- (CGFloat)reachOf:(int)c {
    switch (c) {
    case HF_GROUP_STICK: return [self stickR:0] * 1.3; case HF_GROUP_FACE: return self.faceGap + self.faceR * 1.6; case HF_GROUP_DPAD: return self.dpadR * K_DPAD_GRAB;
    case HF_CTL_ZL: return MAX([self dropR:B_ZL] * 1.35, K_MIN_HIT); case HF_CTL_L: return MAX([self dropR:B_L] * 1.35, K_MIN_HIT);
    case HF_CTL_ZR: return MAX([self dropR:B_ZR] * 1.35, K_MIN_HIT); case HF_CTL_R: return MAX([self dropR:B_R] * 1.35, K_MIN_HIT);
    case HF_CTL_LS: return MAX([self clickR:B_LS] * 1.35, K_MIN_HIT); case HF_CTL_RS: return MAX([self clickR:B_RS] * 1.35, K_MIN_HIT);
    default: { CGRect r = [self pillRect:c == HF_CTL_PLUS ? B_PLUS : B_MINUS]; return MAX(r.size.width / 2 + 8 * self.u, K_MIN_HIT); }
    }
}
- (void)editBegan:(NSSet<UITouch *> *)ts {   // the touch picks the nearest control within its reach (hidden ones too, drawn faint); none: the selection goes
    UITouch *t = ts.anyObject; CGPoint p = [t locationInView:self]; CGFloat best = 1; _editGroup = -1;
    for (int c = 0; c < HF_GROUPS; c++) { if (ctlFullOnly(c) && !_full) continue;
        CGFloat d = dist(p, [self centreOf:c]) / [self reachOf:c]; if (d < best) { best = d; _editGroup = c; } }
    _editSel = _editGroup; _editLast = p;
    [self placeEditBar]; [self refresh];
}
- (void)editMoved:(NSSet<UITouch *> *)ts {   // the selected control follows the finger, its centre kept inside the controls region's safe area (from upstream PR #630's clampSelected)
    if (_editGroup < 0) return;
    CGPoint p = [ts.anyObject locationInView:self]; CGFloat u = self.u; if (u <= 0) return;
    CGPoint c = [self centreOf:_editGroup]; CGRect s = CGRectInset(self.safe, 8, 8);
    CGFloat nx = fmin(fmax(c.x + p.x - _editLast.x, CGRectGetMinX(s)), CGRectGetMaxX(s)), ny = fmin(fmax(c.y + p.y - _editLast.y, CGRectGetMinY(s)), CGRectGetMaxY(s));
    hf_posture ps = self.layout.posture; hf_profile pr = self.profile;
    pr.off[_editGroup].dx += (nx - c.x) / u; pr.off[_editGroup].dy += (ny - c.y) / u; _editLast = p;
    _prof[ps] = hf_profile_clamp(pr, HF_MAX_MOVE);
    [self setNeedsLayout]; [self layoutIfNeeded];
}
// Every change is saved at once (the posture's NSUserDefaults key), so leaving the editor any way keeps it
- (void)saveProfile {
    hf_posture ps = self.layout.posture; char buf[HF_PROFILE_TEXT]; hf_profile pr = self.profile; hf_profile_format(&pr, buf, sizeof buf);
    [NSUserDefaults.standardUserDefaults setObject:@(buf) forKey:prof_key(ps)];
}
- (void)editApply:(hf_profile)pr {
    _prof[self.layout.posture] = hf_profile_clamp(pr, HF_MAX_MOVE); [self saveProfile];
    [self placeEditBar]; [self setNeedsLayout];
}
- (void)editResize:(double)d {   // the selected control's size, or with none the three corner groups' common scale
    hf_profile pr = self.profile;
    if (_editSel >= 0) pr.size[_editSel] += d; else pr.scale += d;
    [self editApply:pr];
}
- (void)editSmaller { [self editResize:-0.1]; }
- (void)editLarger { [self editResize:0.1]; }
- (void)editFainter { hf_profile pr = self.profile; pr.alpha -= 0.1; [self editApply:pr]; }
- (void)editBolder { hf_profile pr = self.profile; pr.alpha += 0.1; [self editApply:pr]; }
- (void)editHideShow { if (_editSel < 0) return; hf_profile pr = self.profile; pr.hidden ^= 1u << _editSel; [self editApply:pr]; }
- (void)editResetOne {   // the selected control back to the posture's default place, size and shown
    if (_editSel < 0) return; hf_profile pr = self.profile, d = hf_profile_default(self.layout.posture);
    pr.off[_editSel] = d.off[_editSel]; pr.size[_editSel] = d.size[_editSel]; pr.hidden &= ~(1u << _editSel);
    [self editApply:pr];
}
- (void)editReset {
    hf_posture ps = self.layout.posture; _prof[ps] = hf_profile_default(ps); [NSUserDefaults.standardUserDefaults removeObjectForKey:prof_key(ps)];
    LOG("front end: layout editor reset %s to the default", hf_posture_name(ps)); [self placeEditBar]; [self setNeedsLayout];
}
- (void)editDone {
    if (!_editing) return;
    hf_posture ps = self.layout.posture; char buf[HF_PROFILE_TEXT]; hf_profile pr = self.profile; hf_profile_format(&pr, buf, sizeof buf);
    [self saveProfile];
    LOG("front end: layout editor saved %s: %s", hf_posture_name(ps), buf);
    _editing = NO; _editGroup = _editSel = -1; [_editBar removeFromSuperview]; [_editHint removeFromSuperview]; _editBar = nil; _editHint = nil; _editHide = nil; _editKey.hidden = _tap || self.zones; _exitKey.hidden = _tap;
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    if (g_ab_xbox && !dm_pad_labelled(g.controller)) m = (m & ~(uint64_t)(DM_BTN_A | DM_BTN_B)) | (m & DM_BTN_A ? DM_BTN_B : 0) | (m & DM_BTN_B ? DM_BTN_A : 0);   // DM_PAD_AB=xbox: A at the bottom, B on the right (a Nintendo pad keeps its labels)
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{   // the touch gamepad hides while any controller is in use; its editor closes, saved (from upstream PR #630)
        if (any) [self editDone];
        self->_padOff = any; self->_controls.hidden = any; [self reset]; });
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_set_insets(UIView *v, UIEdgeInsets i) { [(DmGamepad *)v setPadInsets:i]; }   // front_ios.m: the safe area in the pad's own (possibly upside-down) coordinates
void dm_gamepad_set_turned(int turned) { atomic_store(&g_stage_turned, turned); }   // front_ios.m: the stage, and so the pad, turned upside down by the app
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
