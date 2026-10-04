# 第二十五轮交付说明：画中画整体回退到原版实现

需求方原话：**「r24 是不是相当于回到了原版实现？如果不是，就手动修改退回到原版实现（我们修改 pip 之前）」**

结论先说：**r24 不等价于原版**，本轮已按需求把画中画整条链路回退到 `f96d996`（Initial commit，即我们动手改 PiP 之前）的实现。

---

## 1. r24 与原版差在哪（为什么要再动一次）

r24 只改了**默认值**：`Pref.pipStyle` 从 `systemWindow` 改成 `systemWholeApp`，于是「点按画中画按钮」这条路确实又走回了原版的 `plPlayerController.enterPip()`。**默认行为等价，代码不等价**——r19~r23 堆起来的整套机制还全在包里：

| 仍在 r24 包里的东西 | 规模 |
| --- | --- |
| `lib/services/floating_player.dart`（应用内浮窗：Overlay 小窗、拖拽、等比 letterbox、亮度还原、引用计数、媒体会话簿记、交接自检、看门狗、`[pip]` 诊断日志、mpv 日志转发） | 971 行 |
| `android/.../PipActivity.kt`（独立 PiP Activity：TextureView、wid 交接、PiP 参数、RemoteAction 媒体按钮） | 412 行 |
| `lib/services/system_pip.dart`（`SystemPipBridge` / `SystemPipEvent` / `MpvWidHandoff`） | 230 行 |
| `lib/plugin/pl_player/models/pip_style.dart` + 「设置 → 播放设置 → 画中画样式」选项 + `SettingBoxKey.pipStyle` + `Pref.pipStyle` | 45 行 + 3 处 |
| 顶栏按钮：`enterPip()` 三级兜底链（独立窗口 → 整应用 PiP → 应用内浮窗）、`onLongPress` 浮窗入口、改过的 tooltip | ~90 行 |
| `floatingKeepAlive` 保活标记在 4 处的分支：播放页 `dispose`、`didChangeAppLifecycleState`、`_onUserLeaveHint`、SAF fd 回收（`browser.dart` ×2 / `app_scheme.dart`）、页面跳转前 `closeIfActive()`（`page_utils.dart` ×2） | ~60 行 |
| `PlPlayerController.releasePageSlotForFloating()`（浮窗接管时还引用计数） | 12 行 |
| `initLocalMediaSource(startAt:)` + `args['progress']`（浮窗回播放页时带实时进度） | 20 行 |
| `MainActivity.dartMessenger` + `piliplus/pip` 通道、Manifest 里的 `PipActivity` 声明 | ~40 行 |

也就是说：r24 的包里仍然编译着两条我们自造的画中画路径（应用内浮窗 / 独立 PiP Activity），入口仍然挂在按钮的长按与兜底链上，播放页与本地媒体链路里仍然散落着为它们开的特例分支。**本轮把这些全部删掉/还原。**

---

## 2. 回退后的行为（= 上游原版，逐条对照）

1. **顶栏「画中画」按钮**：
   ```dart
   onPressed: () {
     if (AndroidHelper.isPipAvailable) {
       plPlayerController.enterPip();
     }
   }
   ```
   → `PageUtils.enterPip(...)` → JNI `AndroidHelper.enterPip(engineId, width, height, autoEnter, isLive, isPlaying)`，由**持有 Flutter 引擎的那个 Activity（MainActivity）自己进系统 PiP**。没有第二个 Activity、没有 surface/wid 交接。
2. **窗口里是什么**：整个播放页。`lib/pages/video/view.dart` 里那段
   `if (plPlayerController.isPipMode) { child = plPlayer(..., isPipMode: true); }`
   是**原版就有的**（本轮未动），所以控件层/弹幕/VR 层都在小窗里；`画中画不加载弹幕`（`pipNoDanmaku`）继续生效。
