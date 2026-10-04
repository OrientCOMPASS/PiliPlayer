# 第十九轮交付说明 + 装机测试清单

> **⚠️ 第二十五轮起本文的「画中画」章节全部作废**：应用内浮窗、独立 PiP Activity、
> 「画中画样式」设置等实现已整体回退到上游原版（见 `docs/round25-delivery.md`）。
> 本文仅作决策记录保留，其中非画中画的部分（SAF 浏览、播放列表、播放/字幕记忆、
> 手柄、VR）仍然有效。

> 面向真机验证。所有改动都已在 CI（`PiliPlayer CI`）里跑通
> `flutter analyze`（错误 0）、新增代码零容忍检查（`dart analyze --fatal-infos`，
> STRICT_PATHS 全绿）、`flutter test`（全部单测通过）与
> `flutter build apk --release --split-per-abi --target-platform android-arm64`
> （release 签名，非 debug 签名）。
>
> 版本号未 bump（仍是 `pubspec.yaml` 的 `2.1.5+2`）。

---

## 0. 本轮需求对照

| # | 需求 | 落点 |
|---|------|------|
| 1 | 完全重写本机文件目录浏览；不显示 `..`；解决"目录显示不全 / 文件应用里有但浏览找不到" | SAF 授权浏览（新）+ 直读硬化 + 浏览页导航重构 |
| 2 | 切集时播放列表焦点跟随；播放列表表头加快速搜索 | `LocalMediaIntroPanel` + `LocalMediaPlaylistHeader` |
| 3 | 画中画只收起播放页，不收起整个应用，PiP 时仍可在应用内浏览 | `FloatingPlayerService`（root Overlay 浮窗） |
| 4 | VR 模式右侧截图按钮与 VR 操作按钮重叠误触 | VR 操作模式下隐藏截图按钮 |
| 5 | VR 操作模式手柄：右摇杆转视角、△ 复位、□ 切眼位，且不唤起播放器 UI | `Gamepad.kt` + `GamepadPoller` + `PlayerFocus` |

---

## 1. 需求 1：本机文件目录浏览重写

### 1.1 根因（为什么"文件应用显示有、浏览找不到"）

安卓 11+ 的作用域存储下，应用只持有 `READ_MEDIA_VIDEO` / `READ_MEDIA_IMAGES`，
FUSE 会**只把媒体文件暴露给应用**：

* 目录里的非媒体文件（`.ass` 字幕、`.nfo`、`.txt`、压缩包、`.insv` 之类未被
  MediaStore 收录的容器）直接不可见；
* 只含非媒体文件的目录整个列不出来；
* `Android/data`、其它应用的私有目录一律 EACCES。

系统「文件」应用是特权应用，能看到全部 —— 这就是两边不一致的来源。

另外还有两个自伤 bug：

* 旧 `_listDevice` 用 `await for (dir.list())`：**任何一个**条目读失败就会把
  异常抛出去，整层已列出的条目全部作废 →「目录显示不全」；
* `followLinks: false` + `entity is! File && entity is! Directory` 的判断，把所有
  **软链**条目整条丢掉（安卓上相当多目录/文件是软链）。

### 1.2 现在的做法

1. **SAF（默认路径）**：「本地 → 本机存储 → 选择本机文件夹…」调系统
   `ACTION_OPEN_DOCUMENT_TREE`，用户授权一个目录树；之后走
   `DocumentsContract.buildChildDocumentsUriUsingTree` 列目录，
   **能看到该树下的全部条目**（与系统文件管理器一致），且授权是
   *持久化 URI 权限*，重启不丢（`persistedTrees()` 每次现查系统）。
   * 授权入口可反复添加多个文件夹；长按某个已授权文件夹可「移除授权」
     （只撤权限，不删文件）。
   * 也可以直接授权**整个内部存储的根**（在选择器里进「内部存储」再选
     "选择此文件夹"），一次到位。
2. **播放**：SAF 条目是 `content://` 文档地址，mpv 读不了 —— 复用仓库里
   已有的 `resolveContentMedia`（系统「用其它应用打开」进来的视频走的同一条
   路）把文档导出成 fd，以 `fd://N` 交给定制 libmpv。外挂字幕同路径。
   * fd 记账本 `SafFdRegistry`：从浏览页返回时统一 `closeAllFds`；
   * Kotlin 侧另有 LRU 兜底，上限从 4 提到 8（一个视频 + 若干外挂字幕
     会同时占 fd，4 个太容易把正在用的挤掉）。
   * `uri` 仍然保留 `content://` 文档地址作为**稳定标识**，所以续播记忆、
     同目录播放列表、字幕同名匹配全都照常工作（`fd://` 每次会话都变，
     不能当 key）。
