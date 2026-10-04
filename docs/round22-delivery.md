# 第二十二轮交付说明 + 装机测试清单（修 r21 真机故障）

> **⚠️ 第二十五轮起本文的「画中画」章节全部作废**：应用内浮窗、独立 PiP Activity、
> 「画中画样式」设置等实现已整体回退到上游原版（见 `docs/round25-delivery.md`）。
> 本文仅作决策记录保留，其中非画中画的部分（SAF 浏览、播放列表、播放/字幕记忆、
> 手柄、VR）仍然有效。

> 前几轮：`docs/round19-delivery.md`、`round20-delivery.md`、`round21-delivery.md`。
> 本轮针对你真机反馈的 4 个问题：**画中画暂停 / 画面与黑屏来回闪烁 / 点叉号闪退 /
> 拖拽 VR 镜头画面撕裂**。
>
> CI 全绿（analyze 0 error、STRICT_PATHS 零容忍 No issues、flutter test 全通过、
> release APK（arm64-v8a）构建 + 签名核验通过）。版本号仍未 bump（`2.1.5+2`）。

---

## 一、拖拽 VR 镜头画面撕裂 → 已 revert 回 r19

按你的要求，把第二十/二十一轮对"手动环视下发"的两处改动**整块回退**到 r19 那版
（r19 是你真机验证过没问题的版本）：

| 项 | r20/r21（已回退） | r22 = r19 |
|---|---|---|
| `applyVrView` 下发节奏 | `scheduleFrameCallback` 每帧一次 + 慢设备隔帧 | **30ms 节流 + 尾随补发**（`vrApplyIntervalMs`/`_vrApplyTimer`） |
| 视角状态 | `_vrTarget`（输入目标）+ `vrView`（每帧指数趋近的显示值） | **只有 `vrView`**，输入直接写 |
| 拖拽/步进/缩放 | 改目标，画面插值 | 直接写 `vrView.value` 后 `applyVrView()` |
| 摇杆推进 | 100Hz 采样 + 帧 Ticker 逐帧积分 | **20ms 轮询即积分**（`GamepadPoller(onAxes:)`） |
| 缩放基准 | `vrTargetFov` | `vrView.value.fov` |
| VrControlLayer | `SingleTickerProviderStateMixin` + Ticker | 无 Ticker |

保留（与 r19 行为一致，只是位置变了）：`GamepadMath`（死区 0.15 / 满偏 110°/s /
方向约定 / dt 夹取）——r19 的手感就是这套常数；`VrViewState.wrap180/shortestDelta`
（纯函数，`clamped()` 的回绕行为与 r19 完全相同）。

r21 的其它内容**都保留**：× 键播放暂停、字幕记忆、长按连发已 revert、
VR 模式隐藏截图按钮、手柄右摇杆/△/□。

## 二、点画中画叉号 → app 闪退（根因已定位）

`onStop → surfaceDestroyed → onDestroy` 是**同一次主线程调用序列**，而我当时把
"通知 Dart"写成了 `mainHandler.post{...}` —— 消息要等这一串全部跑完才发得出去。
于是 Dart 收到"surface 要没了"的时候，Surface 早已被系统回收，mpv 还在往那块
死窗口渲染 ⇒ use-after-free ⇒ 闪退。（"展开"能正常返回，正是因为展开路径不走
surfaceDestroyed。）

修法：

- Kotlin 侧 `notifyDart` 改成**同步 `invokeMethod`**（这些回调本来就在主线程；
  消息投递到 Dart 的 UI 线程，不需要主线程继续转），`surfaceDestroyed` 之后再等
  200ms 让 Dart 把 `vo=null / wid=0` 落下去，然后才释放 JNI 引用。
- Dart 侧 `surfaceLost` **无条件**先摘除（不受"我们自己发起的收尾"标志影响，
  摘除永远是安全的），整个事件处理包 try/catch，任何异常都不会把 mpv 留在死窗口上。
- 关闭顺序固定为：摘 surface → 销毁播放器 → finish 窗口 → 回收 SAF 的 fd。

## 三、进画中画后视频被暂停

