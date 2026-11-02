# Foldable phones

The design in full, in Simplified Chinese: [foldable.zh-CN.md](foldable.zh-CN.md).

HalfoldKit (`dm/ios/Sources/Halfold/hf_kit.{h,c}`) is plain C with no Apple framework, tested on the Mac (`halfold/tests`). The iOS front end (`front_ios.m`, `DmGamepad.m`) feeds it the window, the safe area, the hinge and gravity, and lays out what it returns.

- **Postures.** Open landscape: the picture fills the screen, the controls over it. Open portrait: the picture on the upper half, the controls on the lower half. Half folded: the picture on the standing half, the controls on the flat half. Closed: the outer screen's own layouts.
- **The fold.** UIKit's division region (iOS 27.1) gives where the fold is; nothing is drawn on it and no control sits across it.
- **Upside down.** Where the system does not turn an app to upside-down portrait, the stage holding the picture and the controls turns itself half a turn, judged from gravity in the window's frame; the touch and motion controls follow.
- **Controls.** A per-control layout editor (size, position, opacity, hidden) kept per posture.
