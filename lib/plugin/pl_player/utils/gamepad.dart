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
    } catch (_) {
      // MissingPluginException 等: 通道没注册(极老的宿主)也不该影响播放
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
    } catch (_) {
      // 忽略: 清不掉也只是下一次采样覆盖它
    }
  }

  // num 的两种子类(double/int)都已覆盖, 再写一条 num 分支是不可达代码
  static double _asDouble(Object? value) => switch (value) {
    double v => v.isNaN || v.isInfinite ? 0 : v,
    int v => v.toDouble(),
    _ => 0,
  };

  static int? _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    _ => null,
  };
}

/// 摇杆采样器: VR 操作模式挂一个, 只负责"把最新读数取回来"。
///
/// 第二十轮 需求6 的关键分工: **采样与积分解耦**。
/// 旧实现是"取到一次读数就推进一次视角", 于是角度只在采样到达的那一刻动
/// (50Hz, 还要再过一层 30ms 节流 ≈ 33Hz), 而陀螺仪是 native 逐帧跑的 ——
/// 真机上手柄环视就是一格一格的。现在采样只管刷新缓存, 推进由
/// `VrControlLayer` 的帧 Ticker 每帧用最新采样 × 真实帧间隔来积分,
/// 更新率与屏幕刷新率一致。
class GamepadPoller {
  GamepadPoller({
    this.interval = const Duration(milliseconds: 10),
    required this.onSample,
  });

  /// 采样间隔。10ms(≈100Hz)主要是为了压低"手柄动了但 Dart 还不知道"的延迟;
  /// 平滑度由帧积分保证, 不靠这个频率。
  final Duration interval;

  /// 拿到**新鲜**读数时回调(rightX, rightY); 陈旧/静止不回调
  final void Function(double rightX, double rightY) onSample;

  Timer? _timer;
  bool _busy = false;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null || !GamepadBridge.isSupported) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _busy = false;
    unawaited(GamepadBridge.reset());
  }

  Future<void> _tick() async {
    // 上一次通道调用还没回来就跳过: 宁可掉一次采样, 也不要让请求排队
    // (排队会造成"松手之后视角还在飘")
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      final axes = await GamepadBridge.read();
      if (_timer == null || axes.stale) {
        return;
      }
      onSample(axes.rightX, axes.rightY);
    } finally {
      _busy = false;
    }
  }
}