启动 `PipActivity` 会让主 Activity 短暂 `onPause` → Flutter 收到 `paused` →
`PLVideoPlayer.didChangeAppLifecycleState` 里那句"退后台就暂停"（受
「后台继续播放」设置控制）把视频停了；而播放页随后就出栈了，**再没有人来恢复它**。

修法（三重）：

1. `floatingKeepAlive` 保活标记**提前到启动 PiP Activity 之前**置上；
2. `PLVideoPlayer.didChangeAppLifecycleState` 在 `floatingKeepAlive` 为真时直接返回
   （画面正在交接，这不是"退后台"）；
3. 交接完成后按"进 PiP 前的播放状态"补一次 `play()`（万一已经被停掉）。

## 四、画面与黑屏来回闪烁（三处一起修）

1. **正反馈回路**：r20 我加了"监听 `videoParams` 事件后把 wid 抢回来"，但我们那次
   `vo=null → vo=gpu` 自己又会引发新的事件，与 media_kit 内部的监听互相触发 ⇒
   黑屏/画面交替。已删除，改为交接后在 **200ms / 800ms / 2s 三个固定点各检查一次**：
   先读 mpv 当前的 `wid`，**只有发现不在我们手里才重接**（幂等，不构成回路；
   能不动就不动，因为每次重接都会黑一下）。
2. **`android-surface-size`**：media_kit 会把它设成片源尺寸（它那边是 SurfaceTexture，
   必须显式给缓冲尺寸）。接到 PiP 的 SurfaceView 时改传 `0x0`（= 跟随窗口大小），
   否则等于让系统把 4K 缓冲塞进一个小窗；交还 Flutter 纹理时再把原值还原。
3. **不要两套进入路径**：`onResume` 里原本 `setAutoEnterEnabled(true)` 又显式
   `enterPictureInPictureMode()`，系统可能再触发一次进入导致窗口来回重建。
   现在显式进入时 `autoEnter=false`；只有"用户展开之后"才打开 autoEnter
   （这样展开态按 Home 还能重新缩回小窗）。

## 五、新增：画中画诊断日志

整条链路都打了 `[pip]` 前缀的日志（release 的日志级别是 warning，所以用 `logger.w`）：
交接前的 `flutterWid/vo/android-surface-size`、启动 PiP Activity 的结果、拿到的
PiP surface wid、**每一个** native 事件（surfaceReady/Changed/Lost/pipModeChanged/
expanded/closed/failed）、"wid 被抢走后重新接回"、展开/关闭的收尾动作、各种失败原因。

> 再出问题时：「设置 → 日志」开启日志 → 复现一次 → 把 `[pip]` 开头的记录发我，
> 就能直接定位（不用再靠猜）。

---

## 装机测试清单

### A. 画中画（本轮重点，务必逐条过）

- [ ] 播放中点顶栏画中画（**点按**）→ 出现系统 PiP 窗口，**视频继续播**（不暂停、
      声音连续、进度在走）
- [ ] PiP 窗口画面**稳定**：不与黑屏来回闪烁；拖动/缩放窗口后画面仍正常（不黑屏）
- [ ] 主界面可以继续点：回首页、切「本地」、进目录浏览、进设置，PiP 一直在最上层播
- [ ] 点 PiP 窗口的 **X**（或把它划到关闭区）→ 播放停止、**app 不闪退**、无残余声音；
      之后应用一切正常（能再开视频）
- [ ] 点 PiP 窗口的**展开** → 回到播放页，画面与进度接上（本地文件误差 1~2 秒内）
- [ ] PiP 存在时按 **Home** → 桌面继续播；点应用图标能回到应用（PiP 仍在）
- [ ] PiP 存在时从应用里**再开一个视频** → 旧 PiP 自动关闭，新视频正常播
- [ ] PiP 窗口的系统按钮：快退 / 播放暂停 / 快进 都有效
- [ ] 竖屏视频进 PiP：比例正常、画面不变形
- [ ] 4K / 高码率片源进 PiP：不黑屏、不卡死（本轮把 surface 缓冲尺寸交回系统了）
- [ ] **暂停**状态进 PiP → 仍是暂停（不会被强制播放）；播放状态进 PiP → 继续播
- [ ] 展开后再进 PiP、反复 3~5 次：不出现黑屏/闪烁/崩溃
- [ ] 进 PiP → 关闭 → 再进 PiP：正常
- [ ] 「自动画中画」设置开着时按 Home：仍是老的整应用系统 PiP；
      且点了画中画按钮后**不会**再多出一个主 Activity 的小窗
