import 'package:PiliPlus/models/common/enum_with_label.dart';

/// 画中画的实现方式(第二十二轮新增设置项)。
///
/// 之所以做成可选: "系统 PiP + 应用内可继续浏览"这条路要把 mpv 的渲染目标
/// (`--wid`)在 Flutter 纹理与独立 PiP Activity 的 SurfaceView 之间交接,
/// 依赖厂商 ROM 的窗口/surface 行为, 真机差异大。出问题时用户能自己切一种
/// 立刻可用的, 不必等下一版。
///
/// **只能追加, 不能插队或改序**: 设置里持久化的是 [index]。
enum PipStyle implements EnumWithLabel {
  /// 系统画中画(独立 PiP Activity): 画面由 mpv 直接渲染到该窗口的 SurfaceView,
  /// 主 Activity 留在原任务里 ⇒ 系统级小窗(可出应用、可拖动缩放、有系统媒体
  /// 按钮) **且** 应用内可继续浏览。与 moonlight-android 的 Game Activity 同结构。
  systemWindow('系统画中画（独立窗口，可继续浏览应用）'),

  /// 应用内浮窗: 纯 Flutter 的 root Overlay 小窗, 不做任何 surface 交接,
  /// 兼容性最好; 但不能出应用(离开应用就没有小窗了)。
  inAppFloat('应用内浮窗（不出应用，兼容性最好）'),

  /// 整应用系统画中画(上游 PiliPlus 的老行为): 收起的是**整个应用**,
  /// PiP 期间无法在应用内浏览, 但可以出应用。
  systemWholeApp('系统画中画（整个应用，老行为）'),
  ;

  @override
  final String label;
  const PipStyle(this.label);
}
