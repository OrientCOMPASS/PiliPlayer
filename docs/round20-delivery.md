# 第二十轮交付说明 + 装机测试清单

> **⚠️ 第二十五轮起本文的「画中画」章节全部作废**：应用内浮窗、独立 PiP Activity、
> 「画中画样式」设置等实现已整体回退到上游原版（见 `docs/round25-delivery.md`）。
> 本文仅作决策记录保留，其中非画中画的部分（SAF 浏览、播放列表、播放/字幕记忆、
> 手柄、VR）仍然有效。

> 上一轮(第十九轮)的说明与清单见 `docs/round19-delivery.md`，本轮**包含**其全部改动。
> 本轮需求：① 记忆播放设置 ② 真·系统画中画 ③ 手柄长按连续输入
> ④ 去掉「选择本机文件夹…」行 ⑤（追加）修好"摇杆/拖拽不如陀螺仪流畅"。
>
> 验证方式与上轮一致：沙盒不能构建 Flutter/Android，全部走 CI
> （`flutter analyze` 0 error → 新增代码零容忍 `dart analyze --fatal-infos` →
> `flutter test` → `flutter build apk --release`（arm64-v8a）+ 签名核验）。
> 版本号仍未 bump（`2.1.5+2`）。

---

## 需求 2：系统级画中画，且不收起整个应用

### 为什么 moonlight-android 可以，而上一轮我用了应用内浮窗

系统 PiP 收起的是**调用 `enterPictureInPictureMode()` 的那个 Activity**。
moonlight-android 的串流跑在独立的 `Game` Activity 里（manifest：
`supportsPictureInPicture` + `launchMode="singleTask"` + `excludeFromRecents`
+ `noHistory`），浏览界面是另一个 Activity（`PcView`/`AppView`）——
`Game` 进 PiP 后它的任务被移到 pinned 栈，主任务照常回到前台，所以能边 PiP 边浏览。

本工程是**单 FlutterActivity**：主 Activity 一进 PiP，整个应用（所有 Flutter 页面）
都被塞进那个小窗，应用内什么都点不到。上一轮因此退而求其次做了应用内浮窗
（root Overlay，只收起播放页），但那不是系统 PiP：出不了应用、没有系统窗口管理
（吸附/缩放/跨应用悬浮）、没有系统媒体按钮。

### 本轮实现：照搬 moonlight 的结构

1. **新增 `PipActivity`（独立任务的 native Activity）**：一个 `SurfaceView` 作渲染目标，
   一可见就 `enterPictureInPictureMode()`；`singleTask` + 独立 `taskAffinity`
   （`${applicationId}.pip`）+ `excludeFromRecents` + `noHistory`，与 moonlight 的
   `Game` 一致。系统媒体按钮（快退 / 播放暂停 / 快进）走既有 `MediaButtonReceiver`。
   PiP 宽高比按安卓硬限制（约 1:2.39 ~ 2.39:1）夹取，超出会抛异常。
2. **画面交接（不重建播放器）**：mpv 的 `--wid` 就是"指向 `android.view.Surface`
   的 JNI 全局引用指针"（media_kit 的 `VideoOutput.createSurface` 正是这么造的）。
   所以 `PipActivity` 用
   `MediaKitAndroidHelper.newGlobalObjectRef(holder.surface)` 造一个新 wid，
   Dart 侧按 media_kit 自己的顺序 **`vo=null` → `wid=<新>` → `vo=gpu`** 把画面搬过去；
   退出 PiP 时用**交接前就 `getProperty('wid')` 存下来的**原值搬回 Flutter 纹理。
   播放器实例全程不重建 ⇒ 不重新拉流、不丢进度、不重新缓冲。
3. **surface 生命周期**：`surfaceCreated`（含 PiP 尺寸变化导致的重建）推新 wid 给
   Dart 重新接上；`surfaceDestroyed` 里先通知 Dart 摘掉 mpv 再**短暂阻塞主线程
   ~260ms** 等它处理完（回调返回后 surface 随时失效，继续渲染就是 use-after-free；
   Dart 在 UI isolate 上跑、`setOption` 是直连 FFI，不依赖主线程，所以这样等是安全的）。
