import 'package:PiliPlus/models/common/enum_with_label.dart';

/// 画中画的实现方式(第二十二轮新增设置项, 第二十三轮改默认值与文案)。
///
/// 三种实现的差别来自一条 Flutter 平台硬约束: **一个 FlutterEngine 同一时刻
/// 只渲染一个 Activity**(`FlutterEngineConnectionRegistry.attachToActivity`
/// 会把前一个 Activity 直接 detach 掉, 它的 FlutterView 立刻变空白)。于是:
///
/// * 想让系统 PiP 窗口里是**整个 Flutter 播放页**(控件/弹幕/VR 层都在),
///   就必须让"持有引擎的那个 Activity"进 PiP —— 也就是 [systemWholeApp]。
///   此时主界面没有引擎可渲染, PiP 期间**不能**在应用内继续浏览。
/// * 想让 PiP 期间**还能在应用内浏览**, 引擎就必须留在主 Activity,
///   PiP 窗口只能由 native 渲染画面 —— 也就是 [systemWindow]
///   (独立 PiP Activity + 把 mpv 的 `--wid` 交接过去) 或 [inAppFloat]
///   (应用内浮窗, 复用主 Activity 的引擎与纹理)。
/// * 两者都要, 只能上第二个引擎(FlutterEngineGroup): 代价是第二个 isolate
///   不能与主 isolate 同时打开同一个 Hive 盒子(存储层要重构)、第二个 mpv
///   实例、进 PiP 时视频要在第二个 isolate 里重新起播。
///
/// **只能追加, 不能插队或改序**: 设置里持久化的是 [index]。
enum PipStyle implements EnumWithLabel {
  /// 系统画中画·独立窗口: 画面由 mpv 直接渲染到独立 PiP Activity 的
  /// TextureView(`--wid` 交接), 主 Activity 留着引擎 ⇒ 系统级小窗(可出应用、
  /// 可拖动缩放、有系统媒体按钮) **且** 应用内可继续浏览。
  /// 代价: 窗口里只有画面(字幕有, 是 mpv 渲染进画面的), 没有 Flutter 控件层
  /// 与弹幕; 且依赖 ROM 的 surface 行为, 交接失败时会自动退回 [inAppFloat]。
  systemWindow('系统画中画·独立窗口（可同时浏览应用）'),

  /// 应用内浮窗: 纯 Flutter 的 root Overlay 小窗, 复用主 Activity 的引擎与
  /// 纹理, **不做任何 surface 交接** ⇒ 兼容性最好、窗口里就是播放器画面。
  /// 代价: 不是系统 PiP, 出不了应用(离开应用就没有小窗)。
  inAppFloat('应用内浮窗（可同时浏览，不出应用）'),

  /// 系统画中画·整个播放页(**第二十三轮起为默认**): 由持有引擎的主 Activity
  /// 自己进系统 PiP, 应用此时只渲染播放页 ⇒ **窗口里就是整个播放页**
  /// (控件/弹幕/VR 层都在), 且完全没有 surface 交接(上游 PiliPlus 的老路,
  /// 最稳)。代价: PiP 期间主界面没有引擎, **不能**在应用内继续浏览;
  /// 点窗口的叉号会连同应用一起退出(系统对整应用 PiP 的标准行为)。
  systemWholeApp('系统画中画·整个播放页（最稳，不能同时浏览）'),
  ;

  @override
  final String label;
  const PipStyle(this.label);
}
