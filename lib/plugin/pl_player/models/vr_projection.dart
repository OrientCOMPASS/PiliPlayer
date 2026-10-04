import 'dart:math' as math;

import 'package:PiliPlus/models/common/enum_with_label.dart';

/// VR / 全景视频的片源布局。
///
/// 全景片源以等距柱状投影(equirectangular)存储, 播放时由本分支定制的
/// libmpv 在渲染链末端把平面画面重投影到球面(见 tool/libmpv-vr 与
/// docs/piliplayer.md §15)。本模型同时定义了 Dart 侧枚举到 mpv
/// `vr-layout` / `vr-projection` 属性值的映射。
///
/// 支持矩阵(需求 REQUIREMENTS.md 第 1 条): 水平覆盖 360°/180° ×
/// 立体布局 单目/左右(SBS)/上下(TB), 另加:
///   * [VrProjection.auto] —— 自动(按片源元数据): 文件加载后读取定制
///     libmpv 的 `vr-metadata-projection` / `vr-metadata-layout` 只读属性
///     解析成具体格式(见 [resolveMetadata]);
///   * [VrProjection.off] —— 强制平面(普通 2D), 不做任何重投影。
enum VrProjection with EnumWithLabel {
  off('强制平面（2D）'),
  auto('自动（元数据）'),
  equirect360('等距柱状 360°'),
  equirect180('等距柱状 180°'),
  sbs360('左右格式 360°'),
  tb360('上下格式 360°'),
  sbs180('左右格式 180°'),
  tb180('上下格式 180°'),
  ;

  @override
  final String label;
  const VrProjection(this.label);

  /// VR 重投影当前是否生效。[off] 是强制平面; [auto] 是"待解析"状态,
  /// 解析前按平面播放, 解析成功后 `vrProjection` 会变成具体格式,
  /// 因此二者都不算 enabled。
  bool get enabled => this != VrProjection.off && this != VrProjection.auto;

  /// 双目(3D)片源: 渲染时只取其中一只眼睛的画面
  bool get isStereo =>
      this == VrProjection.sbs360 ||
      this == VrProjection.tb360 ||
      this == VrProjection.sbs180 ||
      this == VrProjection.tb180;

  /// 左右格式(side by side): 两只眼睛的画面左右排列
  bool get isSideBySide =>
      this == VrProjection.sbs360 || this == VrProjection.sbs180;

  /// mpv `vr-layout` 属性值(片源立体布局)。
  /// [off]/[auto] 不会下发到 mpv(effective 状态永远不是二者), 仅为完备性
  /// 返回 mono。
  String get mpvLayout {
    if (isSideBySide) {
      return 'sbs';
    }
    if (this == VrProjection.tb360 || this == VrProjection.tb180) {
      return 'tb';
    }
    return 'mono';
  }

  /// mpv `vr-projection` 属性值(水平覆盖角)
  String get mpvCoverage => coverageH >= 360.0 ? '360' : '180';

  /// 水平覆盖角度, 360° 片源可以无限水平旋转, 180° 片源需要在边界处收敛。
  /// [off]/[auto] 不参与环视, 返回 360 仅作中性值。
  double get coverageH =>
      this == VrProjection.equirect180 ||
          this == VrProjection.sbs180 ||
          this == VrProjection.tb180
      ? 180.0
      : 360.0;

  /// 垂直覆盖角度, 等距柱状投影固定为 180°
  double get coverageV => 180.0;

  /// 偏航角(yaw)的可活动范围, 单位: 度
  ({double min, double max}) yawRange(double fov) {
    if (coverageH >= 360.0) {
      return (min: -180.0, max: 180.0);
    }
    // 180° 片源: 视口不能越过片源边界, 否则会出现黑边
    final limit = (coverageH - fov) / 2;
    return (min: -limit, max: limit);
  }

