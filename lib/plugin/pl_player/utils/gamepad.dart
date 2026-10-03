import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel, PlatformException;

/// 一次手柄摇杆采样。
///
/// 轴值语义与安卓一致: 右/下为 +1, 左/上为 −1, 静止为 0。
/// [stale] 表示这条读数太旧(手柄断开/很久没有事件), 不应再驱动视角。
class GamepadAxes {
  const GamepadAxes({
    required this.rightX,
    required this.rightY,
    required this.leftX,
    required this.leftY,
    required this.hatX,
    required this.hatY,
    required this.stale,
  });

  /// 右摇杆(安卓 AXIS_Z / AXIS_RZ) —— VR 环视用这一根
  final double rightX;
  final double rightY;

  /// 左摇杆(AXIS_X / AXIS_Y)
  final double leftX;
  final double leftY;

  /// 十字键的模拟量(AXIS_HAT_X / AXIS_HAT_Y)
  final double hatX;
  final double hatY;

  final bool stale;

  static const GamepadAxes zero = GamepadAxes(
    rightX: 0,
    rightY: 0,
    leftX: 0,
    leftY: 0,
    hatX: 0,
    hatY: 0,
    stale: true,
  );

  bool get hasRightStick => rightX != 0 || rightY != 0;
}

/// 手柄摇杆桥。
///
/// 摇杆是 `MotionEvent` 的**模拟轴**, Flutter 只把 `KeyEvent` 送进 Dart,
/// 模拟轴不会过桥 —— 所以 `MainActivity.dispatchGenericMotionEvent` 把最新
/// 读数缓存在 native 侧(`Gamepad.kt`), 这里按需轮询。
///
/// 按键(三角/方块/肩键…)不走这里: 它们是 KeyEvent, 由 `PlayerFocus` 处理。
abstract final class GamepadBridge {
  static const MethodChannel _channel = MethodChannel('piliplus/gamepad');

  /// 读数超过这个年龄就当作陈旧(手柄被拔掉时轴值会停在最后一次采样上)
  static const int staleAfterMs = 300;

  static bool get isSupported => Platform.isAndroid;

  /// 读一次摇杆。失败/非安卓返回 [GamepadAxes.zero](stale=true)。
  static Future<GamepadAxes> read() async {
    if (!isSupported) {
      return GamepadAxes.zero;
    }
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
        'readAxes',
      );
      if (raw == null) {
        return GamepadAxes.zero;
      }
      final age = _asInt(raw['ageMs']);
      return GamepadAxes(
        rightX: _asDouble(raw['rightX']),
        rightY: _asDouble(raw['rightY']),
        leftX: _asDouble(raw['leftX']),
        leftY: _asDouble(raw['leftY']),
        hatX: _asDouble(raw['hatX']),
        hatY: _asDouble(raw['hatY']),
        // ageMs 为 null / 极大值 = 从来没接过摇杆事件
        stale: age == null || age > staleAfterMs,
      );
    } on PlatformException {
      return GamepadAxes.zero;
    } on MissingPluginException {
      return GamepadAxes.zero;
    }
  }

  /// 清零缓存(退出 VR 操作模式时调用, 避免下次进来先"飘"一下)
  static Future<void> reset() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('reset');
    } on PlatformException {
      // 忽略: 清不掉也只是下一次采样覆盖它
    } on MissingPluginException {
      // 忽略
    }
  }

  static double _asDouble(Object? value) => switch (value) {
    double v => v.isNaN || v.isInfinite ? 0 : v,
    int v => v.toDouble(),
    num v => v.toDouble(),
    _ => 0,
  };

  static int? _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    _ => null,
  };
}

/// 轮询器: VR 操作模式挂一个, 把右摇杆读数按固定节奏喂给回调。
///
/// 单独抽出来是为了让 `VrControlLayer` 的 build/dispose 保持干净, 也方便
/// 在测试里替换节奏。
class GamepadPoller {
  GamepadPoller({
    this.interval = const Duration(milliseconds: 20),
    required this.onAxes,
  });

  /// 采样间隔。20ms(≈50Hz)足够跟手, 又不会把主线程塞满
  final Duration interval;

  /// 每次拿到**新鲜**读数时回调(rightX, rightY, 距上次采样的秒数)
  final void Function(double rightX, double rightY, double dtSeconds) onAxes;

  Timer? _timer;
  bool _busy = false;
  int _lastMs = 0;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null || !GamepadBridge.isSupported) {
      return;
    }
    _lastMs = DateTime.now().millisecondsSinceEpoch;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _busy = false;
    unawaited(GamepadBridge.reset());
  }

  Future<void> _tick() async {
    // 上一帧的通道调用还没回来就跳过: 宁可掉一帧, 也不要让请求排队
    // (排队会造成"松手之后视角还在飘")
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      final axes = await GamepadBridge.read();
      final now = DateTime.now().millisecondsSinceEpoch;
      final dt = (now - _lastMs) / 1000.0;
      _lastMs = now;
      if (_timer == null || axes.stale) {
        return;
      }
      onAxes(axes.rightX, axes.rightY, dt);
    } finally {
      _busy = false;
    }
  }
}

/// 摇杆 -> 视角的换算(纯函数, 便于单测)。
///
/// 摇杆不像手指拖拽自带位移量, 只能"角速度 × 时间"积分; 方向约定与
/// [PlPlayerController.onVrLook] 保持一致的"看世界"语义:
///   * 摇杆推右(axisX = +1) -> 视线向右 -> yaw **增大**
///   * 摇杆推上(axisY = −1) -> 视线向上 -> pitch **减小**
abstract final class GamepadMath {
  /// 死区: 摇杆静置时的抖动(±0.1 很常见)不该让画面缓慢漂移
  static const double deadZone = 0.15;

  /// 满偏时的角速度(度/秒)。360° 片源约 3.3 秒转一圈, 跟手又不至于晕
  static const double degPerSec = 110.0;

  /// 单次采样的最大时间片: 掉帧/切后台回来时不要让视角"瞬移"
  static const double maxDeltaSeconds = 0.25;

  /// 死区 + 线性重映射: 刚过死区时增量从 0 平滑起步, 不会一跳一大步
  static double axis(double value) {
    if (value.isNaN || value.isInfinite) {
      return 0;
    }
    final magnitude = value.abs();
    if (magnitude <= deadZone) {
      return 0;
    }
    final scaled = (magnitude - deadZone) / (1.0 - deadZone);
    return value < 0 ? -scaled : scaled;
  }

  /// 一次采样转成的角度增量(度)。静止(两轴都在死区内)返回 (0, 0)。
  static ({double yaw, double pitch}) look(
    double axisX,
    double axisY,
    double dtSeconds,
  ) {
    final x = axis(axisX);
    final y = axis(axisY);
    if ((x == 0 && y == 0) || dtSeconds <= 0) {
      return (yaw: 0, pitch: 0);
    }
    final dt = dtSeconds > maxDeltaSeconds ? maxDeltaSeconds : dtSeconds;
    final step = degPerSec * dt;
    return (yaw: x * step, pitch: y * step);
  }
}