3. **直读模式（dart:io）保留但硬化**，并在 UI 上明确标注受限：
   * `listen + onError` 取代 `await for`：坏条目跳过，已拿到的照常返回；
     只有"一条都没拿到"才算这层失败；
   * 软链按 `stat().type`（跟随链接）归类为文件/目录，死链才跳过；
   * 未开「所有文件访问权限」时，存储卷副标题写明「直读(只能看到媒体文件)」，
     点进去会先弹选择框：**选择本机文件夹（推荐） / 开启「所有文件访问权限」 /
     仍然直接浏览（可能不全）** —— 不再默默把人放进一个残缺列表里。
4. **可选：「所有文件访问权限」**（`MANAGE_EXTERNAL_STORAGE`）：
   「本地」页有一行入口直达系统设置页；开了之后直读模式与系统文件管理器
   一致（不需要逐个文件夹授权）。状态用 `Environment.isExternalStorageManager()`
   探测，回前台自动刷新。
5. **导航重构（不再有 `..`）**：
   * 列表里彻底去掉 `..` 行；
   * 顶栏返回键 = 上一级（在根层才关页面），系统返回键同语义（`popScope`）；
   * 顶栏下方新增**可点面包屑**（`本机存储 › Download › 电影`），点任意一段
     直接跳回该层；横向列表用 `reverse` 保证"当前层"永远可见。
6. 其它一致性收尾：
   * 条目详情/复制/播放列表副标题改用 `displayPath`：SAF 显示
     `内部存储/Download/电影/a.mkv` 这种可读路径，而不是一长串 `content://`；
   * 空目录的提示分场景给（SAF：「这个文件夹是空的」；直读受限：告诉用户
     去授权，而不是让人以为文件被吃了）；
   * 「快捷方式（收藏）」支持 SAF 子目录：新增 `LocalMediaSource.subPath`
     记住"授权是整棵树，打开后落到哪一层"；收藏判定连 `subPath` 一起比，
     同一棵树的不同子目录不会互相顶掉；
   * 本机条目不再显示「编辑」（来源编辑器只认网络协议，进去会被改成 WebDAV）。

### 1.3 装机验证要点（需求 1）

- [ ] 「本地 → 本机存储 → 选择本机文件夹…」能拉起系统选择器；选一个
      **含非媒体文件**的目录（例如放几个 `.ass`/`.nfo`/`.zip` 的目录）。
- [ ] 授权后立刻进入浏览，列表里能看到**全部**文件（与系统文件管理器逐项对比，
      数量应一致；`.ass`、`.zip` 这类以前看不到的现在要在）。
- [ ] 目录里**没有** `..` 这一行；顶栏返回键逐级回退；面包屑显示当前路径，
      点中间某一段能直接跳回该层。
- [ ] 退出应用重进：「本机存储」里那条授权还在（持久化授权），点开仍能浏览。
- [ ] 长按已授权文件夹 → 「移除授权」→ 该入口消失；再点其它入口不受影响。
- [ ] 未授权时点存储卷（直读）→ 弹出三选一说明框；选「仍然直接浏览」时
      列表可能不全，但**不应整层报错/空白**；进入 `Android/` 这类目录不应崩溃。
- [ ] 「开启「所有文件访问权限」」→ 跳系统设置 → 打开后回到应用，
      存储卷副标题不再显示"只能看到媒体文件"，直读能看到全部文件。
- [ ] 点一个 SAF 目录里的视频：能正常播放（走 `fd://`）；
      播放中切换同目录下一集/上一集正常；退出后再次进入能续播（进度记忆）。
- [ ] 同目录放 `movie.mkv` + `movie.ass`（或 `movie.zh-CN.srt`）：
      外挂字幕被自动加载，顶栏「字幕」面板里能切。
- [ ] 顶栏检索（含子目录）在 SAF 目录下能扫出子目录里的文件。
- [ ] SD 卡/U 盘（若有）：授权 SD 卡上的目录后同样能浏览与播放。
- [ ] VR 片源（`.insv` / 文件名带 `360`/`sbs` 的 mkv）放在 SAF 目录里：
      能被列出、能播、能自动识别为全景并进入 VR 操作模式。

