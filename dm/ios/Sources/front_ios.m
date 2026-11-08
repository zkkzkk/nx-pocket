// iOS front end (the iOS implementation of front.h): a centered 16:9 Metal view (black bars on both sides) + a full-screen virtual gamepad layer (DmGamepad.m, controls drawn over the picture);
// with a TV connected the Metal view is on the TV and the phone shows the pad (DmTVSceneDelegate).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMotion/CoreMotion.h>
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "haptics_apple.h"
#include "save_sync.h"
#import "CloudSaves.h"
#include <stdatomic.h>
#include "Halfold/hf_kit.h"

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_set_insets(UIView *pad, UIEdgeInsets insets);
void dm_gamepad_set_turned(int turned);
void dm_gamepad_reset(void);
void dm_gamepad_active(void);
void front_ios_boot(void);
int front_ios_boot_ok(void);
const char *front_ios_boot_message(void);   // main.m: why a build that keeps the game files off the IPA found none usable (NULL = the generic hint)
const char *front_ios_device_check(void);   // main.m: why this device cannot run the games (its GPU has no BC textures; NULL = supported); makes the first Metal device
#if DM_PACK   // a game pack: NX Pocket showed the launcher before it loaded the pack, and the settings are in the environment
static bool dm_show_launcher(void *view_controller, void (*done)(void)) { (void)view_controller; (void)done; return false; }
#else
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)
#endif

static CAMetalLayer *g_layer;
static void front_ios_notify_setup(void);
static void front_ios_notify_ask(void);
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);

