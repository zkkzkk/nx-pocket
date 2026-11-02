// The launcher's view of the fold (Launcher.swift's home screen): the hinge status and the fold's place, as front_ios.m reads them for the game (UIHingeInteraction and the
// division region, iOS 27.1). The launcher shows before the game's root view starts watching, so it reads them itself; HalfoldKit (hf_kit.h) turns them into the posture and regions.
#import <UIKit/UIKit.h>

/// A view with no drawing that reports the hinge status (UIHingeStatus: 0 unknown or no hinge, 1 closed, 2 partially open, 3 fully open) and the first division region that is a
/// fold across it (hf_division_of; have = NO: none known, the window's middle), in its own coordinates. Reports on the main thread, once at first and then on each change.
@interface DmFoldProbe : UIView
@property (nonatomic, copy) void (^onChange)(int hinge, BOOL have, CGRect fold);
@end
