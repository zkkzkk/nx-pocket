# Notice

NX Pocket is not affiliated with, authorized or endorsed by Nintendo. Nintendo Switch is a trademark of Nintendo. This repository contains no games, game files or keys.

## Based on

- **nxnative** by seedds, MIT License: https://github.com/seedds/nxnative. NX Pocket is a fork; nxnative's `LICENSE` applies to the whole repository, and its own third-party notices (`dm/third_party`, `docs`) stand as they are.

## Adapted code

- **NX Play** by varyform, MIT License: https://github.com/varyform/nx-native-wrapper. NX Pocket for Mac (`dm/mac/pocket`) adapts its build-progress reading, its tool runner, its device list parsing and its control-data (NACP) reader; the files say which.

## Ideas and ported pull requests

- Touch controls ported from pull requests to nxnative: #634 (A/B layout), #433 (haptics, D-pad diagonals), #500 (left stick anywhere on the left), #258 (swipe camera, camera area, dead zone); the foldable layout editor takes from #630 and #683. Thanks to their authors.
- The Rhythm Heaven Groove touch layout follows the design of [Touchable](https://github.com/MZhao-ouo/Touchable) by MZhao-ouo (the idea only, no code).
- Local play speaks ldn_mitm's LAN protocol.
