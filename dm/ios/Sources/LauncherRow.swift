// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI

// The apps' words in Chinese or English (settings.tsv's labels, notes and choices, nacp.py's language names and the launchers' own words): English as written, Chinese
// from the table below. Which one is Settings › Language (appLanguage: "zh-Hans", "en", or none for the system's; AppLanguage), read each time, so a change shows as
// the views draw again. Anything not in the table shows as written
enum AppLanguage {
    static let key = "appLanguage"
    /// The system's choice: its first language, or a game app's packed game language (DM_LANG), Chinese
    static var systemChinese: Bool { (Locale.preferredLanguages.first ?? "").hasPrefix("zh") || (ProcessInfo.processInfo.environment["DM_LANG"] ?? "").hasPrefix("zh") }
    static var chosen: String { UserDefaults.standard.string(forKey: key) ?? "" }
    /// The language code in use: the one chosen, else the system's first
    static var effective: String { chosen.isEmpty ? (Locale.preferredLanguages.first ?? "en") : chosen }
    /// Sets the language: the apps' own words at once; the system's (its menus, its alerts, InfoPlist.strings) from the next launch, through AppleLanguages
    static func choose(_ code: String) {
        let d = UserDefaults.standard
        if code.isEmpty { d.removeObject(forKey: key); d.removeObject(forKey: "AppleLanguages") }
        else { d.set(code, forKey: key); d.set([code], forKey: "AppleLanguages") }
    }
}
var launcherChinese: Bool {
    switch AppLanguage.chosen { case "zh-Hans": return true; case "en": return false; default: return AppLanguage.systemChinese }
}
private let zh: [String: String] = [
    "Game": "游戏", "Controls": "操控", "Performance": "性能",
    "Frame rate": "帧率", "Dynamic resolution": "动态分辨率",
    "Adjusts resolution between 70% and 100% under load. Turn off to keep full resolution for the selected console mode.": "负载高时在 70%～100% 之间调整分辨率。关闭则在所选运行模式下保持完整分辨率。",
    "Render scale": "渲染倍率", "Console mode": "运行模式", "Docked": "主机", "Handheld": "掌机",
    "Upscaling": "画面放大", "Standard": "标准", "Uses more GPU time and can increase heat.": "占用更多 GPU，可能更热。",
    "Screen fill": "画面铺满方式", "Fit": "等比（留黑边）", "Stretch": "拉伸铺满", "Crop": "裁切铺满",
    "Fit keeps the shape with black bars; stretch fills the screen; crop fills it and cuts the sides.": "等比：画面不变形，留黑边；拉伸：铺满但会变形；裁切：铺满不变形，裁掉两侧。",
    "Game language": "游戏语言", "Display mode": "显示方式", "Window": "窗口", "Fullscreen": "全屏", "Frame-rate counter": "帧率显示",
    "Touch feedback": "触控震动", "On press": "按下时", "On press and release": "按下和松开时", "Touch feedback strength": "触控震动强度", "D-pad diagonals": "十字键斜向范围", "Left stick": "左摇杆", "Left-stick dead zone": "左摇杆死区", "Ignore small movements near the centre.": "忽略中心附近的小幅移动。", "Ignore small movements near the center.": "忽略中心附近的小幅移动。", "Swipe camera": "滑动转视角", "Move your finger to turn; the game still limits turning speed.": "手指滑动来转视角；转动速度仍受游戏限制。", "Swipe sensitivity": "滑动灵敏度", "Camera touch area": "视角触控区域", "Right third": "右侧三分之一", "Right half": "右半边", "Used by both camera modes; buttons keep priority.": "两种视角方式都用这个区域；按键优先。", "Fixed": "固定位置", "Anywhere on the left": "左半边任意位置", "Anywhere on the left: the stick centres where the thumb lands on the left half.": "左半边任意位置：拇指落在左半边哪里，摇杆就以哪里为中心。", "Anywhere on the left: the stick centers where your thumb lands on the left half.": "左半边任意位置：拇指落在左半边哪里，摇杆就以哪里为中心。", "A/B buttons": "A/B 键位", "A right / B bottom": "A 在右 / B 在下", "A bottom / B right": "A 在下 / B 在右", "Nintendo (A right / B bottom)": "A 在右 / B 在下", "Xbox / PlayStation (A bottom / B right)": "A 在下 / B 在右", "Game rumble": "游戏震动", "Rumble strength": "震动强度", "Rumble cutoff": "震动下限",
    "Frame buffering": "帧缓冲", "Up to one frame more display latency.": "画面最多多延迟一帧。",
    "Metal 4 pipelines": "Metal 4 管线", "Keeps a pipeline archive; uses more memory.": "保留管线缓存，占用更多内存。",
    "Pipeline prebuild": "预编译管线", "The first start waits a few minutes for it, once.": "第一次启动要等几分钟，只需一次。",
    "Encode thread": "编码线程", "Hold frames when late": "掉帧时保持画面", "Performance HUD": "性能浮层",
    "American English": "英语（美国）", "British English": "英语（英国）", "Japanese": "日语", "French": "法语", "German": "德语",
    "Latin American Spanish": "西班牙语（拉丁美洲）", "Spanish": "西班牙语", "Italian": "意大利语", "Dutch": "荷兰语", "Canadian French": "法语（加拿大）",
    "Portuguese": "葡萄牙语", "Russian": "俄语", "Korean": "韩语", "Traditional Chinese": "繁体中文", "Simplified Chinese": "简体中文", "Brazilian Portuguese": "葡萄牙语（巴西）",
    "Play": "开始游戏", "Version": "版本", "Memory available": "可用内存", "Set by an env file": "由 env 文件设定", "Set at launch": "启动时设定",
    "Reset to tested defaults": "恢复默认设置", "Restores the settings this game was tested with.": "恢复为本游戏经过测试的默认设置。",
    "Cloud saves": "云存档", "Off": "关", "Choose a folder in iCloud Drive…": "选择 iCloud 云盘文件夹…", "Choose a different folder…": "更换文件夹…",
    "Turn off cloud saves": "关闭云存档",
    "Local play": "本地联机", "Local wireless over Wi-Fi": "通过 Wi-Fi 本地联机", "Runs the game's local wireless mode with devices on the same Wi-Fi network.": "通过同一 Wi-Fi 网络与其他设备进行本地无线联机。",
    "Other devices' addresses": "其他设备的地址", "Only when a room is not found on its own: the other devices' IP addresses, separated by commas.": "搜不到房间时才需要：填其他设备的 IP 地址，用逗号分隔。",
    "Player name": "玩家名称", "Shown to the other players. Each device needs its own.": "显示给其他玩家。每台设备用不同的名字。",
    "This device's address": "本机地址", "No Wi-Fi address": "未连接 Wi-Fi", "Not set": "未设置",
    // The home screen (LauncherHome.swift)
    "Game settings": "游戏设置", "Last played %@": "上次游玩：%@", "Not played yet": "尚未游玩", "Local play on": "本地联机已开启", "Local play off": "本地联机未开启",
    "Import game pack": "导入游戏包", "Import": "导入", "Button layout": "按键布局", "Settings": "设置", "My games": "我的游戏", "Back": "返回", "Title ID": "标题号",
    "Kept for this game only.": "仅对本游戏生效。", "This game's settings appear once its pack is imported.": "导入这个游戏包后才有它的设置。",
    "This game does not support local play.": "本游戏不支持本地联机。", "Per-game options are in Game settings.": "各游戏的选项请在「游戏设置」中调整。",
    "To move, resize or hide touch controls, start the game and tap Edit to the right of +. In games started from NX Pocket, Home to the left of − pauses the game and returns here.": "如需移动、缩放或隐藏触屏按键，请在游戏中点按「+」右侧的「编辑」。从 NX Pocket 启动的游戏，点按「−」左侧的「主页」可暂停游戏并返回此处。",
    "OK": "好",
    "No games yet": "还没有游戏", "Cancel": "取消",
                    "Not a game pack (pack.json is missing).": "不是有效的游戏包（缺少 pack.json）。", "pack.json could not be read.": "无法读取 pack.json。",
    "pack.json does not contain a valid title ID.": "pack.json 中没有有效的游戏 ID。",
    "The game library is missing.": "缺少游戏库文件。", "Game data (romfs.img) is missing.": "缺少游戏数据（romfs.img）。",
    "Signed by team %@, which differs from NX Pocket (team %@). Import a developer certificate in Settings to re-sign it on this device.": "签名团队（%@）与 NX Pocket（%@）不一致。在「设置」中导入开发者证书后，可在本机重新签名。",
    "Unsigned. Import a developer certificate in Settings to sign it on this device.": "未签名。在「设置」中导入开发者证书后，可在本机签名。",
    "This pack must be signed on this device. Import a developer certificate in Settings first.": "此游戏包需要在本机签名，请先在「设置」中导入开发者证书。",
    "The certificate cannot be used: %@": "证书不能用：%@", "it has expired": "已过期", "Signing the game's library failed: %@": "签名游戏库失败：%@",
    "Signing %@ for this device…": "正在为本机签名《%@》…", 
    "Signing": "签名", "Developer certificate": "开发者证书", "None": "无", "Team": "团队", "Expires": "过期", "Expired": "已过期", "in %d days (%@)": "%d 天后（%@）",
    "Import certificate (.p12)…": "导入证书（.p12）…", "Replace certificate…": "更换证书…", "Remove certificate": "移除证书",
    "Used to sign game packs on this device. It must be the certificate NX Pocket is signed with, exported as a .p12 with its private key, and is stored in this device's Keychain.": "用于在本机为游戏包签名。须为签署 NX Pocket 所用的证书（含私钥的 .p12），仅保存在本机钥匙串中。",
    "The file could not be read.": "无法读取该文件。",
    "the certificate belongs to team %@, but NX Pocket is signed by team %@. Use the certificate NX Pocket is signed with.": "证书属于团队 %@，而 NX Pocket 由团队 %@ 签名。请使用签署 NX Pocket 的证书。", "Certificate password": "证书密码", "Password": "密码",
    "Certificate imported. Game packs are signed on this device when they start.": "证书已导入，启动游戏时将在本机签名游戏包。",
    "Enter the password set when the .p12 was exported. Leave it empty if none was set.": "请输入导出 .p12 时设置的密码；未设置可留空。",
"Shader libraries (msl/%@) are missing.": "缺少着色器库（msl/%@）。",
    "This pack did not pass its checks. Import it again for details.": "此游戏包未通过校验，重新导入可查看详情。",
    "Removes the link only; the pack stays in its location. Saves and settings are kept.": "仅移除关联，游戏包保留在原位置。存档与设置不受影响。",
    "Deletes the copy stored in NX Pocket. Saves and settings are kept.": "删除 NX Pocket 中保存的副本。存档与设置不受影响。",
    "The game's library could not be loaded. It must be signed by NX Pocket's team.\n\n%@": "游戏库加载失败。它必须由 NX Pocket 同一团队签名。\n\n%@",
    "This library is not a game pack (no dm_pack_start).": "这个库不是游戏包（没有 dm_pack_start）。",
    "Kept for this game only. Changes apply the next time the game starts.": "仅对本游戏生效。更改将在下次启动游戏时应用。",
    "Import Game Pack": "导入游戏包",
    "Package format and game data": "游戏包格式与游戏数据",
    "Code signature": "代码签名",
    "Shader libraries": "着色器库",
    "Use in place keeps the pack where it is, which must stay available. Copying stores a second copy on this device.": "「原位使用」不复制文件，需保持原位置可访问；「复制」会在本机再存一份。",
    "Use in Place": "原位使用",
    "Copy to NX Pocket": "复制到 NX Pocket",
    "Select Pack": "选择游戏包",
    "Select Another": "重新选择",
    "Copying %@…": "正在复制《%@》…",
    "Adding to library…": "正在添加到游戏库…",
    "This app contains a single game. Import game packs in NX Pocket.": "此 App 仅包含一款游戏。如需导入游戏包，请使用 NX Pocket。",
    "Select a game pack (.nxpack) in Files. NX Pocket checks it before adding it to your library.": "从「文件」中选择游戏包（.nxpack 文件夹）。NX Pocket 将先进行校验，通过后加入游戏库。",
    "Paused": "已暂停",
    "Resume": "继续游戏",
    "Close": "关闭游戏",
    "Close %@?": "关闭《%@》？",
    "Progress that has not been saved will be lost.": "未保存的进度将会丢失。",
    "Progress that has not been saved will be lost. %@ starts afterwards.": "未保存的进度将会丢失，随后将启动《%@》。",
    "Close and Start": "关闭并启动",
    "%@ was stopped": "《%@》已停止",
    "The iPhone's storage ran low (%@ GB free), so the game was stopped before it filled up. The game needs at least %@ GB free while it runs. Free up some space, then start it again.": "iPhone 存储空间只剩 %@ GB，为了不把存储写满，游戏已被停止。游戏运行时至少需要 %@ GB 可用空间，请清理一些空间后再启动。",
    "The game used more memory than the iPhone allows, so it was stopped.": "游戏占用的内存超出了 iPhone 允许的上限，已被停止。",
    "Storage Almost Full": "存储空间不足",
    "Only %@ GB is free on this iPhone. A large game keeps part of its memory in storage, and it is stopped when less than 5 GB is free.": "这台 iPhone 只剩 %@ GB 可用空间。大型游戏会把一部分内存放在存储空间里，可用空间少于 5 GB 时游戏会被停止。",
    "Start Anyway": "仍要启动",
    "Use the same iCloud Drive folder as Cloud Saves in the Mac app. Saves are downloaded when a game starts and uploaded after each save; replaced saves are kept in save-backups.": "请选择与 Mac App「云存档」相同的 iCloud 云盘文件夹。游戏启动时下载存档，每次存档后自动上传；被替换的存档保留在 save-backups 中。",
    "Folder saved. It takes effect the next time a game starts.": "已保存，下次启动游戏时生效。",
    "This folder cannot be used. Choose another folder.": "无法使用此文件夹，请选择其他文件夹。",
    "The previously selected folder is no longer accessible. Choose it again.": "之前选择的文件夹已无法访问，请重新选择。",
    "Delete Game Pack": "删除游戏包",
    "Delete %@?": "删除《%@》？",
    "The game pack is removed from this device. Saves and settings are kept.": "游戏包将从本机移除，存档与设置会保留。",
    "The link to the game pack is removed; the pack itself stays in its location. Saves and settings are kept.": "将移除与游戏包的关联，游戏包本身保留在原位置。存档与设置会保留。",
    "Delete": "删除",
    "Close the game before deleting it.": "请先关闭游戏再删除。",
    "No local play": "不支持联机",
    "Pack format %d is not supported (this version of NX Pocket supports format %d). Update NX Pocket to play it.": "不支持游戏包格式 %d（当前版本支持到格式 %d），请更新 NX Pocket 后再试。",
    "Preparing %@ (first start only)…": "正在准备《%@》的游戏数据（仅首次）…",
    "The archive %@ could not be opened.": "无法打开归档 %@。", "The archive %@ could not be unpacked.": "无法解开归档 %@。",
    "Part of this pack is still in iCloud Drive. Used in place, it downloads in the background; the game can start once it is on this device.": "此游戏包有部分文件仍在 iCloud 云盘中。原位使用时会在后台下载，下载到本机后即可开始游戏。",
    "Copy cancelled. Nothing was imported.": "已取消复制，未导入任何内容。", "%@ could not be read.": "无法读取 %@。", "%@ could not be written.": "无法写入 %@。",
    "%@ is still downloading from iCloud Drive. Try again once it is on this device.": "《%@》仍在从 iCloud 云盘下载，请在下载到本机后再试。",
    // NX Pocket for Mac (dm/mac/pocket)
    "Add Game…": "添加游戏…", "Hide Log": "隐藏日志", "Show Log": "显示日志",
    "Set Up NX Pocket": "设置 NX Pocket", "Storage": "存储空间", "Add": "添加",
    "Choose a game's folder, or its NSP / XCI / NSZ / XCZ files.": "选择游戏所在的文件夹，或它的 NSP / XCI / NSZ / XCZ 文件。", "Prepare the game": "准备游戏", "Make the game pack": "封装游戏包",
    "Send to iPhone": "发送到 iPhone", "NX Pocket is not on this iPhone. Install it first.": "这台 iPhone 上没有 NX Pocket，请先安装。", "Export Here": "导出到这里",
    "Export": "导出", "Install": "安装", "Choose": "选择",
    "Stopping…": "正在停止…", "Connection lost; trying %@ again (%d of 3)…": "连接中断，正在重试 %@（第 %d 次，共 3 次）…", "%@ could not be sent. Check the cable and that the iPhone is unlocked, then send again.": "%@ 发送失败。请检查数据线并确认 iPhone 已解锁，然后重新发送。",
    "Sent. Open NX Pocket on the iPhone: the game is in its library.": "已发送。在 iPhone 上打开 NX Pocket，游戏已在游戏库中。", "Sending stopped.": "已停止发送。", "Xcode 27.1 or later, from the App Store": "需要 Xcode 27.1 或更高版本（App Store）",
    "iOS platform": "iOS 平台", "Xcode → Settings → Components": "Xcode → 设置 → 组件", "Metal toolchain": "Metal 工具链",
    "Installed": "已安装", "Missing: %@": "缺少：%@", "The shader translator needs .NET 10": "着色器转换工具需要 .NET 10",
    "Not chosen": "未选择", "%@ is not an arm64 Python 3.12 or later": "%@ 不是 arm64 架构的 Python 3.12 或更高版本", "Missing modules: %@": "缺少模块：%@",
    "nxnative checkout": "nxnative 仓库", "Your own console's keys; only the path is kept": "你自己主机的密钥；只记录路径，不复制文件", "Welcome to NX Pocket": "欢迎使用 NX Pocket",
    "Before making game packs, check that this Mac has everything they need.": "制作游戏包之前，先确认这台 Mac 已具备所需环境。", "Check Again": "重新检查", "Later": "稍后",
    "Done": "完成", "Open": "打开", "Change…": "更改…",
    "Choose…": "选择…", "Installing…": "正在安装…", "Install All": "全部安装", "Download Here": "下载到这里",
    "Where the code goes (about 600 MB). It is put in a folder named nx-pocket here.": "代码放在哪里（约 600 MB），会在这里新建一个 nx-pocket 文件夹。",
    "Download gets it from GitHub (about 600 MB), or choose a copy you have": "点“下载”从 GitHub 获取（约 600 MB），已经有的话点“选择…”",
    "Installing in Terminal. Type your Mac's password there when it asks (nothing shows as you type). This list updates when you come back.": "正在“终端”里安装。提示输入密码时，输入这台 Mac 的开机密码（输入时不会显示），然后按回车。回到这里后列表会自动更新。",
    "Done. Go back to NX Pocket.": "安装完成，可以回到 NX Pocket 了。", "%@ is not selected yet": "%@ 还没有被选为当前 Xcode",
    "Xcode's first launch: its license and components": "Xcode 还需要完成首次启动（同意许可协议、安装组件）", "The install failed. See its output.": "安装失败，请查看输出",
    "Tools": "工具", "Unsigned: NX Pocket signs it on the iPhone": "不签名：由 iPhone 上的 NX Pocket 签名", "Signed with my team": "用我的开发者团队签名",
    "Team ID": "团队 ID", "Game packs": "游戏包", "An unsigned pack plays in anyone's NX Pocket that holds a developer certificate. A pack signed with your team plays in an NX Pocket signed by the same team.": "未签名的游戏包可在任何已导入开发者证书的 NX Pocket 中使用；用你的团队签名的游戏包，只能在同一团队签名的 NX Pocket 中使用。",
    "iPhone": "iPhone", "NX Pocket's bundle ID": "NX Pocket 的 Bundle ID", "Found automatically": "自动识别",
    "Build files speed up the next build of a game; a game pack can be made again from them.": "构建文件可加快同一游戏的下次制作，也可以用它们重新制作游戏包。", "%@ total": "共 %@", "Build files": "构建文件",
    "Newer version available, still playable": "有新版本，可继续使用", "Made %d commits ago. Since then, %@ changed. Making it again brings that in; this pack keeps working as it is.": "这个包是 %d 次提交之前做的，之后%@有改动。重新制作就能用上；现在的包照常可玩。", "Since it was made, %@ changed. Making it again brings that in; this pack keeps working as it is.": "做包之后%@有改动。重新制作就能用上；现在的包照常可玩。", "the shader chain": "着色器版本", "The shaders have a new version and are compiled again first. This takes a while.": "着色器版本已更新，需要先重新编译着色器，耗时较长。", "About %d minutes for this game, estimated from its shaders. Progress, Stop and Continue work as for any build; the pack you have keeps working until the new one is made.": "按这个游戏的着色器数量估算，大约需要 %d 分钟。进度、停止和继续都跟平时制作一样；新包做好之前，现在的包照常可用。", "NX Pocket only shows the difference: it does not merge or switch your code. Merge upstream in your checkout yourself (git merge). The packs listed keep working; make them again when you want what changed.": "NX Pocket 只显示差异，不会合并或切换你的代码。请自己在代码目录里合并上游（git merge）。下面列出的游戏包照常可用，想用上新改动时再重新制作。", "Game packs with a newer version after merging (they still play)": "合并后有新版本可做的游戏包（现有的照常可玩）",
    "Make the Mac version": "制作 Mac 版", "Making the Mac version failed": "制作 Mac 版失败", "The Mac version could not be made": "Mac 版没能做好", "The game could not be opened": "游戏打不开", "Play on Mac": "在 Mac 上玩", "Mac version ready": "Mac 版已就绪", "Keyboard or controller. Its settings window comes first: frame rate, resolution, language. Saves stay on this Mac; choose the same iCloud Drive folder under Cloud saves there and in NX Pocket to play on from the same save.": "可以用键盘或手柄。开始前会先出现它的设置窗口：帧率、分辨率、语言。存档留在这台 Mac 上；在那里的「云存档」和 NX Pocket 里选同一个 iCloud 云盘文件夹，就能接着同一份存档玩。", "The first time, a Mac version is made from the game's build files (about %d minutes); then it starts at once.": "第一次会先用这个游戏的构建文件做一份 Mac 版（大约 %d 分钟），之后点一下就直接开始。", "The first time, a Mac version is made from the game files (20 to 60 minutes); then it starts at once.": "第一次会先用游戏文件做一份 Mac 版（20 到 60 分钟），之后点一下就直接开始。",
    "Game pack": "游戏包", "Total": "合计", "Delete the game pack of %@?": "删除《%@》的游戏包？",
    "Game pack folder": "游戏包存放位置", "Game packs: %@ in %@": "游戏包：共 %@，存放在 %@",
    "New game packs are made in the game pack folder, apart from the build files. A game's pack is found there by its title ID, else in the game's folder.": "新做的游戏包放在游戏包存放位置，和构建文件分开。找游戏包时先按 title ID 在这里找，找不到再看游戏所在的文件夹。",
    "Delete the build files of %@?": "删除《%@》的构建文件？", "It goes to the Trash. The game on the iPhone is not affected.": "文件将移到废纸篓，iPhone 上的游戏不受影响。", "It goes to the Trash. The next build of this game starts from the beginning.": "文件将移到废纸篓，下次制作该游戏需要从头开始。",
    "Add Game": "添加游戏", "Add a game's folder or files": "添加游戏文件夹或游戏文件", "Stop": "停止",
    "Make Game Pack": "制作游戏包", "Make Again": "重新制作", "Log": "日志",
    "Show or hide the log (⇧⌘Y)": "显示或隐藏日志（⇧⌘Y）", "Games": "游戏", "Show in Finder": "在访达中显示",
    "Remove from List": "从列表中移除", "Setup": "环境检查", "Making… %d%%": "制作中… %d%%",
    "Sending %d/%d": "发送中 %d/%d", "Failed": "失败", "On iPhone": "已在 iPhone 上",
    "Pack ready": "游戏包已就绪", "No game files": "没有游戏文件", "Not made yet": "尚未制作",
    "No iPhone": "未连接 iPhone", "Connect it with a cable and unlock it": "请用数据线连接并解锁", "Refresh": "重新检测",
    "Make your own Switch games into packs for NX Pocket": "把你自己的 Switch 游戏制作成 NX Pocket 游戏包", "Add a game": "添加游戏", "Its folder, or its NSP / XCI / NSZ / XCZ files": "游戏文件夹，或 NSP / XCI / NSZ / XCZ 文件",
    "With your own prod.keys": "使用你自己的 prod.keys", "To NX Pocket, over the cable": "通过数据线送进 NX Pocket", "Drop game folders here, or click to choose": "把游戏文件夹拖到这里，或点击选择",
    "Drop to add the game": "松开以添加游戏", "Copy": "拷贝", "Play on this Mac": "在这台 Mac 上玩",
    "Base game": "本体", "Update": "更新", "Folder": "文件夹",
    "DLC ×%d": "DLC ×%d", "No game files in this folder": "此文件夹中没有游戏文件", "Game Pack": "游戏包",
    "No game pack yet": "还没有游戏包", "Making one takes 20 to 60 minutes, depending on the game. You can stop and carry on later: finished stages are kept.": "制作一次约需 20～60 分钟，取决于游戏大小。可以随时停止，下次继续时会保留已完成的阶段。", "Finish setting up first: the nxnative checkout, a Python and your prod.keys.": "请先完成环境设置：nxnative 仓库、Python 和你的 prod.keys。",
    "Game pack ready": "游戏包已就绪", "Export…": "导出…", "signed by %@": "由 %@ 签名",
    "signed on the iPhone": "在 iPhone 上签名", "format %d": "格式 %d", "Try Again": "重试",
    "Continue": "继续", "Making the game pack failed": "游戏包制作失败", "Stopped. Continue to resume from the last finished stage.": "已停止。点击「继续」将从最后完成的阶段接着做。",
    "%@ left": "剩余 %@", "Starting…": "正在开始…", "Make the game pack first.": "请先制作游戏包。",
    "To NX Pocket on this iPhone (%@)": "发送到它的 NX Pocket（%@）", "found automatically": "自动识别", "Send Again": "再次发送",
    "Send": "发送", "No iPhone connected: connect it with a cable, unlock it and trust this Mac.": "未连接 iPhone：请用数据线连接、解锁，并信任这台 Mac。", "Sending %@ (%d of %d)": "正在发送 %@（%d/%d）",
    "Game Files": "游戏文件",
    "Not needed: the tools are already installed": "不需要：所需工具已安装", "zbic is missing (only some games need it)": "缺少 zbic（仅部分游戏需要）", "Environment script": "环境脚本",
    "Optional: a shell script that sets up tools kept elsewhere": "可选：一个设置工具路径的 shell 脚本（工具装在别处时使用）",
    "The game pack did not arrive complete (%@ of %@). Send it again.": "游戏包没有传完整（已收到 %@，共 %@）。请重新传输。",
    "The game pack did not arrive complete (%@ received). Send it again.": "游戏包没有传完整（只收到 %@）。请重新传输。",
    "The game pack is damaged (part %d of %d does not match). Send it again.": "游戏包已损坏（第 %d 段校验不符，共 %d 段）。请重新传输。",
    "The game pack could not be read: %@": "无法读取游戏包：%@", "its table of contents is out of place": "目录位置不正确", "its table of contents is cut off": "目录不完整",
    "its table of contents does not match its checksum": "目录校验不符", "its table of contents is not valid": "目录格式无效",
    "Checking %@…": "正在校验《%@》…", "Unpacking %@…": "正在解出《%@》…",
    "AirDrop…": "隔空投送…",
    "This game pack's library is too old to read its game data from a single file. Make the pack again with the current tools.": "这个游戏包的程序库版本太旧，无法从单文件中读取游戏数据。请用最新的工具重新制作游戏包。",
    "Support": "支持情况", "Notes": "说明", "Last checked: %@": "上次验证：%@", "Read game name and icon": "读取游戏名称和图标",
    "Tested: plays on the iPhone": "已测试：可在 iPhone 上玩", "In progress: nxnative has a profile for it": "还在调：已有游戏配置", "No profile": "没有配置",
    "nxnative's notes for this game say it plays on an iPhone.": "nxnative 对这个游戏的说明里写明可以在 iPhone 上玩。",
    "It has a game profile, but its notes do not yet say it plays on an iPhone. It may work, or have known problems.": "已有游戏配置，但说明里还没写明能在 iPhone 上玩。可能可以运行，也可能有已知问题。",
    "nxnative has not been set up for this game. The build makes a provisional profile; the pack will most likely not run.": "nxnative 还没有适配这个游戏。制作时会自动生成临时配置，做出来的游戏包很可能无法运行。",
    "nxnative has no profile for this game: a pack can be made, but it will most likely not run.": "nxnative 没有这个游戏的配置：可以照样制作，但很可能无法运行。",
    "Make a pack of a game nxnative has no profile for?": "要为没有配置的游戏制作游戏包吗？", "Make Anyway": "仍然制作",
    "The build surveys the game and guesses a provisional profile. The pack may not start, or may crash on the way. Games with a profile are the ones known to run.": "制作时会分析游戏并推测一份临时配置。做出来的游戏包可能无法启动，或者中途崩溃。有配置的游戏才是已知能运行的。",
    "%@ is ready to send to the iPhone.": "《%@》已可以发送到 iPhone。", "The game pack could not be made": "游戏包制作失败",
    "%@: see the log in NX Pocket for Mac.": "《%@》：请在 NX Pocket 中查看日志。", "Sent to iPhone": "已发送到 iPhone", "%@ is in NX Pocket on %@.": "《%@》已传到 %@ 上的 NX Pocket。",
    "Sending failed": "发送失败",
    "Looking for NX Pocket…": "正在查找 NX Pocket…", "NX Pocket is not installed": "未安装 NX Pocket", "Older NX Pocket installed": "NX Pocket：旧版本", "NX Pocket build %d: update available": "NX Pocket 版本 %d：有更新", "NX Pocket is up to date": "NX Pocket 已是最新", "Install NX Pocket": "安装 NX Pocket", "Team for installing NX Pocket": "安装 NX Pocket 用的开发者团队", "Built from the last commit of your nxnative checkout and installed over the cable. Games and saves on the iPhone stay.": "用你的 nxnative 代码最新一次提交编译，通过数据线安装。iPhone 上的游戏和存档都会保留。", "Set the team NX Pocket is signed with first (Settings › iPhone): game packs signed by a team play only in an NX Pocket of the same team.": "请先设置给 NX Pocket 签名的开发者团队（设置 › iPhone）：用某个团队签名的游戏包，只能在同一团队签名的 NX Pocket 中运行。", "Building and installing… (the first time takes several minutes)": "正在编译并安装…（第一次需要几分钟）", "Installed.": "安装完成。", "Stopped.": "已停止。", "NX Pocket installed": "NX Pocket 已安装", "NX Pocket is up to date on %@.": "%@ 上的 NX Pocket 已是最新版本。", "NX Pocket could not be installed": "NX Pocket 安装失败", "See the install log in NX Pocket for Mac.": "请在 NX Pocket for Mac 中查看安装日志。",
    "NX Pocket needs iOS %d or later": "NX Pocket 需要 iOS %d 或更高版本",
    "Queued (%d)": "排队中（第 %d 个）", "Queued: %d ahead": "排队中：前面还有 %d 个", "The queue is paused. Resume it to continue.": "队列已暂停：继续后会自动接着做。", "Making %@ now. This game starts automatically next.": "正在制作《%@》，完成后会自动开始这一个。", "It starts automatically.": "会自动开始。", "Resume Queue": "继续队列", "Pause Queue": "暂停队列", "Remove from Queue": "移出队列",
    "the host (emulation)": "宿主（模拟层）", "the graphics and shaders": "图形与着色器", "the iPhone front end": "iPhone 前端", "the code rewriter": "代码改写", "this game's profile": "这个游戏的配置", "The pack does not say which commit it was made from.": "游戏包里没有记录它是用哪次提交制作的。", "No nxnative checkout is set.": "还没有设置 nxnative 代码目录。", "Commit %@ is not in this checkout (made from another one?).": "提交 %@ 不在当前代码目录中（可能是用别的代码做的）。", ", ": "、", 
    "Problem report": "问题报告", "Problem report ready": "问题报告已生成", "Report a Problem…": "问题报告…", "It holds the build's logs, your settings and crash reports, with your home folder hidden and nothing that looks like a key; no game files. Open it and look through it before you send it.": "里面有制作日志、你的设置和崩溃报告：个人目录已隐去，看起来像密钥的内容都已去掉，不含游戏文件。发送前请先打开看看。", "Puts the logs and settings for a bug report into a zip (no game files, no keys).": "把报告问题需要的日志和设置打包成一个 zip（不含游戏文件和密钥）。",
    "Reading…": "正在读取…", "Reading the game's folder…": "正在读取游戏文件夹…",
    "NX Pocket is not affiliated with, authorized or endorsed by Nintendo. Nintendo Switch is a trademark of Nintendo. NX Pocket provides no games or keys; use only games and console keys you legally own.": "本项目与任天堂无关，未获任天堂授权或认可。Nintendo Switch 是任天堂的商标。NX Pocket 不提供任何游戏或密钥，请仅使用你自己合法拥有的游戏和主机密钥。", "Not affiliated with Nintendo · Only games you own": "与任天堂无关 · 仅限你合法拥有的游戏", "Based on nxnative (seedds, MIT License).": "基于 nxnative（seedds，MIT 许可）。", "NX Pocket for Mac adapts parts of NX Play (varyform, MIT License): reading the build's progress and running its tools.": "NX Pocket for Mac 引用了 NX Play（varyform，MIT 许可）的部分代码：读取构建进度和运行工具。", "About NX Pocket": "关于 NX Pocket",
    "The game pack is damaged (%@ does not match). Send it again.": "游戏包已损坏（%@ 校验不符）。请重新传输。", "Quick check of %@…": "正在快速检查《%@》…", "Added after a quick check only: this pack does not carry checksums for all of its game data. If the game misbehaves, make the pack again with Full Check on and send it again.": "已加入游戏库。只做了快速检查：这个游戏包没有带全部游戏数据的校验值，未做完整校验。如果游戏运行异常，请在 Mac 端打开「完整校验」后重新制作并发送。", "Full check (recommended when sharing packs)": "完整校验（发给别人时建议打开）", "Puts checksums for all of the game data in the pack, so the iPhone can check every part. Reads the game data once more if its checksums were not saved during extraction.": "把全部游戏数据的校验值写进游戏包，手机导入时可以做完整校验。如果提取时没有保存校验值，会再完整读一遍游戏数据。",
    "Looking for NX Pocket on the iPhone…": "正在查找 iPhone 上的 NX Pocket…", "The iPhone did not answer. Unlock it, check the cable, then send again.": "iPhone 没有响应。请解锁 iPhone、检查数据线，然后重新发送。", "Getting ready…": "正在准备…",
    "about": "约",
    "NX Pocket Updates": "NX Pocket 更新", "This is build %d.": "当前版本号 %d。", "Checking for updates…": "正在检查更新…", "NX Pocket is up to date.": "NX Pocket 已是最新版本。", "Downloading and checking its signature…": "正在下载并校验签名…", "Version %@ (build %d) is out.": "新版本 %@（版本号 %d）已发布。", "Downloaded. The signature is valid.": "已下载，签名校验通过。", "NX Pocket cannot replace itself where it is. Quit it and put the new copy in Applications yourself.": "NX Pocket 无法在当前位置替换自己。请退出后，自己把新版本放进「应用程序」。", "NX Pocket is not notarized by Apple. If macOS says it cannot be opened, open System Settings › Privacy & Security and click Open Anyway (or Control-click the app and choose Open).": "NX Pocket 没有经过 Apple 公证。如果 macOS 提示无法打开，请到「系统设置 › 隐私与安全性」里点「仍要打开」（或按住 Control 点按 App，选择「打开」）。", "Download": "下载", "Install and Reopen": "安装并重新打开", "Set the repository the releases come from first (Settings › Updates).": "请先设置发布新版本的仓库（设置 › 更新）。", "Could not check for updates: %@": "无法检查更新：%@", "the server answered %d (no release yet?)": "服务器返回 %d（可能还没有发布版本）", "this build has no update key (NXPocketUpdateKey), so it cannot check a release's signature": "这个版本没有内置更新公钥，无法校验新版本的签名", "the download's size is not the release's": "下载的文件大小与发布信息不符", "the download's checksum is not the release's": "下载的文件校验值与发布信息不符", "the release's signature does not match this app's update key: it was not made by this app's maker, or was changed on the way": "签名与本 App 的更新公钥不匹配：不是本 App 的作者发布的，或者在传输中被改动过", "the release is not this app (another bundle ID)": "下载的不是本 App（包名不同）", "the release's app is not the build its manifest names": "下载的 App 版本号与发布信息不符", "The update was not installed: %@": "没有安装更新：%@", "Upstream nxnative": "上游 nxnative", "Check Now": "立即检查", "Not checked yet.": "还没有检查过。", "Fetching upstream's commits…": "正在获取上游的提交…", "new upstream commits": "个上游新提交", "of yours not upstream": "个你自己的提交（上游没有）", "Checked %@": "检查于 %@", "None: its changes do not touch what your packs are made of.": "没有：这些改动不涉及你的游戏包用到的代码。", "Your checkout has every upstream commit.": "你的代码已包含上游的全部提交。", "Could not reach upstream: %@": "无法连接上游：%@", "git fetch failed": "git fetch 失败", "Check for Updates…": "检查更新…", "Upstream nxnative…": "上游 nxnative…", "NX Pocket %@ is out": "NX Pocket %@ 已发布", "Upstream has %d new commits": "上游有 %d 个新提交", "Releases from (GitHub owner/name)": "新版本发布仓库（GitHub 用户名/仓库名）", "Upstream branch": "上游分支", "Updates": "更新", "NX Pocket for Mac checks this repository's GitHub releases once a day and installs a newer one only when its signature checks out. Upstream nxnative is only compared with your checkout: nothing is merged, and nothing is written to GitHub.": "NX Pocket for Mac 每天检查一次这个仓库的 GitHub 发布，只安装签名校验通过的新版本。上游 nxnative 只用来和你的代码比较：不会合并任何东西，也不会往 GitHub 写入任何内容。",

    "NX Pocket update available": "NX Pocket 有更新", "NX Pocket build %d is installed; this checkout makes a newer one.": "已安装 NX Pocket 版本 %d；当前代码可以生成更新的版本。", "Language": "语言", "System": "跟随系统", "System alerts follow the next time NX Pocket starts.": "系统弹窗的语言会在下次打开 NX Pocket 时生效。", "The menu bar's standard items follow the next time NX Pocket starts.": "菜单栏的标准菜单项会在下次打开 NX Pocket 时切换语言。",
]
func tr(_ s: String) -> String { launcherChinese ? zh[s] ?? s : s }

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        guard locked else { return tr(s.note) }
        return (s.note.isEmpty ? "" : tr(s.note) + " · ") + (m.fromLaunch.contains(s.env) ? tr("Set at launch") : tr("Set by an env file"))
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(s.label))
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { Text(tr($0[1])).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(tr(s.label))
                        .accessibilityValue(percentage)
                }
            case "text":   // a line of text (local play's peers and player name); empty leaves the host's own default (LauncherSettings.apply)
                VStack(alignment: .leading, spacing: 8) {
                    settingLabel
                    TextField(tr("Not set"), text: m.binding(s))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(s.env == "DM_NET_PEERS" ? .numbersAndPunctuation : .default)
#endif
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr(s.label))
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}