// Halfold (Sources/Halfold/hf_kit.h, docs/nx-pocket/foldable.zh-CN.md): the posture from the window and the hinge, and the regions of the picture and the controls. Landscape: both are the whole
// window. Portrait: the picture above the screen's middle, the controls below (the iPhone Duo's inner screen folds across its middle when held upright). Tabletop: the hinge
// partly open, the controls below the hinge band. g_hinge is the hinge status (UIHingeStatus, 0 until the hinge interaction reports)
static _Atomic int g_hinge;
// The fold's real place: UIKit's division region (iOS 27.1), in the stage's coordinates, read by DmRootVC viewDidLayoutSubviews on the main thread (where the pad lays out too);
// none known: the window's middle (hf_layout_make_at). From upstream PR #683
static hf_rect g_division; static int g_have_division;
// Without a hinge across the screen (outer screen, ordinary iPhone) the fit mode's picture sits at the top at its own ratio, so no black bar is left above it
hf_layout front_ios_layout(CGRect b, UIEdgeInsets safe) {
    int hinge = atomic_load(&g_hinge); double aspect = hf_fill_parse(getenv("DM_FIT")) == HF_FIT ? 16.0 / 9 : 0;
    return hf_layout_make_at(hf_posture_of(b.size.width, b.size.height, hinge), b.size.width, b.size.height, (hf_insets){safe.top, safe.left, safe.bottom, safe.right}, hinge, aspect,
                             g_have_division ? &g_division : 0);
}

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)didMoveToWindow {   // the phone's screen or a TV's (DmTVSceneDelegate): render at that screen's pixels
    [super didMoveToWindow];
    UIScreen *s = self.window.windowScene.screen; if (!s) return;
    self.layer.contentsScale = s.nativeScale; [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end
static CGRect fit_16_9(CGRect b) {   // the largest centered 16:9 rectangle in b
    CGFloat w = b.size.width, h = b.size.height;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    return CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
}
static void tv_attach(void);

// The root view reads the division regions in updateConstraints: that registers it for UIKit's invalidation, so a fold that moves (another screen, the hinge opening) lays the
// view out again (from upstream PR #683)
@interface DmRootView : UIView
@end
@implementation DmRootView
+ (BOOL)requiresConstraintBasedLayout { return YES; }
- (void)updateConstraints {
    if (@available(iOS 27.1, *)) { [self reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]; [self setNeedsLayout]; }
    [super updateConstraints];
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) UIView *stage;   // holds the game view, the pad and the counter; turned upside down when the phone is but the interface is not (deviceTurned)
@property (nonatomic, copy) NSString *offsetKey;   // deviceTurned without turnMotion: the screen (native size) whose gravity offset _turn holds
@property (nonatomic, strong) NSTimer *turnTimer;
@property (nonatomic, strong) CMMotionManager *turnMotion;   // deviceTurned: gravity in the root view's frame (iOS 27), nil where there is none (then gravity and calibration)
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic) BOOL launched;
@property (nonatomic, strong) id tv;   // the TV scene accessory's registration (iOS 27)
- (void)startGame;
@end
static DmRootVC *g_root;
#if DM_PACK
static void exit_after_env(void);   // NX Pocket's DM_EXIT_AFTER / DM_HOME_AFTER (below, with Home and Exit)
#endif
static void launcher_done(void) { [g_root startGame]; }
@implementation DmRootVC { hf_flip _turn; }   // the upside-down check (deviceTurned)
- (void)loadView { self.view = [DmRootView new]; }
- (void)showHint:(NSString *)text {   // why the game cannot start, centered over the black screen
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
    lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
    lb.text = text; [self.view addSubview:lb];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    front_ios_power_watch();
    front_ios_notify_setup();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        const char *why = front_ios_boot_message();
        [self showHint:why ? [NSString stringWithFormat:@"Game files unusable.\n%s", why] : @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart."]; return;
    }
    front_ios_audio_watch();
#if defined(__IPHONE_27_0)   // compiled only with an SDK that has the scene accessory API
    if (@available(iOS 27.0, *)) {   // iOS 27 offers a TV scene only to a registered scene accessory, no longer from the Info.plist entry alone (that path stays for iOS 26)
        UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"TV" sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
        c.delegateClass = NSClassFromString(@"DmTVSceneDelegate");
        self.tv = [self registerSceneAccessory:[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:c]];
    }
#endif
}
// The game view, the pad and the frame-rate counter are made once the launcher has set the switches they read (DM_SHOW_FPS, DM_METAL_HUD); the host's loading began at app launch (main.m)
- (void)startGame {
    if (self.game) return;
#if DM_PACK
    exit_after_env();
#endif
    dm_cloud_saves_env();   // DM_SAVE_SYNC from the launcher's Cloud saves pick, before the game's first save mount reads it (CloudSaves.m, save_sync.h)
    front_hud_env();   // before the process's first Metal device, which reads MTL_HUD_ENABLED (an env file's DM_METAL_HUD sets it in main.m already; GitHub issue #840)
    const char *dev = front_ios_device_check();   // that first device: a GPU without BC textures is refused here, not at launch, so the launcher's HUD switch counts
    if (dev) { [self showHint:[NSString stringWithFormat:@"This device is not supported.\n%s", dev]]; return; }   // the host does not start
    self.stage = [[UIView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.stage];
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.stage addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
    dm_haptics_apple_init();
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.stage addSubview:self.pad];
    self.fps = front_ios_fps_label();   // above the pad, which hides while a controller is connected
    if (self.fps) [self.stage addSubview:self.fps];
    [self turnStart];
    [self hingeWatch];
    self.turnTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { (void)t; [self deviceTurned]; }];   // the upside-down check (deviceTurned)
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    tv_attach();   // a TV connected while the launcher showed
    front_ios_boot();
}
// Portrait either way up. iOS never gave this app an upside-down interface on the iPhone Duo (iOS 27.1 and 27.2, iOS 27.1 SDK: the home screen turns, the app does not), and
// UIDevice's orientation there is a quarter turn off the inner screen and reads face up while the phone is held tilted, so the stage turns itself by HalfoldKit's rule
// (hf_flip_update, docs/nx-pocket/foldable.zh-CN.md 3.3): half a turn when the interface is portrait and the picture is upside down, never when iOS turned the interface itself (upside down
// or landscape). Which way is down for the picture: on iOS 27 Core Motion's gravity in the root view's frame (deviceMotionBody; the root view is the one the app never turns,
// the stage is turned inside it), so whatever iOS did with the screen is already in it and nothing is calibrated. Elsewhere the accelerometer (DmGamepad.m dm_gravity) in the
// device's own axes, whose offset from the interface is taken from the first held portrait reading after the game starts, or after the window moves to the other screen,
// counted as upright: on a 27.2 Duo that reading was once taken held by the other end, and every later reading came out turned (picture upside down held upright). Each
// change is logged
int dm_gravity(double g[3]);
- (void)turnStart {
    CMMotionManager *m = [CMMotionManager new];
    if (@available(iOS 27.0, *)) {
        if (m.deviceMotionAvailable) {
            m.deviceMotionUpdateInterval = 0.1; m.deviceMotionBody = self.view; [m startDeviceMotionUpdates]; self.turnMotion = m;   // read in deviceTurned (no handler)
            hf_flip_init(&_turn, 0);   // the picture's own frame: upright is gravity straight down, no offset to learn
            LOG("front end: upside-down check from gravity in the window's frame (deviceMotionBody), nothing calibrated"); return;
        }
    }
    hf_flip_init(&_turn, -1);
    LOG("front end: upside-down check from the accelerometer, the first portrait reading taken as upright");
}
static int quarter_of_interface(UIInterfaceOrientation io) {   // hf_kit.h's turns: interface landscape right is device landscape left
    switch (io) { case UIInterfaceOrientationPortrait: return 0; case UIInterfaceOrientationLandscapeRight: return 1;
                  case UIInterfaceOrientationPortraitUpsideDown: return 2; case UIInterfaceOrientationLandscapeLeft: return 3; default: return -1; }
}
- (void)deviceTurned {
    UIWindowScene *ws = self.view.window.windowScene; if (!ws) return;
    int iq = quarter_of_interface(ws.effectiveGeometry.interfaceOrientation), bq;
    double g[3];
    if (self.turnMotion) {   // gravity in the picture's frame, given to hf_flip_update as if in the device's (its quarter plus the interface's) with offset 0
        CMDeviceMotion *d = self.turnMotion.deviceMotion; if (!d) return;
        g[0] = d.gravity.x; g[1] = d.gravity.y; g[2] = d.gravity.z;
        int pq = hf_quarter_of_gravity(g[0], g[1]);
        bq = pq < 0 || iq < 0 ? -1 : (pq + iq) % 4;
    } else {
        if (!dm_gravity(g)) return;
        CGRect nb = ws.screen.nativeBounds; NSString *key = [NSString stringWithFormat:@"%.0fx%.0f", nb.size.width, nb.size.height];
        if (![key isEqualToString:self.offsetKey]) {   // another screen (folded / unfolded): measure its offset again, the current turn kept
            self.offsetKey = key; int was = _turn.flipped; hf_flip_init(&_turn, -1); _turn.flipped = was;
        }
        bq = hf_quarter_of_gravity(g[0], g[1]);
    }
    int r = hf_flip_update(&_turn, bq, iq, CACurrentMediaTime());
    if (r & HF_FLIP_OFFSET_FIRST) LOG("front end: gravity offset %d quarter turns on the %s screen (first portrait reading taken as upright)", _turn.offset, self.offsetKey.UTF8String);
    if (!(r & HF_FLIP_CHANGED)) return;
    LOG("front end: phone held %s in portrait (gravity %.2f %.2f %.2f) → picture turned %s", _turn.flipped ? "by its other end" : "upright", g[0], g[1], g[2], _turn.flipped ? "by the app" : "back");
    [self.view setNeedsLayout];
}
// Tabletop: the hinge status from UIHingeInteraction (iOS 27.1). A status change re-lays the picture and the pad (front_ios_layout picks the posture); angle-only updates are ignored
- (void)hingeWatch {
    if (@available(iOS 27.1, *)) {
        __weak DmRootVC *weak = self;
        UIHingeInteraction *hi = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *i, UIHingeInteractionUpdate *u) {
            (void)i; int st = u.hinge ? (int)u.hinge.status : 0;
            if (atomic_exchange(&g_hinge, st) == st) return;
            static const char *names[] = {"unknown", "closed", "partially open", "fully open"};
            LOG("front end: hinge %s (%.0f degrees)", st >= 0 && st <= 3 ? names[st] : "?", u.hinge ? u.hinge.angle * 180 / M_PI : 0.0);
            DmRootVC *me = weak; [me.view setNeedsLayout]; [me.pad setNeedsLayout];
        }];
        [self.view addInteraction:hi];
        LOG("front end: hinge interaction on (tabletop layout when partially open in portrait)");
    }
}
// The first division region that is a fold across the window, turned into the stage's coordinates (half a turn when the stage is upside down); a change re-lays the pad
- (void)readDivision:(CGRect)b {
    int have = 0; hf_rect d = {0, 0, 0, 0};
    if (@available(iOS 27.1, *)) {
        for (UIViewReservedRegion *r in [self.view reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
            CGRect f = r.frame;
            if (_turn.flipped) f = CGRectMake(b.size.width - CGRectGetMaxX(f), b.size.height - CGRectGetMaxY(f), f.size.width, f.size.height);
            if (hf_division_of(b.size.width, b.size.height, (hf_rect){f.origin.x, f.origin.y, f.size.width, f.size.height}, &d)) { have = 1; break; }
        }
    }
    if (have == g_have_division && (!have || !memcmp(&d, &g_division, sizeof d))) return;
    g_have_division = have; g_division = d; [self.pad setNeedsLayout];
    if (have) LOG("front end: fold at %.0f,%.0f %.0fx%.0f (division region)", d.x, d.y, d.w, d.h); else LOG("front end: no division region: the fold is taken at the window's middle");
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.game) return;
    self.stage.transform = CGAffineTransformIdentity; self.stage.frame = self.view.bounds;
    self.stage.transform = _turn.flipped ? CGAffineTransformMakeRotation(M_PI) : CGAffineTransformIdentity;
    CGRect b = self.stage.bounds;
    UIEdgeInsets si = self.view.safeAreaInsets;
    if (_turn.flipped) si = UIEdgeInsetsMake(si.bottom, si.right, si.top, si.left);   // the safe area in the stage's turned coordinates
    dm_gamepad_set_insets(self.pad, si); dm_gamepad_set_turned(_turn.flipped);
    [self readDivision:b];
    hf_layout L = front_ios_layout(b, si);   // the picture's and the controls' regions for the posture
    static int last_posture = -1; static CGSize last_size;
    if ((int)L.posture != last_posture || !CGSizeEqualToSize(last_size, b.size)) { last_posture = L.posture; last_size = b.size;
        LOG("front end: posture %s, window %.0fx%.0f, picture region %.0f,%.0f %.0fx%.0f, controls region %.0f,%.0f %.0fx%.0f", hf_posture_name(L.posture), b.size.width, b.size.height,
            L.picture.x, L.picture.y, L.picture.w, L.picture.h, L.controls.x, L.controls.y, L.controls.w, L.controls.h); }
    hf_rect v = hf_view_frame(L.picture, 16.0 / 9, hf_fill_parse(getenv("DM_FIT")));   // fit: 16:9 inside the region; DM_FIT=stretch / crop (the launcher's fill mode): the whole region, the present fills it (nvn_mtl.m present_fit_mode)
    if (self.game.superview == self.stage) self.game.frame = CGRectMake(v.x, v.y, v.w, v.h);   // on a TV the TV's view lays it out
    if (self.fps && L.posture != HF_LANDSCAPE)   // portrait / tabletop: the picture region's top-left corner (the controls' top row is full on a narrow screen: it covered − on the Duo's outer screen)
        self.fps.frame = CGRectMake(floor(L.picture.x + 6), floor(L.picture.y + 6), 64, 22);
    else if (self.fps) {   // landscape: the top row's free stretch: right of DmGamepad.m's L3 key (102 + 17 of its units from the safe edge), level with − / + (22 units down); u is its unit
        CGRect c = CGRectMake(L.controls.x, L.controls.y, L.controls.w, L.controls.h);
        CGRect s = UIEdgeInsetsInsetRect(c, UIEdgeInsetsMake(L.controls_insets.top, L.controls_insets.left, L.controls_insets.bottom, L.controls_insets.right)); CGFloat u = MIN(c.size.height / 430.0, 1.3);
        self.fps.frame = CGRectMake(floor(CGRectGetMinX(s) + 130 * u), floor(CGRectGetMinY(s) + 22 * u - 11), 64, 22);
    }
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    if (!front_ios_boot_ok() && front_ios_boot_message() && !self.presentedViewController) {   // a slim build whose game file image is missing or another version (main.m)
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game files" message:@(front_ios_boot_message()) preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
    if (self.launched || !front_ios_boot_ok()) return;
    self.launched = YES; g_root = self;
    if (!dm_show_launcher((__bridge void *)self, launcher_done)) [self startGame];   // the settings screen first (Launcher.swift), when the app has one
    front_ios_notify_ask();
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }   // portrait either way up (a foldable is held by either end): picture above, controls below (front_ios_layout)
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

// A TV (cable or AirPlay): iOS gives the app the TV as a scene of its own instead of mirroring the phone. The game's view moves there, 16:9 fills the TV, and the game is
// docked as a Switch on its dock (1080p, the operation mode change notification); the phone keeps the pad. Unplugging puts the view back and the mode the game had before
@interface DmTVVC : UIViewController
@end
@implementation DmTVVC
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; for (UIView *v in self.view.subviews) v.frame = fit_16_9(self.view.bounds); }
@end
static UIWindow *g_tv; static int g_tv_mode_was = -1;
static void tv_attach(void) {
    DmGameView *v = g_root.game; if (!g_tv || !v || v.superview == g_tv.rootViewController.view) return;
    [g_tv.rootViewController.view addSubview:v]; [g_tv.rootViewController.view setNeedsLayout];
    // at most 1080p: the game renders 1080p docked, and a 4K drawable only adds an upscale and a 4K stream (an AirPlay TV showed black, the GPU went from 15 to 60 ms a frame).
    // Taken from the 16:9 picture, not the screen, so a display of another shape still gets the full 1920 pixels across the picture
    CGRect f = fit_16_9(g_tv.bounds);
    v.layer.contentsScale = MIN(v.layer.contentsScale, 1920.0 / MAX(f.size.width, 1)); [v setNeedsLayout];
    if (g_tv_mode_was < 0) g_tv_mode_was = dm_opmode();
    dm_set_opmode(1);
    LOG("front end: TV connected (%.0fx%.0f points), the picture moves there at %.0fx%.0f, console mode", g_tv.bounds.size.width, g_tv.bounds.size.height, f.size.width * v.layer.contentsScale, f.size.height * v.layer.contentsScale);
}
static void tv_detach(void) {
    DmGameView *v = g_root.game; g_tv = nil;
    if (v && v.superview != g_root.stage) { [g_root.stage insertSubview:v atIndex:0]; [g_root.view setNeedsLayout]; }   // back under the pad in the stage
    if (g_tv_mode_was >= 0) { dm_set_opmode(g_tv_mode_was); g_tv_mode_was = -1; }
    LOG("front end: TV disconnected, the picture is back on the phone");
}
@interface DmTVSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation DmTVSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [DmTVVC new];
    self.window.hidden = NO;   // without a window iOS goes on mirroring the phone; not key, so the phone's window keeps the keyboard
    g_tv = self.window; tv_attach();
}
- (void)sceneDidDisconnect:(UIScene *)s { if (g_tv == self.window) tv_detach(); self.window = nil; }
@end

