import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:media_kit/media_kit.dart' show Player;

/// PiP Activity 推过来的事件类型
enum SystemPipEventType {
  /// SurfaceView 就绪(带新的 wid); 尺寸变化导致 surface 重建时会再来一次
  surfaceReady,

  /// surface 尺寸变化(wid 不变)
  surfaceChanged,

  /// surface 即将失效: 必须**立刻**把 mpv 摘下来, 否则渲染进已销毁的 surface
  surfaceLost,

  /// 进/出 PiP 窗口态
  pipModeChanged,

  /// 用户点了 PiP 窗口的"展开": 该把画面交还 Flutter 播放页
  expanded,

  /// PiP 窗口被关掉(划掉/点 X): 播放该结束了
  closed,

  /// 进 PiP 失败(系统不允许/设备不支持), 调用方应走兜底
  failed,

  unknown,
}

class SystemPipEvent {
  const SystemPipEvent(this.type, {this.wid = 0, this.reason});

  final SystemPipEventType type;

  /// native 侧 `MediaKitAndroidHelper.newGlobalObjectRef(surface)` 的返回值:
  /// 指向 android.view.Surface 的 JNI 全局引用指针, 也就是 mpv `--wid` 的值
  final int wid;
  final String? reason;

  bool get inPip => wid == 1;

  static SystemPipEvent fromCall(MethodCall call) {
    final args = call.arguments;
    int widOf() {
      final value = args is Map ? args['wid'] : null;
      return value is int ? value : (value is num ? value.toInt() : 0);
    }

    String? reasonOf() {
      final value = args is Map ? args['reason'] : null;
      return value is String ? value : null;
    }

    return switch (call.method) {
      'onSurfaceReady' => SystemPipEvent(
        SystemPipEventType.surfaceReady,
        wid: widOf(),
      ),
      'onSurfaceChanged' => SystemPipEvent(
        SystemPipEventType.surfaceChanged,
        wid: widOf(),
      ),
      'onSurfaceLost' => SystemPipEvent(
        SystemPipEventType.surfaceLost,
        wid: widOf(),
      ),
      'onPipModeChanged' => SystemPipEvent(SystemPipEventType.pipModeChanged),
      'onExpanded' => SystemPipEvent(SystemPipEventType.expanded),
      'onClosed' => SystemPipEvent(SystemPipEventType.closed),
      'onFailed' => SystemPipEvent(
        SystemPipEventType.failed,
        reason: reasonOf(),
      ),
      _ => SystemPipEvent(SystemPipEventType.unknown),
    };
  }
}

/// 与 `PipActivity.kt` 对接的通道。
///
/// 系统 PiP 收起的是"调用它的那个 Activity"。主 Activity 是 FlutterActivity,
/// 它一进 PiP 整个应用都被塞进小窗(应用内没法继续浏览)—— 所以画面交给一个
/// **独立的 PiP Activity**(结构与 moonlight-android 的 Game Activity 一致),
/// 主 Activity 留在原任务里照常可点。见 PipActivity.kt 的头注释。
abstract final class SystemPipBridge {
  static const MethodChannel _channel = MethodChannel('piliplus/pip');

  static bool _handlerInstalled = false;

  /// 事件回调(由 FloatingPlayerService 安装)
  static void Function(SystemPipEvent event)? onEvent;

  static bool get isSupported => Platform.isAndroid;

  static void installHandler() {
    if (_handlerInstalled) {
      return;
    }
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      onEvent?.call(SystemPipEvent.fromCall(call));
    });
  }

  /// 起 PiP 窗口(独立任务)。返回系统是否受理。
  static Future<bool> start({
    required int width,
    required int height,
    String? title,
  }) async {
    if (!isSupported) {
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('start', <String, Object?>{
        'width': width,
        'height': height,
        'title': title,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 关掉 PiP 窗口(finish PipActivity)
  static Future<void> stop() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // 窗口可能已经自己关了
    }
  }
}

/// mpv 渲染目标(`--wid`)在 **Flutter 纹理** 与 **PiP SurfaceView** 之间的交接。
///
/// 顺序照抄 media_kit 自己的 `AndroidVideoController`:
/// `vo=null` → `wid=<新值>` → `vo=<原值>`。
/// 它的注释写得很直白: "It is necessary to set vo=null here to avoid SIGSEGV,
/// --wid must be assigned before vo=gpu is set."
abstract final class MpvWidHandoff {
  /// 读一个 mpv 属性; 读不到(旧引擎/属性不存在)返回 null, 绝不抛
  static String? read(Player? player, String property) {
    if (player == null) {
      return null;
    }
    try {
      final value = player.getProperty(property);
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// 把画面接到 [wid] 指向的 surface 上
  static void attach(Player? player, int wid, {String vo = 'gpu'}) {
    if (player == null || wid <= 0) {
      return;
    }
    _safe(player, () {
      player
        ..setOption('vo', 'null')
        ..setOption('wid', '$wid')
        ..setOption('vo', vo);
    });
  }

  /// 摘下来(不再往任何 surface 渲染)。surface 即将销毁时必须先做这一步。
  static void detach(Player? player) {
    if (player == null) {
      return;
    }
    _safe(player, () {
      player
        ..setOption('vo', 'null')
        ..setOption('wid', '0');
    });
  }

  static void _safe(Player player, void Function() action) {
    try {
      action();
    } catch (_) {
      // 播放器已销毁等竞态: 交接失败最多是黑屏, 不能把异常抛回 native 回调
    }
  }
}