  /// 根据文件名猜测片源布局。
  ///
  /// 只认明确的关键词, 并且对 `360`/`180`/`vr`/`3d`/`tb` 这类容易误伤的短词
  /// 做词边界匹配(否则清晰度 `360p`、`1080p` 会被误判成全景片源)。
  /// 宽高比不作为判据: 2:1 也可能是普通宽银幕视频。
  ///
  /// 识别不到时回退 [VrProjection.auto](按片源元数据识别, 需求第 5 条),
  /// 而不是直接判定为平面: 文件名没有关键词 ≠ 片源不是全景。
  static VrProjection detectFromName(String name) {
    final n = name.toLowerCase();
    // 字母边界匹配, 允许数字紧邻(如 `360vr`)
    bool word(String key) => RegExp('(^|[^a-z])$key([^a-z]|\$)').hasMatch(n);
    // 数字关键词: 排除 `360p` / `1080p` 这类清晰度写法
    bool numberWord(String key) =>
        RegExp('(^|[^0-9])$key([^0-9p]|\$)').hasMatch(n);
    bool has(List<String> keys) => keys.any(n.contains);

    final is180 = numberWord('180');
    final is360 = numberWord('360');
    final isVr = word('vr') || has(['全景']);

    final sbs =
        word('sbs') ||
        has(['左右格式', '左右3d', '3d左右', 'lr3d', '3dlr', '左右']);
    final tb =
        word('tb') ||
        word('ou') ||
        has(['over-under', 'over_under', '上下格式', '上下3d', '3d上下', '上下']);

    final pano =
        isVr ||
        is360 ||
        is180 ||
        word('pano') ||
        has(['equirect', 'equi-angular', 'panoram', 'spherical']);
    // 只有 `3d` 字样无法判断片源布局, 不乱猜
    if (!pano && !sbs && !tb) {
      return VrProjection.auto;
    }

    // tb 与 sbs 同时出现时以 sbs 为准(更常见的命名)
    if (tb && !sbs) {
      return is180 && !is360 ? VrProjection.tb180 : VrProjection.tb360;
    }
    if (sbs) {
      return is180 && !is360 ? VrProjection.sbs180 : VrProjection.sbs360;
    }
    return is180 && !is360
        ? VrProjection.equirect180
        : VrProjection.equirect360;
  }

  /// 解析定制 libmpv 报告的片源元数据(`vr-metadata-projection` /
  /// `vr-metadata-layout` 只读属性, 由 vr_metadata.patch 从 mov `sv3d`/`st3d`/
  /// `prji` 与 mkv `Projection`/`StereoMode` side data 提取)。
  ///
  /// 取值(与 mpv 侧 player/command.c 的映射一一对应):
  ///   * [projection]: `360` / `180` / `cubemap` / `other` / `none`
  ///   * [layout]: `sbs` / `tb` / `mono` / `other` / `none`
  ///
  /// cubemap 与非等距柱状投影、棋盘格等立体排布在需求范围外(第 9 条),
  /// 返回 [VrAutoResolution.unsupported], UI 必须明确提示而不是静默失效
  /// (第 8 条)。
  static VrAutoResolution resolveMetadata({
    required String projection,
    required String layout,
  }) {
    switch (projection) {
      case '360':
      case '180':
        final is360 = projection == '360';
        switch (layout) {
          case 'sbs':
            return VrAutoResolution.vr(
              is360 ? VrProjection.sbs360 : VrProjection.sbs180,
            );
          case 'tb':
            return VrAutoResolution.vr(
              is360 ? VrProjection.tb360 : VrProjection.tb180,
            );
          case 'mono':
          case 'none':
          case '':
            return VrAutoResolution.vr(
              is360 ? VrProjection.equirect360 : VrProjection.equirect180,
            );
          default:
            return const VrAutoResolution.unsupported(
              '不支持该立体排布(棋盘格/交织等), 已按普通视频播放',
            );
        }
      case 'cubemap':
        return const VrAutoResolution.unsupported(
          '不支持 cubemap 立方体全景片源, 已按普通视频播放',
        );
      case 'none':
      case '':
        return const VrAutoResolution.flat();
      default:
        return const VrAutoResolution.unsupported(
          '不支持该全景投影类型(鱼眼/矩形等), 已按普通视频播放',
        );
    }
  }
}

/// [VrProjection.resolveMetadata] 的解析结果。
class VrAutoResolution {
  /// 识别为可渲染的全景片源
  const VrAutoResolution.vr(this.projection) : unsupportedReason = null;

  /// 没有全景元数据(或元数据明确是平面): 按普通视频播放, 无需提示
  const VrAutoResolution.flat()
    : projection = VrProjection.off,
      unsupportedReason = null;

  /// 识别到全景/立体元数据但渲染器不支持(范围外格式): 必须明确提示
  const VrAutoResolution.unsupported(this.unsupportedReason)
    : projection = VrProjection.off;

  /// 生效的片源布局, [VrProjection.off] 表示平面播放
  final VrProjection projection;

  /// "识别到但不支持"的原因文案; 非 null 时 UI 必须提示用户
  final String? unsupportedReason;

  bool get isVr => projection.enabled;
}