// Thermal state and screen brightness for the power and present rows every 300 frames (hle_nvn.c; its weak defaults return -1 on the Mac). thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
// Brightness is read on the main thread at start and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
static void front_ios_power_watch(void) {
    g_brightness = UIScreen.mainScreen.brightness;
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_brightness = UIScreen.mainScreen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
}

// Frame-rate counter: the frames put on screen in the last second (nvn_mtl.m counts them for NVN and for the Vulkan layer alike; frames the display link merged away are not counted).
// Offline HTML pages (web_apple.m): the page's view goes over the game view and under the gamepad, which lets touches on no control through to it while the page is
// shown (DmGamepad.m hitTest); the page takes them as a click on what they land on, and the gamepad and controllers drive it as on the Switch
void front_web_attach(UIView *box) {
    UIView *v = g_root.game && g_root.game.superview == g_root.stage ? g_root.stage : g_root.view; box.frame = v.bounds;   // in the stage, so it turns with the picture (deviceTurned)
    if (g_root.game.superview == v) [v insertSubview:box aboveSubview:g_root.game]; else [v addSubview:box];
}
void front_web_detach(UIView *box) { (void)box; }
// An app of several programs (main.m: dm/programs.txt; DM_EXEC_OUT is set only there). iOS cannot start the app's process again, so oe::ExecuteProgram records the next program and the
// app ends (hle_oe.c); the next start runs it. To spare the player a silent quit, the app names the program on screen for 1.5 s, then schedules a local notification 1 s ahead that
// opens the app again ("Tap to start …"), then ends. Notifications are asked for at the first start of such an app; a player who refuses gets the plain quit
static int multi_program(void) { const char *e = getenv("DM_EXEC_OUT"); return e && *e; }
@interface DmNotifyDelegate : NSObject <UNUserNotificationCenterDelegate>
@end
@implementation DmNotifyDelegate
// The notification can come due before the graceful exit has ended the process: show it anyway, so it waits in the notification centre once the app is gone
- (void)userNotificationCenter:(UNUserNotificationCenter *)c willPresentNotification:(UNNotification *)n withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
    (void)c; (void)n; done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}