4. **抢回画面**：media_kit 的 `AndroidVideoController` 在 `videoParams` 变化时会把
   `wid` 抢回它自己的 Flutter 纹理（它不知道画面被借走了）。PiP 期间我们监听同一事件，
   延后 150ms（让它的 listener 先跑完）再把 PiP 的 wid 写回去，避免中途改分辨率黑屏。
5. **入口与兜底**：顶栏「画中画」**点按 = 系统 PiP**；这条路走不通（设备不支持 /
   系统拒绝 / surface 没起来 / 读不到当前 wid）时依次退回
   ① 老的"整应用系统 PiP" ② 应用内浮窗 —— 按钮永远有反应。
   **长按 = 应用内浮窗**（上一轮那套，保留为不依赖系统 PiP 的备选）。
6. 进 PiP / 浮窗前会关掉主 Activity 的 `setAutoEnterEnabled`，否则启动 PipActivity 时
   主 Activity 退到后台也会自己缩进一个小窗 ⇒ 两个 PiP。
   设置里的「自动画中画」（按 Home 时主 Activity 进系统 PiP）行为不变。

### 与上一轮共用的机制

播放页出栈但播放器保活（`floatingKeepAlive`）、引用计数归还
（`releasePageSlotForFloating`，否则退出播放页后声音不停/局域网继续拉流）、
小窗期间续播进度落盘、SAF 的 fd 不在小窗期间回收、回播放页带实时进度原位续播、
进新播放页/直播间前自动收掉旧小窗 —— 两种模式共用同一套。

---

## 需求 1：记忆"这个视频怎么播"

新增 `lib/utils/local_media_memory.dart`。除播放**位置**（仍在 `LocalMediaProgress`，
`Box<int>`）外，记住：**倍速、VR 片源布局、眼位、视场角、陀螺仪**。
存 `GStorage.video`（JSON 字符串，key = `localMem:<crc32(uri)>`，上限 500 条按时间淘汰）。

关键取舍 —— **只记"偏离默认"的部分**：

- 倍速与全局默认一致时不写。否则用户以后改全局默认倍速，看过的老视频还卡在旧值上。
- 普通 2D 片源不写 VR 块。否则会把"自动识别"钉死成 `off`，以后这片源再也不认了。
- 用户**手动**选过布局（含"就要平面播"）时靠 `PlPlayerController.vrUserTouched` 记住：
  下次直接按用户的选择走，不再自动识别（文件名没关键词、识别错的那种片源特别有用）。

恢复时机：VR 布局作为 `setDataSource(vrProjection:)` 的 hint 在**装载阶段**生效
（不会先按平面渲染一帧再跳）；倍速/眼位/视场角/陀螺仪在 `onInit` 回调里补
（陀螺仪用 `persist: false`，只作用于这个视频，不改全局默认）。
落盘时机：播放中每 5 秒、切集前（`onReset`）、退出播放页时。

作用范围：**本地 / 局域网媒体**（与既有的位置记忆同域）。在线视频的进度本来就由
B 站历史负责，倍速是全局偏好，暂未纳入（要的话下一轮加）。

---

## 需求 3：手柄按键长按连续输入

- `PlPlayerController.startKeyRepeat/stopKeyRepeat`：按下先走一步，**400ms 后每 110ms
  一步**，松手停 —— 与屏幕上 VR 步进按钮（`_VrStepButton`）完全同一套节奏。
  用**自己的定时器**而不是依赖系统 `KeyRepeatEvent`：各机型/各手柄的重复速率差异很大，
  而且不是所有平台都会把长按转成 repeat 事件；系统 repeat 事件被吃掉，避免双重触发。
- **VR 操作模式下十字键 = 视角步进（长按连续转动）**：左右 = 偏航、上下 = 俯仰，
  方向与右摇杆/单指拖拽一致（右 = 看右、上 = 看上）。
  VR 模式下十字键不再做快退快进/音量：环视优先，进退仍有 **L1/R1（±60s）**，
  音量走屏幕 UI 或退出 VR 操作模式。
- △ 摆正 / □ 眼位是**单次**动作：只认 `KeyDownEvent`，长按产生的 `KeyRepeatEvent`
  直接吃掉；眼位另加 400ms 冷却，抖动/长按都不会连着切。