---

## 2. 需求 2：播放列表焦点跟随 + 表头快速搜索

* **焦点跟随**：切集（点列表、上一集/下一集、列表循环、随机播放、播完自动下一集）
  后，播放列表自动滚动到正在播的那一条。
  实现上不用 `Scrollable.ensureVisible`（定高列表里目标条目常常还没被构建，
  拿不到 context），而是按 `表头高度 + index × 行高` 精确算偏移；
  只在"当前条目不可见"时才滚动，不打断用户手动翻看；首次进入用 `jumpTo`
  不带动画（避免一进页面就晃一下）。
* **表头快速搜索**：`SliverPinnedHeader` 固定表头（滚动时常驻），
  左侧显示 `播放列表 N` / 检索时显示 `命中 X / N`，右侧是搜索框（带清除按钮）。
  检索**只过滤展示**，不改变播放列表本身：上一集/下一集、列表循环、随机播放
  仍走完整列表；正在播的条目被过滤掉时不会中断播放，也不会去抢滚动位置。
* 列表副标题的路径显示同步换成可读路径（SAF 不再是一串 `content://`）。

### 装机验证要点（需求 2）

- [ ] 进一个几十集的目录播放，点「下一集」：列表自动滚到新播的那一条，
      高亮（主色 + 加粗 + ▶）也在它身上。
- [ ] 播完一集自动切下一集时同样跟随；随机播放模式下也跟随。
- [ ] 手动把列表滚到别处再看下一集：焦点会拉回来（这是预期行为）。
- [ ] 表头搜索框输入关键词：列表实时过滤，计数变成 `X / N`；
      点过滤后的条目能正常开播；清空关键词恢复完整列表。
- [ ] 检索状态下正在播的条目被过滤掉：播放不中断，列表显示"没有匹配"提示。
- [ ] 表头是 pinned 的：长列表往下滚，搜索框一直在顶部可点。
- [ ] 横屏（全屏）布局下同样有表头与焦点跟随。

---

## 3. 需求 3：画中画只收起播放页

### 为什么不是系统 PiP

系统画中画收起的是**整个 Activity**。本应用是单 Activity 的 Flutter 工程，
一旦进系统 PiP，应用内其它页面全都不可见（moonlight-android 能"PiP 时继续
浏览"，是因为它的串流跑在独立的 `Game` Activity 里，主界面是另一个 Activity，
两者不在同一个任务窗口里）。要在本应用里做到"只收起播放页"，只能把播放器
收进应用自己的浮窗。

### 实现

* 浮窗插在 **root Overlay**（`Get.key.currentState.overlay`）上，位于**所有路由
  之上**：之后无论返回、切底部 Tab、进任意新页面，小窗都还在播、还能拖动。
* 播放页出栈时通过 `PlPlayerController.floatingKeepAlive` 跳过播放器销毁，
  mpv 实例与 `VideoController` 都活着；小窗里用同一个 `Texture`
  （media_kit `SimpleVideo`）继续渲染，**不重新拉流、不重新缓冲**。
* 引用计数同步归还（`releasePageSlotForFloating`）：否则"播放页 → 小窗 →
  回播放页"会让 `_playerCount` 变成 2，用户第二次退出播放页时 dispose 只减到 1
  就返回，播放器不销毁（退出后声音还在、局域网还在拉流）。
* 点小窗画面或「展开」按钮 = 回到播放页：用**原样保存的路由参数**重新进页，
  带上当前实时进度（本地媒体走 `startAt`，优先于 5 秒一存的本机记录，
  否则"在小窗里看了半小时，回播放页跳回半小时前"）；播放器是单例复用的，
  装载同一条流，原位续播。
* 点「关闭」= 正常销毁播放器。
* 小窗期间补一份续播进度落盘（播放页那个 5 秒定时器随页面销毁了）。
* 打开新播放页 / 直播间前会自动收掉旧小窗（播放器是单例，不能被两个页面抢）。
* 小窗UI：16:9 画面 + 标题栏（播放/暂停、展开、关闭），可拖拽，
  位置限制在屏幕内，默认停右下角（避开系统手势区）。