@end
static DmNotifyDelegate *g_notify_delegate;
static void front_ios_notify_setup(void) {   // at each start: the delegate, and no notification left from an earlier hand-off (the app is open now)
    if (!multi_program()) return;
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    g_notify_delegate = [DmNotifyDelegate new]; c.delegate = g_notify_delegate;
    [c removeAllPendingNotificationRequests]; [c removeAllDeliveredNotifications];
}
static void front_ios_notify_ask(void) {   // iOS asks the player only while the choice is not made, so this shows a prompt at the first start alone
    if (!multi_program()) return;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *e) {
        LOG("front end: notifications %s%s%s", granted ? "allowed" : "not allowed", e ? ": " : "", e ? e.localizedDescription.UTF8String : ""); }];
}
static int notify_allowed(void) {
    __block UNAuthorizationStatus st = UNAuthorizationStatusNotDetermined; dispatch_semaphore_t got = dispatch_semaphore_create(0);
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *t) { st = t.authorizationStatus; dispatch_semaphore_signal(got); }];
    if (dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))) return 0;
    return st == UNAuthorizationStatusAuthorized || st == UNAuthorizationStatusProvisional || st == UNAuthorizationStatusEphemeral;
}
void front_program_handoff(int index, const char *name) {   // front.h; on the guest thread that called oe::ExecuteProgram, before the graceful exit
    if (!multi_program() || !notify_allowed()) { LOG("front end: program %d starts at the next start of the app (notifications not allowed)", index); return; }
    NSString *nm = name && *name ? @(name) : [NSString stringWithFormat:@"program %d", index];
    dm_audio_suspend(1);   // the game is ending: no sound under the notice
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = g_root.view.window; if (!w) return;
        UIView *o = [[UIView alloc] initWithFrame:w.bounds]; o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        o.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(o.bounds, 40, 0)]; lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold]; lb.text = [NSString stringWithFormat:@"Starting %@\u2026", nm];
        [o addSubview:lb]; [w addSubview:o];
    });
    usleep(1500 * 1000);
    UNMutableNotificationContent *c = [UNMutableNotificationContent new]; c.body = [NSString stringWithFormat:@"Tap to start %@", nm];
    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:@"dm.program" content:c trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1.0 repeats:NO]];
    __block NSError *err = nil; dispatch_semaphore_t added = dispatch_semaphore_create(0);
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:r withCompletionHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(added); }];
    if (dispatch_semaphore_wait(added, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) LOG("[RED] front end: the notification for program %d was not scheduled within 2 s", index);
    else if (err) LOG("[RED] front end: the notification for program %d could not be scheduled: %s", index, err.localizedDescription.UTF8String);
    else LOG("front end: \"Starting %s\" shown, notification for program %d scheduled", nm.UTF8String, index);
}
// On when the IPA was built with it (the NSP script's SHOW_FPS / --show-fps → DMShowFPS in Info.plist; showFPS in a pack's pack.json); DM_SHOW_FPS=0 / 1 in Documents/env.txt overrides that without a rebuild. NULL when off
uint64_t mtl_present_count(void);
BOOL front_ios_show_fps_default(void);   // main.m: DMShowFPS in Info.plist, or the pack's pack.json
static UILabel *front_ios_fps_label(void) {
    const char *e = getenv("DM_SHOW_FPS");
    if (!(e ? atoi(e) != 0 : front_ios_show_fps_default())) return nil;
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor; l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; l.layer.cornerRadius = 6; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
    l.text = @"-- fps";
    __block uint64_t n0 = mtl_present_count(); __block double t0 = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t; uint64_t n = mtl_present_count(); double now = CACurrentMediaTime();
        if (now - t0 < 1.5) l.text = [NSString stringWithFormat:@"%.0f fps", (n - n0) / (now - t0)];   // a longer span is the time in the background: no reading
        n0 = n; t0 = now;
    }];
    LOG("front end: frame-rate counter on");
    return l;
}

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UIView *g_prog; static UILabel *g_prog_count; static UIProgressView *g_prog_bar; static UILabel *g_prog_title;
void (*front_progress_hook)(const char *title, long done, long total);
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    void (*hook)(const char *, long, long) = front_progress_hook;
    if (hook) { dispatch_async(dispatch_get_main_queue(), ^{ hook(tt.UTF8String, done, total); }); return; }   // the host app draws it (front.h)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            UIView *root = g_root.view; if (!root) return;
            g_prog = [[UIView alloc] initWithFrame:root.bounds]; g_prog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_prog.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floor((root.bounds.size.width - 320) / 2), floor((root.bounds.size.height - 96) / 2), 320, 96)];
            box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            g_prog_title = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 320, 30)]; g_prog_title.textAlignment = NSTextAlignmentCenter; g_prog_title.textColor = UIColor.whiteColor;
            g_prog_title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            g_prog_bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; g_prog_bar.frame = CGRectMake(20, 48, 280, 4);
            g_prog_count = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 320, 22)]; g_prog_count.textAlignment = NSTextAlignmentCenter;
            g_prog_count.textColor = [UIColor colorWithWhite:0.72 alpha:1]; g_prog_count.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [root addSubview:g_prog];
        }
        g_prog_title.text = tt; g_prog_bar.progress = total > 0 ? (float)done / (float)total : 0;
        g_prog_count.text = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                             [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
int front_display_pixels(int *w, int *h) {   // the screen in pixels, landscape (nativeBounds is portrait); UIScreen's sizes may be read from any thread
    CGRect b = UIScreen.mainScreen.nativeBounds; int a = (int)b.size.width, c = (int)b.size.height;
    if (a <= 0 || c <= 0) return 0;
    *w = a > c ? a : c; *h = a > c ? c : a; return 1;
}
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    // The guest clock keeps running meanwhile, as on the Switch (hle_swkbd.c): a freeze here as well stopped Octopath Traveler 0's frame loop for as long as the box was up and made its sound stutter
    // (4,977 ms and 2,577 ms frames, 5,181 wakeups a second). The inline keyboard freezes around its own call (hle_swkbd.c)
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game. hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("front end: save data write failed errno=%d, telling the player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("[RED] front end: no window for the save-failure alert errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"Storage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"Saving failed (errno %d); progress was not saved.", err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category is Playback, as a game's or media app's: the ring / silent switch does not mute it (the default SoloAmbient follows the switch, which silenced the game whenever the phone was on silent) and it still interrupts other apps' audio.
// Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms)", s.sampleRate, s.IOBufferDuration * 1000);
}

// Real audio output is suspended (the silent sink paces the game) while the app is in the background or another audio session has interrupted ours (Siri, an alarm, a call).
// Without the interruption observer the AudioUnits stayed "started" while iOS no longer called them, and a game waiting for its buffers back lost its sound until restart.
// All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue], reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) { LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); g_audio_intr = 1; }
        else {
            LOG("audio session: interruption ended"); g_audio_intr = 0;
            if (!g_audio_bg) front_ios_audio_session();
        }
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; LOG("audio session: the media services were reset; setting the session and the outputs up again");
        front_ios_audio_session(); dm_audio_reset();
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
// Cloud saves (save_sync.h): what the game committed goes out before iOS suspends the app, without the sender's quiet wait. iOS gives a background task about half a minute
static void save_sync_background(void) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^end)(void) = ^{ if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } };   // on the main queue, as the expiry handler runs
    task = [app beginBackgroundTaskWithName:@"cloud save" expirationHandler:end];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!save_sync_flush(20000)) LOG("front end: the save did not reach the cloud before the app was suspended; it goes after the next save or at the next start");
        dispatch_async(dispatch_get_main_queue(), end);
    });
}