- 连发定时器在播放器 `dispose()` 里一并取消，不会留下"松手了还在转"的尾巴。

---

## 需求 6（追加）：摇杆 / 拖拽环视不如陀螺仪流畅

### 根因

| 输入 | 更新路径 | 有效更新率 |
|---|---|---|
| 陀螺仪 | 补丁版 libmpv **native 逐帧**跑 OrientationEKF（含 33ms 前视补偿） | = 渲染帧率（60/90/120Hz） |
| 手指拖拽 | Dart 算绝对角度 → `applyVrView()` **节流 30ms** → 写 `vr-view` 属性 | ≈33Hz（台阶感） |
| 手柄摇杆 | 50Hz MethodChannel 轮询，**且只在采样到达那一刻推进角度** → 再过 30ms 节流 | ≈33Hz 且带抖动 |

### 修法（Dart 侧，不动 libmpv）

1. `applyVrView()`：30ms 节流 → **`SchedulerBinding.scheduleFrameCallback` 每帧合并一次**。
   一帧内来多少次输入都只写一次属性，但**每一帧都会写** ⇒ 更新率与屏幕刷新率一致。
   代价可控：yaw/pitch/fov 早已合并进单个 `vr-view` 属性（第十五轮的优化）、
   差分下发保证值没变的属性不重复写，所以每帧最多 **1 次**跨线程往返
   （第十五轮出问题时是 ~300 次/s）。`force: true`（进/出 VR、切布局、摆正）仍立即下发。
2. 摇杆**采样与积分解耦**：轮询提到 100Hz，只负责把最新读数取回来；
   推进改由 `VrControlLayer` 的**帧 Ticker** 用"最新采样 × 真实帧间隔"积分。
   于是 60/90/120Hz 屏幕上转速一致，也不会因为采样抖动而一格一格跳。
   时间片仍夹在 ≤0.25s（掉帧/切后台回来不会瞬移），死区 0.15、满偏 110°/s 不变。
3. 拖拽本身事件率就够（触摸 60~240Hz），改成每帧下发后自然跟上刷新率。

### 与陀螺仪仍存在的差别（诚实说明）

- 陀螺仪有 **33ms 前视补偿**（预测），手动输入没有 ⇒ 理论上仍慢半拍；
- 陀螺仪在 native 侧**每帧**读姿态，手动输入要过一次 Dart→FFI 属性写入
  （每帧 1 次，已经是最小代价）。
- **要做到与陀螺仪完全同级**，需要把"手动角速度"也搬进 libmpv 逐帧积分：
  给补丁加一个 `vr-look-velocity`（deg/s）属性，在已有的 `vr_manual_angles()`
  里按帧 dt 积分（该函数本来就是逐帧跑的，头追偏置也在那儿合成）。
  好处是 Dart 只在摇杆**变化时**写一次（每秒几次，而不是每帧一次），
  延迟与平滑度都与陀螺仪同级。代价：改 `tool/libmpv-vr` 的 C 补丁 →
  跑 `libmpv_vr.yml`（本仓库无依赖缓存，冷构建约 60~90 分钟）→
  产物发布到本仓库的 `libmpv-vr` 滚动 release → 还要把
  `third_party/media_kit_libs_android_video/android/build.gradle` 的下载地址从
  `OrientCOMPASS/PiliPlus` 改到 `OrientCOMPASS/PiliPlayer`。
  这条链我能在 CI 里跑通编译，但 C 侧行为只能靠你真机验证，风险明显高于本轮的
  Dart 改法，所以留作下一步（你点头我就做）。

---

## 需求 4：去掉「选择本机文件夹…」常驻行

真机确认"看不到文件"就是权限问题（开「所有文件访问权限」一次到位），
常驻一个授权入口只是噪音。已移除该行。SAF 通道本身**保留**：

- 已授权过的目录树仍列在「本机存储」最上面（长按可移除授权）；
- 未开全文件权限又点存储卷时，弹窗里仍有"选择本机文件夹（推荐）"这条出路；
- 「开启「所有文件访问权限」」行保留（未开启时才显示）。

---

## 装机测试清单（本轮）