* 入口：播放器顶栏「画中画」按钮**点按 = 应用内小窗**；
  **长按 = 系统画中画**（离开应用时用，行为与以前一致）。
  设置里的「自动画中画」（按 Home 自动进系统 PiP）保持不变。

### 装机验证要点（需求 3）

- [ ] 全屏播放 → 顶栏「画中画」按钮点按 → 播放页收起成右下角小窗，
      **画面继续播、声音不断、没有重新缓冲**。
- [ ] 小窗存在时：可以返回首页、切到「本地」板块、进目录浏览、进设置页 ——
      小窗始终浮在最上层且一直在播。
- [ ] 从其它页面再进一个新的视频页：旧小窗自动关闭（不会两个播放器打架）。
- [ ] 拖小窗到屏幕四角/边缘：不会被拖丢（会夹在屏幕内）。
- [ ] 点小窗画面或「展开」→ 回到播放页，进度接上（本地文件误差应在 1~2 秒内；
      在线视频会有一次重新装载，属预期）。
- [ ] 小窗里暂停/播放按钮生效；小窗里看了 1 分钟再关闭，重新进那个本地文件
      应从看过的位置续播（进度落盘生效）。
- [ ] 小窗存在时按系统返回键：只是返回下层页面，小窗不消失（预期）。
- [ ] **长按**顶栏画中画按钮 → 进系统画中画（整个应用收起），行为同以前；
      按 Home 且开了「自动画中画」→ 仍进系统 PiP。
- [ ] 直播间的画中画按钮保持原行为（本轮未改）。

---

## 4. 需求 4：VR 模式截图按钮误触

VR 操作模式下，`VrControlLayer` 的右侧按钮列（视场角 +/-、视角摆正、陀螺仪、
眼位）与播放器 UI 右侧的截图按钮在同一位置，而截图按钮在控件树上**位于 VR 层
之上**，拖拽环视时经常误触截图。

处理：VR 操作模式期间**整块隐藏**截图按钮（含长按动态截图）。
需要截图时点顶部读数条退出 VR 操作模式即可；外接键盘的截图快捷键不受影响。

### 装机验证要点（需求 4）

- [ ] 进 VR 片源 → VR 操作模式：右侧只有 VR 的 5 个圆按钮，**没有**相机图标；
      拖拽环视不会误触截图/弹"截图中"提示。
- [ ] 点顶部读数条退出 VR 操作模式：相机按钮回来，截图/长按动态截图正常。
- [ ] 普通（非 VR）视频全屏：截图按钮照旧显示、可用。

---

## 5. 需求 5：VR 操作模式的手柄控制

摇杆是 `MotionEvent` 的**模拟轴**，Flutter 只把 `KeyEvent` 送进 Dart，
模拟轴不会过桥 —— 所以：

* `MainActivity.dispatchGenericMotionEvent` 把最新摇杆读数缓存在 native 侧
  （`Gamepad.kt`：右摇杆 = `AXIS_Z`/`AXIS_RZ`，另存左摇杆与 hat）；
* VR 操作模式挂载期间（`VrControlLayer`）用 `GamepadPoller` 以 50Hz 轮询
  MethodChannel `piliplus/gamepad` 读取，带**死区 0.15**、
  角速度积分（满偏 110°/s）、时间片夹取（≤0.25s，防止掉帧后视角瞬移）、
  陈旧读数丢弃（>300ms 视为手柄已拔）；上一帧没回来就跳过这一帧
  （避免请求排队造成"松手后视角还在飘"）。
* 按键走既有 KeyEvent 通道：`△`（安卓 `KEYCODE_BUTTON_Y` → `gameButtonY`）
  = 视角摆正；`□`（`KEYCODE_BUTTON_X` → `gameButtonX`）= 切换眼位
  （单目片源明确提示"没有左右眼可切换"，不静默失效）。
  长按产生的 `KeyRepeatEvent` 不会重复触发。
* 这些 VR 手柄操作**不点亮播放器控件层**（`controls` 不被置 true），
  符合"手柄操作不应唤起播放器 UI"。
* 方向与单指拖拽同一套语义：摇杆推右 = 视线向右（yaw 增大），
  推上 = 视线向上（pitch 减小）。
* 进入 VR 操作模式的提示文案已加一行手柄说明。

### 装机验证要点（需求 5）

- [ ] 连手柄（PS/Xbox 均可）→ 进 VR 操作模式 → 右摇杆：
      推右转右、推上转上、推满约 3.3 秒转一圈；松手立刻停（不漂移）。