#if DM_PACK
// NX Pocket, as a Switch's Home button: the Home pill left of − (DmGamepad.m) asks NX Pocket to show its home screen over the game, which it pauses as it would going to the
// background (main.m dm_pack_suspend); Resume there carries on. Closing the game (NX Pocket's Close, or another game's Play) cannot unload a pack's host, so the app starts
// over: the cloud save goes out, NX Pocket asks the system to open itself (LSApplicationWorkspace, as LiveContainer returns to its list) and ends; the system starts it again
@protocol DmWorkspace <NSObject>
+ (id)defaultWorkspace;
- (void)openApplicationWithBundleIdentifier:(NSString *)bundle configuration:(id)configuration completionHandler:(void (^)(BOOL ok, NSError *e))done;
@end
static void (*g_home)(void);   // NX Pocket's: show the home screen (main.m dm_pack_on_home)
void front_ios_set_home(void (*f)(void)) { g_home = f; }
void front_ios_home(void) {   // the Home pill
    if (g_home) { LOG("front end: home (the game pauses)"); g_home(); return; }
    void front_ios_confirm_exit(void); front_ios_confirm_exit();   // an NX Pocket without a home over the game: close it, after asking
}
void front_ios_exit_to_pocket(void) {
    LOG("front end: exit to NX Pocket");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!save_sync_flush(10000)) LOG("front end: the save did not reach the cloud before exit; it goes at the next start");
        Class ws = NSClassFromString(@"LSApplicationWorkspace"), cfg = NSClassFromString(@"_LSOpenConfiguration");
        id<DmWorkspace> w = ws ? [(Class<DmWorkspace>)ws defaultWorkspace] : nil;
        if (![w respondsToSelector:@selector(openApplicationWithBundleIdentifier:configuration:completionHandler:)]) { LOG("[RED] front end: cannot ask to be opened again; NX Pocket just ends"); exit(0); }
        // Two requests, and the app ends as the first is answered: the system takes that one while the app still runs (nothing to do), and the second once it has ended,
        // which starts it again at once (LiveContainer's LCSharedUtils launchToGuestApp). _exit: the host's threads and exit handlers would only delay it
        static _Atomic int answered;
        for (int i = 0; i < 2; i++)
            [w openApplicationWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier configuration:cfg ? [cfg new] : nil completionHandler:^(BOOL ok, NSError *e) {
                if (answered++) return;
                LOG("front end: reopen request %s%s%s; ending", ok ? "accepted" : "refused", e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
                fflush(stderr); _exit(0);
            }];
        sleep(3);
        LOG("[RED] front end: no answer to the reopen request; ending"); fflush(stderr); _exit(0);
    });
}
void front_ios_confirm_exit(void) {
    const char *u = getenv("DM_UI_LANG"), *l = getenv("DM_LANG");   // NX Pocket's Settings › Language first (DmGamepad.m hf_zh)
    BOOL zh = u && *u ? !strncmp(u, "zh", 2) : [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] || (l && !strncmp(l, "zh", 2));
    UIAlertController *a = [UIAlertController alertControllerWithTitle:zh ? @"退出游戏？" : @"Exit the game?"
        message:zh ? @"游戏里还没存档的进度会丢失。退出后回到 NX Pocket 首页。" : @"Progress the game has not saved is lost. NX Pocket starts over on its home screen."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:zh ? @"取消" : @"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:zh ? @"退出" : @"Exit" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x; front_ios_exit_to_pocket(); }]];
    UIViewController *vc = g_root; while (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:a animated:YES completion:nil];
}
// DM_EXIT_AFTER=<seconds> / DM_HOME_AFTER=<seconds> (development): close the game, unasked, or press Home that long after the game starts (tests with no one at the phone)
static void exit_after_env(void) {
    const char *e = getenv("DM_EXIT_AFTER"), *h = getenv("DM_HOME_AFTER"); int s = e ? atoi(e) : 0, hs = h ? atoi(h) : 0;
    if (s > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)s * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ front_ios_exit_to_pocket(); });
    if (hs > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)hs * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ front_ios_home(); });
}
#endif

void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); save_sync_background(); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_gamepad_active(); dm_focus_set(1); break;
    }
}