### A. 系统画中画（重点，全新链路）

- [ ] 全屏播放 → 顶栏画中画**点按** → 出现**系统** PiP 窗口（系统样式：圆角、
      可拖到屏幕任意位置、可缩放、能吸附边角），主界面回到应用且**可以继续点**：
      返回首页、切「本地」板块、进目录浏览、进设置页，PiP 窗口一直在最上层播。
- [ ] PiP 期间画面**不卡顿、不重新缓冲**，声音连续；进度在走。
- [ ] PiP 窗口的系统按钮：快退 / 播放暂停 / 快进 都能用。
- [ ] **拖动/缩放** PiP 窗口：画面跟随，不变黑、不花屏（surface 重建后要能重新接上）。
- [ ] 点 PiP 窗口的**展开**：回到播放页，画面接上、进度接上（本地文件误差 1~2 秒内）。
- [ ] 点 PiP 窗口的 **X**（或把它划到屏幕顶部/底部的关闭区）：播放停止，
      应用内不留残余声音；再进那个文件能从看过的位置续播。
- [ ] PiP 存在时**按 Home**：PiP 窗口留在桌面继续播；再点应用图标能回到应用。
- [ ] PiP 存在时从应用里**再开一个视频**：旧 PiP 自动关闭，新视频正常播（不会两个播放器打架）。
- [ ] 竖屏视频进 PiP：窗口比例正常（系统对比例有硬限制，已夹取），画面等比不变形。
- [ ] **长按**画中画按钮 = 应用内浮窗（上一轮那套，仍可用）；
      两种模式互斥，不会同时出现两个小窗。
- [ ] 开了「自动画中画」设置后按 Home：仍是老的"整应用系统 PiP"，且**不会**
      在点了画中画按钮后额外再冒出一个主 Activity 的小窗。
- [ ] 直播间画中画按钮：保持原行为（本轮未改）。
- [ ] VR 片源在 PiP 里：画面是重投影后的视角（VR 补丁在 VO 内生效，与渲染目标无关）。

### B. 播放设置记忆

- [ ] 本地视频调到 1.5x → 退出 → 再进：**仍是 1.5x**；而没调过倍速的其它视频仍用全局默认。
- [ ] 改全局默认倍速（设置里）→ 之前"没手动调过倍速"的视频跟着变；
      手动调过的仍保持自己的值。
- [ ] VR 片源手动选「左右格式 360°」+ 切右眼 + 调视场角 + 开陀螺仪 → 退出重进：
      **全部还原**，且不再重新走"自动识别"（不会先平面闪一下）。
- [ ] 文件名没有 VR 关键词、但手动选过布局的片源：重进后直接按上次的布局播。
- [ ] 对一个普通 2D 视频手动选「强制平面」→ 重进：仍是平面，不会被自动识别改掉。
- [ ] 普通 2D 视频正常看完退出：不应产生 VR 记忆（下次仍走自动识别）。
- [ ] 播到接近结尾（剩 <10 秒）退出：位置记忆按既有规则清掉（从头播），设置记忆保留。
- [ ] 同一目录切集：每集各自记住自己的倍速/VR 设置，互不串。

### C. 手柄

- [ ] VR 操作模式，**按住**十字键任一方向：视角先走一步，约 0.4 秒后开始连续转动，
      松手立刻停（不会多走几步）。
- [ ] 十字键方向：右 = 看右、左 = 看左、上 = 看上、下 = 看下（与右摇杆一致）。
- [ ] **长按** △：只摆正一次（不反复重置）；**长按** □：眼位不会疯狂来回切。
- [ ] VR 模式下 L1/R1 仍是 ±60s；这些手柄操作期间播放器顶栏/底栏**不被唤出**。
- [ ] 退出 VR 操作模式后，十字键恢复原语义（左右快退快进、上下音量）。
- [ ] 键盘方向键在 VR 模式下同样能步进视角（与手柄十字键同一分支）。

### D. VR 环视流畅度（本轮重点体感项）

- [ ] 手指拖拽环视：与陀螺仪对比，**台阶感消失**（60Hz 以上屏幕尤其明显）；
      快速来回拖不卡顿、不掉帧、音画不同步。
