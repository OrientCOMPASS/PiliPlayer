import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/plugin/pl_player/utils/gamepad.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// VR 控制层。
///
/// 只有进入「VR 控制模式」后才会被挂到控件树上; 同时播放器视图的
/// `_onPointerDown` 在此模式下**不再把指针喂给底层的点击/双击/长按/拖拽
/// 识别器**(底层 MouseInteractiveViewer 仍是本层的 child, 命中测试还会
/// 路过它, 只是它的识别器不进竞技场), 因此手势由本层独占:
///   * 单指拖拽 = 环视(偏航/俯仰)
///   * 双指缩放 = 视场角
///   * 陀螺仪转动设备环视(见右侧按钮; 头追由定制 libmpv 在 native 侧
///     逐帧运行, Cardboard OrientationEKF, 参考 xl_player)
///   * 常规手势(左右进退、上下亮度/音量、上下滑全屏、双指缩放画面)全部让位
/// 同时提供屏幕按钮兜底(长按可连续转动), 以及实时视角读数,
/// 方便确认操作是否生效。方案参考 PiliPlus#364「切换操作模式」。
class VrControlLayer extends StatefulWidget {
  const VrControlLayer({
    super.key,
    required this.controller,
    required this.width,
    required this.height,
    required this.child,
  });

  final PlPlayerController controller;
  final double width;
  final double height;
  final Widget child;

  @override
  State<VrControlLayer> createState() => _VrControlLayerState();
}