3. **后台画中画**：「设置 → 播放设置 → 后台画中画」(`autoPiP`) 仍是原版逻辑——`_onUserLeaveHint()` 里 `playerStatus.isPlaying && _isCurrVideoPage` 时进 PiP，不再有 `floatingKeepAlive` 短路。
4. **叉号 / 展开**：点叉号 = 退出整个应用（整应用 PiP 的标准行为）；点展开 = 回到应用、播放页原样还在、进度连续。
5. **长按画中画按钮**：不再有额外行为（应用内浮窗已删）。
6. **直播间**的画中画入口（`lib/pages/live_room/widgets/header_control.dart`）本来就是原版，未动。
7. **设置页**：「画中画样式」选项已移除，播放设置里只剩原版的「后台画中画」「画中画不加载弹幕」。

---

## 3. 具体删/改清单

**整文件删除（4 个，共 1658 行）**

- `lib/services/floating_player.dart`
- `lib/services/system_pip.dart`
- `lib/plugin/pl_player/models/pip_style.dart`
- `android/app/src/main/kotlin/com/example/piliplus/PipActivity.kt`

**还原成与 `f96d996` 逐字节一致（6 个）**

- `lib/pages/video/widgets/header_control.dart`（`git diff f96d996 -- 该文件` 现在为空）
- `lib/pages/setting/models/play_settings.dart`
- `lib/utils/storage_pref.dart`
- `lib/utils/storage_key.dart`
- `lib/utils/page_utils.dart`
- `lib/utils/app_scheme.dart`

**外科式回退（只摘 PiP，其它轮次的功能全部保留）**

| 文件 | 摘掉的 | 保留的 |
| --- | --- | --- |
| `lib/plugin/pl_player/controller.dart` | `floatingKeepAlive`、`releasePageSlotForFloating()`、`_onUserLeaveHint()` 的保活短路 | VR 30ms 节流（r19 版）、手柄环视/眼位、`vrUserTouched` |
| `lib/plugin/pl_player/view/view.dart` | `didChangeAppLifecycleState()` 的保活短路 | VR 操作模式下隐藏截图按钮 |
| `lib/pages/video/view.dart` | `dispose()` 里的浮窗保活分支（回原版 `if (!isCloseAll)`） | 播放列表 pinned 表头 + 检索 |
| `lib/pages/local_media/browser.dart` | 两处「浮窗活着就不回收 SAF fd」的判断 | SAF 浏览、焦点/检索、fd 统一回收 |
| `lib/pages/video/controller.dart` | `initLocalMediaSource(startAt:)` 与 `args['progress']` 分支 | 倍速/VR/字幕记忆、外置字幕自动加载 |
| `android/.../MainActivity.kt` | `dartMessenger`、`piliplus/pip` 通道、`BinaryMessenger` import | SAF 通道、`closeAllFds`、手柄轴通道、fd LRU（上限 16，理由改写为「视频本体 + 外挂字幕」） |
| `android/.../AndroidManifest.xml` | `PipActivity` 声明 | `READ_MEDIA_VISUAL_USER_SELECTED`、`MANAGE_EXTERNAL_STORAGE` |

**本轮完全没碰**：VR/全景（`vr_control_layer.dart`、`vr_projection.dart`、libmpv 补丁）、本机目录 SAF 重写、播放列表、播放设置与字幕记忆、手柄（`Gamepad.kt` / `gamepad.dart` / `player_focus.dart`）、SMB、测试与 CI。

校验手段：`git diff f96d996 HEAD -- lib android | grep -E "画中画|小窗|浮窗|[Pp]ip"` 结果为空（只剩原版自带的 `isPipMode`/`enterPip`/`autoPiP`）。

---

## 4. 遗留与说明