/// 双目片源要渲染哪一只眼睛(手机端为单屏显示, 只取一只)
enum VrEye with EnumWithLabel {
  left('左眼'),
  right('右眼'),
  ;

  @override
  final String label;
  const VrEye(this.label);
}

/// 视角参数。yaw/pitch 单位为度, fov 为水平视场角(度)。
class VrViewState {
  /// 默认水平视场角: 手机竖屏/平板横屏下接近人眼舒适范围
  static const double kVrDefaultFov = 90.0;
  static const double minFov = 25.0;

  /// 第十六轮: 上限对齐 native `vr-fov` 值域(10~180)。注意 fov>~160 时
  /// native 的背面剔除(w<=0 整三角形丢弃)在视锥边缘可能出现小块空洞
  /// (极端放大的已知边界, 见 tool/libmpv-vr/README.md), 常规视场不受影响。
  static const double maxFov = 180.0;

  /// 陀螺仪模式下手动俯仰分量的上限(需求允许放宽收敛)
  static const double maxPitch = 89.0;

  const VrViewState({
    this.yaw = 0,
    this.pitch = 0,
    this.fov = VrViewState.kVrDefaultFov,
  });

  final double yaw;
  final double pitch;
  final double fov;

  /// 水平视场角 + 视口宽高比 -> 垂直视场角(度)。
  /// 与 mpv 侧 `vr_fovy_from_hfov`(vr.c) 的换算一致, 用于俯仰收敛:
  /// 视口垂直方向不能越过等距柱状图的极点, 否则转出画面见黑。
  /// [aspect] 未知时按 1.0 处理(比常见横屏更保守, 收敛更紧, 不会露黑边)。
  static double verticalFov(double hfov, double? aspect) {
    final a = (aspect == null || aspect < 0.01) ? 1.0 : aspect;
    final halfH = math.tan(hfov * math.pi / 360.0);
    final vfov = 2 * math.atan(halfH / a) * 180.0 / math.pi;
    return vfov.clamp(1.0, 179.0);
  }

  /// 手动俯仰的收敛边界(±), 与 mpv 侧 `vr_manual_angles` 的兜底一致
  static double pitchLimit(double fov, double? aspect) =>
      math.max(0.0, 90.0 - verticalFov(fov, aspect) / 2);

  /// 夹取视角(VR_FREE_LOOK, 第十六轮)。
  ///
  /// 需求方明确**放开拖拽角度限制**: 180° 片源的覆盖边界收敛与俯仰
  /// "视口不越过极点"收敛全部移除——转出覆盖范围看到黑边已被接受
  /// (推翻 REQUIREMENTS.md 第 3 条的收敛要求, 由需求方本轮拍板)。
  /// 只保留数学上必要的界限, 与 native `vr_manual_angles` 完全一致:
  ///   * 偏航回绕到 [-180, 180)(避免数值无限增长);
  ///   * 俯仰 ±[maxPitch](等距柱状的极点是硬奇异, 也是选项值域);
  ///   * fov 夹到 [minFov, maxFov]。
  /// 手动与陀螺仪模式规则相同([gyro]/[projection]/[aspect] 保留签名兼容,
  /// 不再参与夹取)。
  VrViewState clamped(
    VrProjection projection, {
    double? aspect,
    bool gyro = false,
  }) {
    return VrViewState(
      yaw: wrap180(yaw),
      pitch: pitch.clamp(-maxPitch, maxPitch),
      fov: fov.clamp(minFov, maxFov),
    );
  }

  /// 把角度回绕到 [-180, 180)
  static double wrap180(double value) {
    var v = value % 360.0;
    if (v > 180.0) v -= 360.0;
    if (v < -180.0) v += 360.0;
    return v;
  }

  /// 两个偏航角之间的**最短有向差**(结果落在 [-180, 180))。
  ///
  /// 360° 片源的偏航会不断回绕(…179° → -179°…), 插值时如果直接
  /// `to - from` 会得到 -358°, 画面就沿着"远路"倒转一整圈。逐帧平滑
  /// (第二十轮 需求4)必须按最短角路径走。
  static double shortestDelta(double from, double to) => wrap180(to - from);


  VrViewState copyWith({double? yaw, double? pitch, double? fov}) => VrViewState(
    yaw: yaw ?? this.yaw,
    pitch: pitch ?? this.pitch,
    fov: fov ?? this.fov,
  );

  @override
  String toString() =>
      'yaw=${yaw.toStringAsFixed(1)} pitch=${pitch.toStringAsFixed(1)} '
      'fov=${fov.toStringAsFixed(1)}';
}
