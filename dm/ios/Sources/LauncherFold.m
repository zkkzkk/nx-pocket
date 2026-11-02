// See LauncherFold.h.
#import "LauncherFold.h"
#include "Halfold/hf_kit.h"

@implementation DmFoldProbe {
    int _hinge, _have, _sent;
    CGRect _fold;
}
+ (BOOL)requiresConstraintBasedLayout { return YES; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) { self.userInteractionEnabled = NO; self.backgroundColor = UIColor.clearColor; }
    return self;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window || self.interactions.count) return;
    if (@available(iOS 27.1, *)) {
        __weak DmFoldProbe *weak = self;
        [self addInteraction:[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *i, UIHingeInteractionUpdate *u) {
            (void)i; DmFoldProbe *me = weak; if (!me) return;
            int st = u.hinge ? (int)u.hinge.status : 0;
            if (st != me->_hinge) { me->_hinge = st; [me setNeedsUpdateConstraints]; [me setNeedsLayout]; [me report]; }
        }]];
    }
}
// Reading the division regions here registers the view for UIKit's invalidation: a fold that moves (another screen, the hinge opening) asks for constraints again (front_ios.m DmRootView)
- (void)updateConstraints {
    if (@available(iOS 27.1, *)) { [self reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]; [self setNeedsLayout]; }
    [super updateConstraints];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size; int have = 0; hf_rect d = {0, 0, 0, 0};
    if (@available(iOS 27.1, *)) {
        for (UIViewReservedRegion *r in [self reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
            CGRect f = r.frame;
            if (hf_division_of(s.width, s.height, (hf_rect){f.origin.x, f.origin.y, f.size.width, f.size.height}, &d)) { have = 1; break; }
        }
    }
    CGRect fold = have ? CGRectMake(d.x, d.y, d.w, d.h) : CGRectZero;
    if (have == _have && CGRectEqualToRect(fold, _fold)) { if (!_sent) [self report]; return; }
    _have = have; _fold = fold; [self report];
}
- (void)report {
    _sent = 1;
    if (self.onChange) self.onChange(_hinge, _have, _fold);
}
@end
