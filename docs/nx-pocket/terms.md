# NX Pocket terms

The words NX Pocket (the iPhone app) and NX Pocket for Mac use, in English and in Simplified Chinese. The apps' text follows this list (`dm/ios/Sources/LauncherRow.swift`, the `zh` table), and so do the user documents. One idea, one word: a word used here is not swapped for another one elsewhere.

## Things

| English | 简体中文 | Meaning |
|---|---|---|
| NX Pocket | NX Pocket | The iPhone app that plays game packs. Not translated. |
| NX Pocket for Mac | NX Pocket for Mac | The Mac app that makes game packs and sends them. Not translated. |
| game pack | 游戏包 | One game ready for NX Pocket: a single `.nxpack` file (format 3), or an older `.nxpack` folder (formats 1 and 2). Not "package" or "bundle". |
| game files | 游戏文件 | The player's own NSP / XCI / NSZ / XCZ files a pack is made from. |
| game data | 游戏数据 | The game's RomFS inside a pack (`romfs.img`). |
| base game | 本体 | The game without its update (title ID ending in 000). |
| update | 更新 | A game update (title ID ending in 800). |
| DLC | DLC | Add-on content. |
| library | 游戏库 | The games in NX Pocket. |
| game library (code) | 游戏库（程序库） | A pack's `Game.framework`; say "the game's library" when the code is meant, to keep it apart from the list of games. |
| build files | 构建文件 | What making a pack leaves in `<title ID>_build`, reused by the next build. |
| Mac version | Mac 版 | A game made for this Mac (nxnative's Mac app of it: settings window, keyboard, controllers), kept in its build files. Not a game pack. |
| game profile | 游戏配置 | nxnative's `dm/games/<title ID>` folder for a game. |
| prod.keys | prod.keys | The player's own console keys. Not translated. |
| developer certificate | 开发者证书 | The `.p12` NX Pocket signs packs with on the iPhone. |
| team / team ID | 开发者团队 / 团队 ID | The Apple developer team that signs NX Pocket and packs. |
| environment script | 环境脚本 | The shell script that sets up tools kept elsewhere. |
| upstream nxnative | 上游 nxnative | seedds/nxnative, the project NX Pocket is based on. |
| commit | 提交 | A git commit. |

## Actions

| English | 简体中文 | Where |
|---|---|---|
| Add Game | 添加游戏 | Mac: add a game's folder or files. |
| Make Game Pack | 制作游戏包 | Mac: build a pack from the game files. |
| Make Again | 重新制作 | Mac: build an existing pack again. |
| Continue | 继续 | Mac: carry on a stopped build from its last finished stage. |
| Send to iPhone | 发送到 iPhone | Mac: copy a pack into NX Pocket over the cable. |
| Send Again | 再次发送 | Mac. |
| AirDrop | 隔空投送 | Mac: send a pack with AirDrop. |
| Export | 导出 | Mac: copy a pack to a folder. |
| Import Game Pack | 导入游戏包 | iPhone: add a pack from Files, AirDrop or a drive. |
| Use in Place | 原地使用 | iPhone: keep the pack where it is (a link), no copy. |
| Copy to NX Pocket | 拷贝到 NX Pocket | iPhone: store a copy of the pack in NX Pocket. |
| Play | 开始游戏 | iPhone. |
| Resume | 继续游戏 | iPhone: back to the paused game. |
| Close | 关闭游戏 | iPhone: end the paused game. A Mac sheet is dismissed with Done (完成), not Close. |
| Home | 主页 | The pill in a game that pauses it and shows NX Pocket's home screen. |
| Edit | 编辑 | The pill in a game that edits the touch controls. |
| Delete Game Pack | 删除游戏包 | iPhone and Mac. |
| Install NX Pocket / Update | 安装 NX Pocket / 更新 | Mac: build NX Pocket and install it on the iPhone. |
| Check for Updates | 检查更新 | Mac: NX Pocket for Mac's own updates. |
| Report a Problem | 问题报告 | Mac: make a zip of logs and settings for a bug report. |
| Play on Mac | 在 Mac 上玩 | Mac: play the game on this Mac, from its Mac version (made the first time). |

## States and checks

| English | 简体中文 | Meaning |
|---|---|---|
| quick check | 快速检查 | A pack's size, end marker, table of contents and small parts checked against their checksums. |
| full check | 完整校验 | Every part of a pack checked, game data included. "Full Check" in Settings. |
| checksum | 校验值 | SHA-256 of a part. |
| signature | 签名 | A code signature (packs) or an Ed25519 signature (NX Pocket for Mac's updates). |
| sign / signed / unsigned | 签名 / 已签名 / 未签名 | |
| unpack | 解出 | Take a pack's small parts out of its file, once, on the iPhone. |
| newer version available, still playable | 有新版本，可继续使用 | A pack made from older code than the checkout's, where what a pack is made of changed (or its shader chain did). It plays as made; making it again brings the change in. Said quietly, not as a fault. |
| shader chain | 着色器版本 | The shader translation chain the host is compiled with (`dm/gfx/nvn/dmsh_chain.h`). A new one means a game's shaders are compiled again before its pack is made again. |
| queued | 排队中 | Mac: waiting to be made. |
| Tested / In progress / No profile | 已测试 / 还在调 / 没有配置 | Mac: what nxnative's profiles say of a game. |
| local play | 本地联机 | A game's local wireless mode over Wi-Fi. |
| cloud saves | 云存档 | Saves synced through an iCloud Drive folder. |
| paused | 已暂停 | A game under NX Pocket's home screen. |

## Style

- Buttons start with a verb and use title case (Make Game Pack, Send to iPhone); in Chinese, a verb phrase (制作游戏包, 发送到 iPhone).
- Messages are sentences, plain and short; say what happened and what to do next.
- American English spelling (center, color).
- Product names are not translated: NX Pocket, nxnative, NX Play, iPhone, Mac, AirDrop in English text; 隔空投送 in Chinese.
- Nintendo's names only where they describe the player's own files or the disclaimer; never in the app's name or icon.