- [ ] 摇杆静置时画面**不应**缓慢漂移（死区生效）。
- [ ] `△`/Y：视角回正（偏航/俯仰归零，HUD 读数变 0）。
- [ ] `□`/X：左右眼切换（双目片源画面应明显变化）；单目片源弹提示。
- [ ] 以上手柄操作期间，播放器顶栏/底栏**不应**被唤出。
- [ ] 触屏操作（单指拖拽/双指缩放）与手柄可以同时用，互不干扰。
- [ ] 退出 VR 操作模式后，手柄的十字键/肩键仍是原来的语义
      （左右快退快进、上下音量、L1/R1 ±60s）。
- [ ] 拔掉手柄后再插：仍能工作（陈旧读数不会让视角乱转）。

---

## 6. 改动清单（文件级）

新增：

* `android/app/src/main/kotlin/com/example/piliplus/SafBrowser.kt` — SAF 桥
  （列目录 / 已授权树 / 授权与撤销 / 所有文件访问权限）
* `android/app/src/main/kotlin/com/example/piliplus/Gamepad.kt` — 摇杆轴缓存
* `lib/services/saf/saf_bridge.dart` — Dart 侧 SAF 桥 + fd 记账本 + docId 纯函数
* `lib/services/floating_player.dart` — 应用内画中画浮窗服务与窗口 UI
* `lib/plugin/pl_player/utils/gamepad.dart` — 摇杆轮询器 + `GamepadMath`
* `test/services/saf_test.dart`、`test/plugin/vr_gamepad_test.dart` — 新增单测

修改：

* `android/app/src/main/kotlin/.../MainActivity.kt` — 注册 SAF/手柄通道、
  `onActivityResult`（文件夹选择器）、`dispatchGenericMotionEvent`、fd LRU 4→8 + `closeAllFds`
* `android/app/src/main/AndroidManifest.xml` — `MANAGE_EXTERNAL_STORAGE`、
  `READ_MEDIA_VISUAL_USER_SELECTED`
* `lib/services/local_media_service.dart` — SAF 分派、直读硬化、`resolvePlayUrl`
  的 `content://`→`fd://`、`displayPath`/`safLabel`/`safSources`/`pickSafSource` 等
* `lib/models/local_media/local_media_source.dart` — `isSafTree`、`subPath`、`rootPath`
* `lib/pages/local_media/{view,controller,browser}.dart` — 本机存储分区重写、
  受限直读的选择框、面包屑、去掉 `..`、SAF fd 回收、收藏判定
* `lib/pages/video/introduction/local_media/{view,controller}.dart` — 播放列表
  焦点跟随 + 表头检索
* `lib/pages/video/view.dart` — 播放列表表头挂载、小窗保活时的出栈清理
* `lib/pages/video/controller.dart` — `initLocalMediaSource(startAt:)`
* `lib/pages/video/widgets/header_control.dart` — 画中画按钮改为应用内小窗（长按=系统 PiP）
* `lib/pages/video/widgets/player_focus.dart` — VR 模式手柄按键
* `lib/plugin/pl_player/controller.dart` — `floatingKeepAlive`、
  `releasePageSlotForFloating`、`onVrGamepadLook`、`toggleVrEye`、提示文案
* `lib/plugin/pl_player/view/view.dart` — VR 模式隐藏截图按钮
* `lib/plugin/pl_player/widgets/vr_control_layer.dart` — 挂载摇杆轮询
* `lib/utils/page_utils.dart` — 打开新播放页/直播间前收掉小窗

---

## 7. 已知取舍与后续可做

1. **小窗回播放页会重新装载一次流**（本地文件几乎无感；在线视频会有一次
   重新缓冲）。要完全无缝需要把 `VideoDetailController` 一起保活并跳过
   `setDataSource`，改动面大、回归风险高，本轮选择稳妥路径。
2. **SAF 授权是按文件夹的**：想让整个存储都可见，要么在选择器里授权
   「内部存储」根，要么开「所有文件访问权限」。这是安卓的限制，不是应用偷懒。
3. 小窗目前是 16:9 固定比例（竖屏视频会有黑边）；后续可按片源比例自适应。
4. 直播间未接应用内小窗（仍走系统 PiP）。
5. 手柄左摇杆轴值已经取到但暂未绑定功能（可用于音量/进度，视需要再加）。