- [ ] **长按**画中画按钮 = 应用内浮窗：能播、能拖、能展开回播放页、关闭后无残声
- [ ] 若开了「设置 → 日志」，复现一次问题后能看到 `[pip]` 记录（有问题请把它们发我）

### B. VR 环视（回到 r19 手感）

- [ ] 手指拖拽环视：**不再撕裂**，手感与你验证过的 r19 一致
- [ ] 快速甩动、来回拖：无撕裂、无卡顿、无残影
- [ ] 右摇杆环视：方向正确（推右看右、推上看上），松手立刻停、静置不漂移
- [ ] 双指缩放视场角：连续捏合速度均匀
- [ ] 屏幕上的 VR 步进按钮：点一下走一步、**按住连续走**（这是屏幕按钮自带的行为，
      与已 revert 的手柄长按连发无关）
- [ ] △ 摆正、□ 切眼位、VR 模式下截图按钮不出现、手柄操作不唤起播放器 UI
- [ ] 陀螺仪 + 手动叠加正常；HUD 读数与画面一致
- [ ] 180° 片源手动偏航到边界的表现与 r19 一致

### C. r21 的内容（真机若还没测过，一并过）

- [ ] 全屏时按 DS 手柄 **×** → 播放/暂停切换（有浮层反馈）；非全屏按 × 不触发；
      长按 × 不反复切换；Xbox 的 A 同样生效；○ 仍是返回
- [ ] 字幕记忆：多条内嵌字幕选第 2 条 → 退出重进仍是第 2 条；
      同目录 `movie.srt` + `movie.chs.ass` 选 chs → 重进仍是 chs；
      手动关字幕 → 重进仍关闭；没动过字幕的视频重进仍是默认策略；
      把外置字幕改名后重进 → 回默认策略（不应变成没字幕或报错）
- [ ] 倍速 / VR 布局 / 眼位 / 视场角 / 陀螺仪 记忆仍生效
- [ ] VR 模式下十字键 = 快退快进 / 音量（长按连发已 revert，不应有连发）

### D. 回归（r19/r20）

- [ ] 本机浏览：SAF 授权目录能看到全部文件；无 `..` 行；面包屑可点回跳；
      播放/续播/外挂字幕/检索含子目录；「本机存储」里没有「选择本机文件夹…」常驻行
- [ ] 播放列表：切集焦点自动跟随；表头搜索实时过滤、计数正确、点结果能播

## 已知取舍（不变）

1. PiP 窗口里是 mpv 直出的画面（**含字幕**，字幕是 mpv 渲染进画面的）+ 系统媒体按钮，
   没有 Flutter 那层控件与弹幕。要在系统 PiP 里看到 Flutter 播放页 UI，只能走
   "双引擎"方案（第二个 isolate 不能与主 isolate 同时打开同一 Hive 盒子 ⇒ 存储层要重构、
   第二个 mpv 实例、进 PiP 需重新起播），是多轮工程量的改造，详见
   `docs/round21-delivery.md` §5 的方案对比表。
2. 手动环视仍是 r19 的 30ms 节流（不做插值）：更新率低于陀螺仪（陀螺仪在 libmpv
   native 侧逐帧跑且有 33ms 前视预测）。要提更新率又不撕裂，正路是给 libmpv 补丁加
   `vr-look-velocity`（deg/s）在 native 逐帧积分（Dart 只在输入变化时写一次），
   需要改 C 补丁 + 跑 libmpv CI（冷构建 60~90 分钟）+ 改 vendored gradle 下载地址。
3. 播放设置记忆只覆盖本地/局域网媒体。