class _VrControlLayerState extends State<VrControlLayer>
    with SingleTickerProviderStateMixin {
  /// 双指缩放开始时的视场角, 缩放按该基准做绝对映射(避免累积漂移)
  double _fovBase = VrViewState.kVrDefaultFov;

  /// HUD 有效视角轮询(手动偏移+折叠偏置+头姿的合成结果在 native 侧,
  /// Dart 只能读属性; getProperty 是同步往返, 5Hz 足够 HUD 显示又不至于
  /// 给 core/VO 线程添堵)
  Timer? _hudTimer;

  /// 手柄右摇杆采样(需求5): 摇杆是 MotionEvent 模拟轴, 不会自动进 Dart,
  /// 只能按固定节奏去 native 侧取最新读数(见 `utils/gamepad.dart`)。
  /// 只在本层挂载期间跑, 也就是**只在 VR 操作模式下**才采样。
  late final GamepadPoller _gamepad = GamepadPoller(onSample: _onGamepadSample);

  /// 最新一次摇杆采样(由帧 Ticker 消费)
  double _axisX = 0;
  double _axisY = 0;

  /// 上一帧的时间戳, 用来算真实帧间隔
  Duration _lastFrame = Duration.zero;

  /// 逐帧积分摇杆(需求6): 采样(≈100Hz)与推进(每帧)解耦之后, 手柄环视的
  /// 更新率与屏幕刷新率一致, 不再是"采样到一格走一格"。
  // 不写显式类型: Ticker 由 scheduler 库提供, 靠推断省一个 import
  late final _lookTicker = createTicker(_onFrame);

  PlPlayerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.vrHudAngles.value = null;
    _c.pollVrHudAngles();
    _hudTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _c.pollVrHudAngles(),
    );
    _gamepad.start();
    // Ticker 不常驻: 只有摇杆偏出死区时才跑(见 _onGamepadSample),
    // 否则暂停播放时也会一直泵帧, 白费电
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _hudTimer = null;
    _gamepad.stop();
    _lookTicker
      ..stop()
      ..dispose();
    super.dispose();
  }

  void _onGamepadSample(double x, double y) {
    _axisX = x;
    _axisY = y;
    // 死区内 = 摇杆没动: 停掉帧 Ticker(插值那边收敛完也会自己停)
    final moving = GamepadMath.axis(x) != 0 || GamepadMath.axis(y) != 0;
    if (moving && !_lookTicker.isActive) {
      _lastFrame = Duration.zero;
      _lookTicker.start();
    } else if (!moving && _lookTicker.isActive) {
      _lookTicker.stop();
    }
  }

  void _onFrame(Duration elapsed) {
    final previous = _lastFrame;
    _lastFrame = elapsed;
    if (GamepadMath.axis(_axisX) == 0 && GamepadMath.axis(_axisY) == 0) {
      return; // 摇杆在死区里: 什么都不做
    }
    if (previous == Duration.zero) {
      return; // 第一帧没有可靠的 dt
    }
    final dtSeconds = (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    if (dtSeconds <= 0) {
      return;
    }
    _c.onVrGamepadLook(_axisX, _axisY, dtSeconds);
  }

  void _onScaleStart(ScaleStartDetails details) {
    // 用目标值而不是"正在插值中的显示值"当基准: 否则连续捏合时基准一直在
    // 追自己, 缩放会越捏越慢(第二十轮 需求4 引入插值后必须这么改)
    _fovBase = _c.vrTargetFov;
    // 触屏操作唤醒控件(与播放器 UI 一致); 陀螺仪动作不产生触摸, 不唤醒
    _c.controls = true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // 拖拽期间保持控件可见(不断续自动隐藏计时)
    if (_c.showControls.value) {
      _c.hideTaskControls();
    }
    if (details.pointerCount > 1) {
      if (details.scale > 0) {
        _c.setVrFov(_fovBase / details.scale);
      }
      return;
    }
    _c.onVrLook(
      details.focalPointDelta.dx,
      details.focalPointDelta.dy,
      width: widget.width,
      height: widget.height,
    );
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // 手势结束强制落一次, 保证最终视角与手指位置一致
    _c
      ..applyVrView(force: true)
      ..hideTaskControls();
  }

  @override
  Widget build(BuildContext context) {
    // 上报渲染视口宽高比: 俯仰角的极点收敛边界依赖它
    // (与 mpv 侧 vr_manual_angles 同一公式, 双层兜底)
    _c.setVrViewport(widget.width, widget.height);
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _c.controls = !_c.showControls.value,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: widget.child,
        ),
        // 顶部: 视角读数 + 退出控制模式(随播放器控件一起自动隐藏)
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Obx(() {
              if (!_c.showControls.value) {
                return const SizedBox.shrink();
              }
              final view = _c.vrView.value;
              final error = _c.vrError.value;
              // 读数优先显示 native 的**有效**视角(含陀螺仪头姿与折叠
              // 偏置); 旧引擎没有该属性时回退显示手动分量
              final eff = _c.vrHudAngles.value;
              final yawShow = eff?.$1 ?? view.yaw;
              final pitchShow = eff?.$2 ?? view.pitch;
              return Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  _Chip(
                    onTap: () => _c.setVrControlMode(false),
                    icon: Icons.gesture_outlined,
                    label:
                        '${_c.vrProjection.value.label}  ·  '
                        '偏航 ${yawShow.toStringAsFixed(1)}°  '
                        '俯仰 ${pitchShow.toStringAsFixed(1)}°  '
                        '视场 ${view.fov.toStringAsFixed(0)}°  ·  点按退出VR操作',
                  ),
                  // VR 没生效时把原因摊开, 不要让用户面对"操作没反应"
                  if (error != null)
                    _Chip(
                      icon: Icons.error_outline,
                      label: error,
                      danger: true,
                    ),
                ],
              );
            }),
          ),
        ),
        // 右侧: 视场角 / 重置 / 眼位(随播放器控件一起自动隐藏;
        // 左侧方向步进按键已按第十三轮真机反馈移除: 单指拖拽环视已经
        // 覆盖全部视角操作, 方向键遮挡画面且与拖拽手势重复)
        Align(
          alignment: Alignment.centerRight,
          child: Obx(
            () => !_c.showControls.value
                ? const SizedBox.shrink()
                : Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _VrStepButton(
                  icon: Icons.zoom_in,
                  tooltip: '放大(视场角变小)',
                  onStep: () => _c.vrStep(dfov: -PlPlayerController.vrFovStep),
                ),
                _VrStepButton(
                  icon: Icons.zoom_out,
                  tooltip: '缩小(视场角变大)',
                  onStep: () => _c.vrStep(dfov: PlPlayerController.vrFovStep),
                ),
                _VrStepButton(
                  icon: Icons.center_focus_strong_outlined,
                  tooltip: '视角摆正',
                  repeat: false,
                  onStep: _c.resetVrView,
                ),
                Obx(
                  () => _VrStepButton(
                    icon: Icons.screen_rotation_outlined,
                    tooltip: _c.vrGyroEnabled.value
                        ? '陀螺仪环视: 开(点按关闭)'
                        : '陀螺仪环视: 关(点按开启)',
                    repeat: false,
                    active: _c.vrGyroEnabled.value,
                    onStep: () => _c.setVrGyro(!_c.vrGyroEnabled.value),
                  ),
                ),
                // (立体分屏输出按钮已随该功能一并移除, 见 controller 注释)
                Obx(
                  () => _c.vrProjection.value.isStereo
                      ? _VrStepButton(
                          icon: Icons.visibility_outlined,
                          tooltip: '切换眼位',
                          repeat: false,
                          onStep: () => _c.setVrEye(
                            _c.vrEye.value == VrEye.left
                                ? VrEye.right
                                : VrEye.left,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
                ),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    this.onTap,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: danger ? 0.75 : 0.55),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Icon(
                icon,
                size: 15,
                color: danger ? Colors.redAccent : Colors.white,
              ),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 支持"点一下走一步、按住连续走"的按钮
class _VrStepButton extends StatefulWidget {
  const _VrStepButton({
    required this.icon,
    required this.tooltip,
    required this.onStep,
    this.repeat = true,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onStep;
  final bool repeat;

  /// 开关型按钮的"已激活"高亮
  final bool active;

  @override
  State<_VrStepButton> createState() => _VrStepButtonState();
}

class _VrStepButtonState extends State<_VrStepButton> {
  Timer? _delay;
  Timer? _repeat;

  void _start() {
    widget.onStep();
    if (!widget.repeat) {
      return;
    }
    _delay = Timer(const Duration(milliseconds: 400), () {
      _repeat = Timer.periodic(
        const Duration(milliseconds: 110),
        (_) => widget.onStep(),
      );
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        child: Container(
          margin: const EdgeInsets.all(3),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: widget.active
                ? Colors.blue.withValues(alpha: 0.65)
                : Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
            border: widget.active
                ? Border.all(color: Colors.white54, width: 1.5)
                : null,
          ),
          child: Icon(widget.icon, size: 22, color: Colors.white),
        ),
      ),
    );
  }
}