- [ ] 右摇杆环视：转动**连续平滑**（不再是一格一格），松手立刻停、静置不漂移。
- [ ] 90/120Hz 屏幕（若手上有）：转速与 60Hz 屏幕一致（按帧间隔积分，不是按采样次数）。
- [ ] 长时间拖拽/摇杆环视（1~2 分钟）：不应出现发热导致的明显掉帧或属性写入堆积
      （每帧只写 1 个合并属性）。
- [ ] 拖拽结束/松手后最终视角与手指位置一致（帧回调尾随下发）。
- [ ] 180° 片源：手动偏航到覆盖边界仍会收敛（不见黑边），陀螺仪模式下放宽 —— 与上轮一致。

### E. 本机存储（回归 + 需求 4）

- [ ] 「本机存储」里**不再有**「选择本机文件夹…」这一行；
      未开全文件权限时仍有「开启「所有文件访问权限」」行，点它跳系统设置，
      开启后回来副标题不再显示"只能看到媒体文件"，直读能看全。
- [ ] 已授权过的 SAF 目录树仍在列表最上面，能浏览、能播、长按能移除授权。
- [ ] 未授权又点存储卷：仍弹三选一（选择本机文件夹 / 开全文件权限 / 仍然直读）。
- [ ] 上一轮的本机浏览项（无 `..`、面包屑、SAF 播放/字幕/续播、检索含子目录）全部回归通过。

---

## 改动清单（本轮新增/修改的文件）

新增：

- `android/app/src/main/kotlin/com/example/piliplus/PipActivity.kt` —
  系统 PiP 专用 Activity + surface/wid 交接 + 事件推送（含 `PipChannel` / `PipLauncher`）
- `lib/services/system_pip.dart` — PiP 通道、事件模型、`MpvWidHandoff`（vo/wid 交接）
- `lib/utils/local_media_memory.dart` — 播放设置记忆（`LocalMediaSettings` / `LocalMediaMemory`）
- `test/utils/local_media_memory_test.dart` — 记忆序列化的回归测试

修改：

- `android/app/src/main/AndroidManifest.xml` — 声明 `PipActivity`
- `android/app/src/main/kotlin/.../MainActivity.kt` — 缓存 Dart messenger、注册 `piliplus/pip` 通道
- `lib/services/floating_player.dart` — 两种模式（应用内浮窗 / 系统 PiP）、
  surface 事件处理、宽高比夹取、关掉主 Activity 的自动 PiP
- `lib/pages/video/widgets/header_control.dart` — 画中画按钮：点按系统 PiP（含兜底）、长按浮窗
- `lib/pages/video/controller.dart` — 记忆的读取/恢复/落盘
- `lib/plugin/pl_player/controller.dart` — `applyVrView` 改逐帧、`vrUserTouched`、
  按键连发、眼位冷却、`_onUserLeaveHint` 兜底
- `lib/plugin/pl_player/utils/gamepad.dart` — 采样与积分解耦、轮询 100Hz
- `lib/plugin/pl_player/widgets/vr_control_layer.dart` — 帧 Ticker 逐帧积分摇杆
- `lib/pages/video/widgets/player_focus.dart` — VR 模式十字键步进 + 长按连发
- `lib/pages/local_media/view.dart` — 去掉常驻的「选择本机文件夹…」行

## 已知取舍

1. 系统 PiP 的画面交接依赖 `--wid` 语义与 media_kit 的 `vo=null → wid → vo=gpu` 顺序，
   这条链我只能保证编译通过，**首次真机验证**；任何一步失败都会退回
   "整应用系统 PiP" 或应用内浮窗，不会没有画中画。
2. 手动环视已改成逐帧下发，但**没有**陀螺仪那样的前视预测；要做到完全同级需改
   libmpv 补丁（见上文"与陀螺仪仍存在的差别"）。
3. VR 模式下十字键改为视角步进，音量在 VR 模式下没有手柄键位（用屏幕 UI 或退出 VR 模式）。
4. 播放设置记忆目前只覆盖本地/局域网媒体。
5. PiP 窗口固定按片源比例，不支持在窗口内切换画质/字幕（系统 PiP 的固有限制）。