- 之前若在设置里选过「画中画样式」，那个 `pipStyle` 值会作为**无人读取的键**留在 setting 盒子里，不影响任何行为（不迁移、不清理，避免多一处启动期写盘）。
- 若以后仍然要「PiP 窗口里是 Flutter 播放页 UI **且** 应用内可继续浏览」，单引擎下不可兼得（`FlutterEngineConnectionRegistry.attachToActivity()` 会把引擎从前一个 Activity 强制摘掉），唯一路线是双引擎（`FlutterEngineGroup`），代价清单见 `docs/round24-delivery.md` §3。**本轮不做**。
- `docs/round19-delivery.md` ~ `docs/round24-delivery.md` 里所有画中画章节自此**作废**（已在 round23/round24 顶部加了作废提示），仅留作决策记录。
- 版本号未动：`pubspec.yaml` 仍是 `2.1.5+2`。

---

## 5. 装机测试清单（r25）

画中画（本轮重点，应当与上游原版一致）：

1. 播放页顶栏点「画中画」→ 整个播放页缩成系统小窗：**不黑屏、不闪烁**，声音不断，进度继续走。
2. 小窗里点「展开」→ 回到应用，播放页原样在，进度不跳。
3. 小窗里点「叉号」→ 应用退出（这是整应用 PiP 的标准行为，不是 bug）。
4. 小窗期间拖动/缩放窗口、旋转设备 → 画面跟随，不出现黑块。
5. 小窗期间按系统媒体键（耳机线控/蓝牙）→ 播放暂停生效。
6. 「设置 → 播放设置 → 后台画中画」打开后，播放中按 Home → 自动进 PiP；关掉后按 Home → 不进。
7. 「画中画不加载弹幕」开关在小窗里生效。
8. VR/全景片源进小窗 → VR 渲染仍在（小窗里是整页，含 VR 层与读数条）；不应再出现 r21~r23 那种黑屏/闪烁/叉号闪退。
9. 直播间的画中画按钮可用（原版入口）。
10. 「设置 → 播放设置」里**没有**「画中画样式」这一项。

回归（确认没被这次回退带坏）：

11. 本地/SAF：浏览目录 → 播放 → 返回 → 再进浏览页，反复几次，无「无法播放」报错（fd 回收已回原版路径）。
12. 本地视频退出再进：从上次的**位置**继续，且记住上次的倍速/字幕/VR 布局（记忆功能保留）。
13. 播放列表：表头计数 + 检索框仍 pinned 在顶部，切集自动滚到正在播那条。
14. 手柄：右摇杆环视、△ 摆正、□ 眼位、× 播放暂停、L1/R1 进退 60s 均正常。
15. 「关于」页 commit hash 应等于 r25 的提交（tag `v2.1.5-r25`）。

---

## 6. 产物静态校验（沙盒侧，装机前先自查了一遍）

- `app-arm64-v8a-release.apk` **24,337,738 B**（r24 是 24,360,971 B，小了约 23 KB ≈ 删掉的 PiP 代码），
  sha256 `48097bbe67ee08d9c7565ec0193ad7fd629050d75e717bba290def2b51d67af6`，只含 `lib/arm64-v8a`。
- `classes.dex`：`PipActivity` / `PipChannel` / `PipLauncher` / `piliplus/pip` **命中 0**；
  原版 `enterPip` / `isPipAvailable` / `isPipMode` 仍在；SAF（`piliplus/local_media`、`safPickTree`）
  与手柄（`piliplus/gamepad`）通道仍在。
- `libapp.so`（Dart AOT 快照里中文是 UTF-16LE，按该编码搜）：「画中画样式」「系统独立窗口」
  「整应用系统 PiP」「应用内浮窗」「`[pip]`」**全部 0 命中**；原版「后台画中画」
  「进入后台时以小窗形式（PiP）播放」「画中画不加载弹幕」「画中画」(tooltip) 仍在；
  其它轮次功能串（检索 / 续播 / 倍速 / VR 操作模式 / 播放列表 / 本机文件夹）仍在。
- CI：check（`flutter analyze` + 严格 `dart analyze --fatal-infos` + `flutter test`）与 release 构建全绿。
