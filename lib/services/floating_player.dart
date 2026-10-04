import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:io' show Platform;

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/saf/saf_bridge.dart' show SafFdRegistry;
import 'package:PiliPlus/services/system_pip.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' show PlayerLog;
import 'package:media_kit_video/media_kit_video.dart' show SimpleVideo;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

/// "播放页已经出栈、播放器还在播"的两种呈现方式。
enum DetachedPlaybackMode {
  /// 应用内浮窗(插在 root Overlay 上): 不出应用, 不依赖系统 PiP
  inAppWindow,

  /// **系统画中画**: 画面交给独立的 PiP Activity(见 `PipActivity.kt`),
  /// 系统管理的小窗(可拖到屏幕任意位置、可出应用、有系统媒体按钮)
  systemPip,
}

/// 应用内画中画(小窗播放)—— 第十九轮 需求3。
///
/// **为什么不用系统 PiP**: 系统画中画收起的是**整个 Activity**, 本应用是
/// 单 Activity 的 Flutter 工程, 一进系统 PiP, 应用里其它页面就都不可见了
/// (moonlight-android 之所以能"PiP 时继续浏览", 是因为它的串流跑在独立的
/// Game Activity 里, 主界面是另一个 Activity)。要在本应用里做到"只收起
/// 播放页", 只能把播放器收进应用自己的浮窗:
///
///   * 浮窗插在 **root Overlay** 上, 位于所有路由之上 —— 之后无论用户怎么
///     浏览(返回、切 Tab、进新页面), 小窗都还在播;
///   * 播放页出栈时通过 [PlPlayerController.floatingKeepAlive] 跳过播放器
///     销毁, mpv 实例与 [VideoController] 都活着, 浮窗里用同一个
///     `Texture`(media_kit 的 `SimpleVideo`)继续渲染;
///   * 点小窗 = 回到播放页: 用**原样保存的路由参数**重新进页, 并带上当前
///     进度, 播放器是单例复用的, 装载的是同一条流, 原位续播;
///   * 点关闭 = 正常销毁播放器。
///
/// 系统 PiP 仍然保留给"按 Home 离开应用"的场景(设置里的自动画中画)。
class FloatingPlayerService {
  FloatingPlayerService._();

  static final FloatingPlayerService instance = FloatingPlayerService._();

  /// 小窗是否在显示
  final RxBool active = false.obs;

  PlPlayerController? _controller;
  OverlayEntry? _entry;

  /// 进小窗前播放页的路由参数(回播放页时原样用)
  Map<dynamic, dynamic>? _restoreArgs;

  /// 进小窗前播放页所在的路由名(本地媒体/普通视频都是 /videoV)
  String _restoreRoute = '/videoV';

  String _title = '';

  /// 小窗期间要续存进度的本地/局域网条目(在线视频走 B 站心跳, 这里不管)
  LocalMediaItem? _progressItem;
  Timer? _progressTimer;

  /// 当前呈现方式(应用内浮窗 / 系统画中画)
  DetachedPlaybackMode _mode = DetachedPlaybackMode.inAppWindow;

  DetachedPlaybackMode get mode => _mode;

  // ---- 系统画中画专用状态 ----

  /// PiP 窗口 TextureView 的 wid(mpv `--wid` 的值)与其缓冲尺寸
  int _pipWid = 0;
  String _pipSurfaceSize = '0x0';

  /// 交接前 Flutter 纹理那边的 wid / vo / surface 尺寸, 退出 PiP 时要还原回去
  int _flutterWid = 0;
  String _flutterVo = 'gpu';
  String _flutterSurfaceSize = '0x0';

  /// 交接后补刀的定时器(见 [_scheduleReassert])
  final List<Timer> _reassertTimers = [];

  /// PiP 期间转发 mpv 的 warn/error 日志到应用日志(排障用:
  /// 交接失败时 mpv 会说清楚是 EGL surface 建不起来还是别的原因)
  StreamSubscription<PlayerLog>? _mpvLogSub;

  /// 等 PiP Activity 的 surface 就绪(拿到 wid + 窗口尺寸)
  Completer<SystemPipEvent>? _surfaceWaiter;

  /// Dart 主动收尾(展开/关闭)期间, 忽略 native 再推来的事件
  bool _ignoreNativeEvents = false;

  bool get isActive => active.value;

  bool get isSystemPip => _mode == DetachedPlaybackMode.systemPip;

  /// 从播放页收起成小窗。[navigator] 用来把播放页弹出栈
  /// (调用方在**同步**阶段就把它取好, 免得 await 之后再用 BuildContext)。
  void enter({
    required NavigatorState? navigator,
    required PlPlayerController controller,
    required String title,
    required Map<dynamic, dynamic> restoreArgs,
    String restoreRoute = '/videoV',
  }) {
    if (active.value) {
      return;
    }
    final videoController = controller.videoController;
    if (videoController == null) {
      SmartDialog.showToast('播放器还没就绪，稍后再试');
      return;
    }
    if (!Platform.isAndroid) {
      SmartDialog.showToast('当前平台不支持应用内小窗');
      return;
    }

    _mode = DetachedPlaybackMode.inAppWindow;
    _controller = controller;
    _title = title;
    _restoreArgs = Map<dynamic, dynamic>.of(restoreArgs);
    _restoreRoute = restoreRoute;
    // 播放页 dispose 时据此放过播放器(否则出栈即销毁)
    controller.floatingKeepAlive = true;

    _leaveFullScreen(controller);
    _resetBrightness();
    _suppressHostAutoPip();

    if (!_insertEntry()) {
      controller.floatingKeepAlive = false;
      _controller = null;
      _restoreArgs = null;
      return;
    }
    active.value = true;
    _startProgressSaver(controller, _restoreArgs);
    // 播放页马上就要出栈, 它占的那份引用计数交给小窗(见方法注释)
    controller.releasePageSlotForFloating();
    // 播放页出栈 —— 下面的页面立刻可见可点, 这就是"只收起播放页"
    _popPage(navigator);
  }

  /// 系统画中画(第二十轮 需求2): 画面交给独立的 `PipActivity`,
  /// 主 Activity 留在原任务里 —— 与 moonlight-android 同一套结构。
  ///
  /// 播放器**不重建**: 只是把 mpv 的渲染目标(`--wid`)从 media_kit 在 Flutter
  /// 纹理注册表里创建的 Surface, 换成 PiP 窗口 SurfaceView 的 Surface
  /// (顺序 `vo=null -> wid -> vo=gpu`, 照抄 media_kit 自己的做法)。
  /// 所以不重新拉流、不丢进度、不重新缓冲。
  ///
  /// 返回 false 表示这条路走不通(设备/系统不允许、surface 没起来、读不到
  /// 当前 wid), 调用方应退回"整应用系统 PiP"或应用内浮窗。
  Future<bool> enterSystemPip({
    required NavigatorState? navigator,
    required PlPlayerController controller,
    required String title,
    required Map<dynamic, dynamic> restoreArgs,
    String restoreRoute = '/videoV',
  }) async {
    if (active.value || !SystemPipBridge.isSupported) {
      return false;
    }
    final player = controller.videoPlayerController;
    if (player == null || controller.videoController == null) {
      logger.w('[pip] 进入失败: 播放器/视频控制器还没就绪');
      return false;
    }
    // 交接前必须记住 Flutter 纹理那边的 wid, 否则退出 PiP 时回不去
    final flutterWid = int.tryParse(MpvWidHandoff.read(player, 'wid') ?? '') ?? 0;
    final flutterVo = MpvWidHandoff.read(player, 'vo') ?? 'gpu';
    // media_kit 会把 android-surface-size 设成片源尺寸(它的 SurfaceTexture
    // 需要这个); 交给 PiP 的 SurfaceView 时要还原成 0x0(= 跟随窗口),
    // 否则等于让系统把 4K 缓冲塞进一个小窗(闪烁/黑屏嫌疑之一)
    final flutterSurfaceSize =
        MpvWidHandoff.read(player, 'android-surface-size') ?? '0x0';
    logger.w(
      '[pip] 交接前: flutterWid=$flutterWid vo=$flutterVo '
      'surfaceSize=$flutterSurfaceSize',
    );
    if (flutterWid <= 0) {
      logger.w('[pip] 进入失败: 读不到当前 wid(mpv 还没挂上 Flutter 纹理?)');
      return false;
    }
    // **在启动 PiP Activity 之前**就置上保活标记: 启动会让主 Activity 短暂
    // onPause -> Flutter 收到 paused -> 播放页那句"退后台就暂停"会把视频停掉,
    // 而播放页随后就出栈了, 再没人来恢复它(真机实测: 一进画中画就暂停)。
    controller.floatingKeepAlive = true;
    final wasPlaying = controller.playerStatus.isPlaying;

    // 启动 PipActivity 之前先把两件事做完(顺序很关键):
    //  ① 关掉主 Activity 的"自动进系统 PiP" —— 否则主 Activity 退到后台时
    //     自己也会缩成一个小窗, 于是屏幕上出现两个 PiP 互相抢焦点, 看起来
    //     就是"画面与黑屏来回闪";
    //  ② 退出全屏/解锁 —— 别把整个应用锁在横屏上。
    _suppressHostAutoPip();
    _leaveFullScreen(controller);

    // 注意: 静态成员不能写成级联(`SystemPipBridge..installHandler()` 会被
    // 解析成对 Type 对象调实例方法)
    SystemPipBridge.installHandler();
    SystemPipBridge.onEvent = _onPipEvent;
    _ignoreNativeEvents = false;
    final waiter = Completer<SystemPipEvent>();
    _surfaceWaiter = waiter;

    final state = player.state;
    var ratioW = state.width > 0 ? state.width : 16;
    var ratioH = state.height > 0 ? state.height : 9;
    // 系统对 PiP 宽高比有硬限制(约 1:2.39 ~ 2.39:1), 超出会抛异常;
    // 兜底规则与 PageUtils.enterPip 一致
    final ratio = ratioW / ratioH;
    if (ratio < 1 / 2.39 || ratio > 2.39) {
      if (ratioH > ratioW) {
        ratioW = 9;
        ratioH = 16;
      } else {
        ratioW = 16;
        ratioH = 9;
      }
    }
    if (!await SystemPipBridge.start(
      width: ratioW,
      height: ratioH,
      title: title,
    )) {
      logger.w('[pip] 进入失败: 启动 PipActivity 被拒');
      _surfaceWaiter = null;
      controller.floatingKeepAlive = false;
      return false;
    }
    final ready = await waiter.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () => const SystemPipEvent(SystemPipEventType.failed),
    );
    _surfaceWaiter = null;
    final pipWid = ready.wid;
    if (pipWid <= 0) {
      logger.w('[pip] 进入失败: 4 秒内没等到 PiP 的 surface(或系统拒绝进入)');
      controller.floatingKeepAlive = false;
      unawaited(SystemPipBridge.stop());
      return false;
    }
    logger.w(
      '[pip] 拿到 PiP surface: wid=$pipWid ${ready.width}x${ready.height} '
      'wasPlaying=$wasPlaying',
    );

    _mode = DetachedPlaybackMode.systemPip;
    _controller = controller;
    _title = title;
    _restoreArgs = Map<dynamic, dynamic>.of(restoreArgs);
    _restoreRoute = restoreRoute;
    _flutterWid = flutterWid;
    _flutterVo = flutterVo;
    _flutterSurfaceSize = flutterSurfaceSize;
    _pipWid = pipWid;
    // native 侧已把 SurfaceTexture 的默认缓冲尺寸设成窗口大小, mpv 的
    // android-surface-size 要跟它一致(不能沿用片源尺寸: 那等于让系统把 4K
    // 缓冲塞进一个小窗)
    _pipSurfaceSize = ready.surfaceSize ?? '0x0';

    // 画面搬进 PiP 窗口
    MpvWidHandoff.attach(
      player,
      pipWid,
      vo: flutterVo,
      surfaceSize: _pipSurfaceSize,
    );
    logger.w(
      '[pip] 已把 mpv 渲染目标交给 PiP 窗口(surfaceSize=$_pipSurfaceSize), '
      'current-vo=${MpvWidHandoff.read(player, 'current-vo')}',
    );
    _scheduleReassert();
    _watchMpvLogs(player);
    // 启动 PiP Activity 期间主 Activity 会短暂 onPause, 播放可能被"退后台
    // 就暂停"停掉(那时保活标记还没生效或页面还没出栈), 这里按进 PiP 前的
    // 状态补一次
    if (wasPlaying && !controller.playerStatus.isPlaying) {
      unawaited(controller.play());
    }

    _resetBrightness();

    active.value = true;
    _startProgressSaver(controller, _restoreArgs);
    controller.releasePageSlotForFloating();
    _popPage(navigator);
    _scheduleHandoffWatchdog(controller, wasPlaying);
    return true;
  }

  /// 交接自检(第二十二轮)。
  ///
  /// "进 PiP 后被暂停 / 画面与黑屏来回闪 / 关窗闪退"这类问题只能在真机上
  /// 复现, 所以这里自己验一遍: 2.6 秒后(三次 wid 补刀都跑完了)检查
  ///   ① mpv 的渲染目标是否还是 PiP 窗口(被别人抢回去 = 窗口是黑的);
  ///   ② 播放状态是否还是进 PiP 前的样子(被"退后台就暂停"停掉 = 画面冻住)。
  /// 任一不满足就**自动退回应用内浮窗**(纯 Flutter, 不做 surface 交接),
  /// 至少给用户一个能用的小窗, 并把原因写进 `[pip]` 日志。
  void _scheduleHandoffWatchdog(
    PlPlayerController controller,
    bool wasPlaying,
  ) {
    Timer(const Duration(milliseconds: 2600), () {
      if (!isSystemPip || _controller != controller) {
        return; // 已经展开/关闭/换成别的模式了
      }
      final player = controller.videoPlayerController;
      final wid = int.tryParse(MpvWidHandoff.read(player, 'wid') ?? '') ?? -1;
      final vo = MpvWidHandoff.read(player, 'current-vo');
      final playing = controller.playerStatus.isPlaying;
      logger.w(
        '[pip] 自检: wid=$wid(期望 $_pipWid) current-vo=$vo '
        'playing=$playing(进 PiP 前 $wasPlaying)',
      );
      // ① 渲染目标不在 PiP 窗口手里, 或 vo 根本没起来 -> 窗口必然是黑的,
      //    补刀三次都没救回来, 直接退回应用内浮窗
      if (wid != _pipWid || vo == null || vo.isEmpty) {
        _fallbackToInAppWindow(controller, wasPlaying: wasPlaying);
        return;
      }
      // ② 只是被"退后台就暂停"停掉了 -> 先补一次 play, 一秒后复查
      if (wasPlaying && !playing) {
        logger.w('[pip] 自检: 视频被暂停了, 补一次 play()');
        unawaited(controller.play());
        Timer(const Duration(seconds: 1), () {
          if (!isSystemPip || _controller != controller) {
            return;
          }
          if (!controller.playerStatus.isPlaying) {
            logger.w('[pip] 自检: 补 play 之后仍是暂停 -> 退回应用内浮窗');
            _fallbackToInAppWindow(controller, wasPlaying: true);
          }
        });
      }
    });
  }

  /// 系统 PiP 交接不成功时的兜底: 画面还给 Flutter 纹理, 关掉 PiP 窗口,
  /// 改用应用内浮窗(它只是把播放页出栈 + 在 root Overlay 上挂一个
  /// `SimpleVideo`, 不碰 mpv 的渲染目标, 因此不依赖 ROM 的 surface 行为)。
  void _fallbackToInAppWindow(
    PlPlayerController controller, {
    required bool wasPlaying,
  }) {
    _ignoreNativeEvents = true;
    _restoreFlutterSurface(controller);
    unawaited(SystemPipBridge.stop());
    _mode = DetachedPlaybackMode.inAppWindow;
    if (!_insertEntry()) {
      close();
      return;
    }
    if (wasPlaying && !controller.playerStatus.isPlaying) {
      unawaited(controller.play());
    }
    SmartDialog.showToast(
      '系统画中画在这台设备上没交接成功，已切到应用内浮窗\n'
      '可在「设置 → 播放设置 → 画中画样式」里更换实现',
      displayTime: const Duration(seconds: 4),
    );
  }

  /// 关掉主 Activity 的"自动进系统 PiP"。
  ///
  /// 不设的话会有两个 PiP: 启动 PipActivity 时 MainActivity 退到后台,
  /// 若它此前按「自动画中画」设置挂了 `setAutoEnterEnabled(true)`(或
  /// onUserLeaveHint 回调), 它自己也会缩进一个系统小窗。
  void _suppressHostAutoPip() {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      PiliAndroidHelper.disableAutoEnterPip();
    } catch (_) {
      // JNI 没就绪之类: 最多是多一个小窗, 不影响主流程
    }
  }

  /// 播放页出栈(两种模式共用)
  void _popPage(NavigatorState? navigator) {
    if (navigator != null) {
      navigator.pop();
    } else {
      Get.back<dynamic>();
    }
  }

  /// 全屏(横屏锁定)状态下先退回窗口态: 播放页都要出栈了, 不该把整个应用
  /// 锁在横屏上
  void _leaveFullScreen(PlPlayerController controller) {
    if (controller.isFullScreen.value) {
      controller.triggerFullScreen(status: false);
    }
    if (controller.controlsLock.value) {
      controller.onLockControl(false);
    }
  }

  /// 播放页里手势调过的屏幕亮度是"应用级"的, 正常退出由播放器 dispose 还原;
  /// 这两条路都跳过了 dispose, 这里手动还一次, 否则接下来浏览应用会一直停在
  /// 播放页的亮度上。平台没初始化/不支持就算了, 不能因为这个进不了小窗。
  void _resetBrightness() {
    try {
      unawaited(
        ScreenBrightnessPlatform.instance
            .resetApplicationScreenBrightness()
            .catchError((Object _) {}),
      );
    } catch (_) {
      // 见上
    }
  }

  // ==================== 系统画中画的事件与 surface 交接 ====================

  void _onPipEvent(SystemPipEvent event) {
    logger.w(
      '[pip] 事件 ${event.type.name}'
      '${event.wid == 0 ? '' : ' wid=${event.wid}'}'
      '${event.reason == null ? '' : ' reason=${event.reason}'}',
    );
    try {
      _handlePipEvent(event);
    } catch (err) {
      // 事件处理里出任何异常都不能让 native 侧等不到回应/让 mpv 挂在死窗口上
      logger.e('[pip] 事件处理异常', error: err);
    }
  }

  void _handlePipEvent(SystemPipEvent event) {
    // surface 要没了: **无条件**先把 mpv 摘下来(native 正在主线程上等着我们,
    // 摘晚了就是往已销毁的窗口渲染 -> 闪退)。这一步不受 _ignoreNativeEvents
    // 影响: 摘除永远是安全的。
    if (event.type == SystemPipEventType.surfaceLost) {
      MpvWidHandoff.detach(_controller?.videoPlayerController);
      _cancelReassert();
      return;
    }
    if (_ignoreNativeEvents) {
      return;
    }
    final player = _controller?.videoPlayerController;
    switch (event.type) {
      case SystemPipEventType.surfaceReady:
        final waiter = _surfaceWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(event);
          return;
        }
        // PiP 窗口尺寸变化会让系统重建 surface: 用新 wid 重新接上
        if (isSystemPip && event.wid > 0 && event.wid != _pipWid) {
          logger.w('[pip] surface 重建: wid $_pipWid -> ${event.wid}');
          _pipWid = event.wid;
          _pipSurfaceSize = event.surfaceSize ?? _pipSurfaceSize;
          MpvWidHandoff.attach(
            player,
            event.wid,
            vo: _flutterVo,
            surfaceSize: _pipSurfaceSize,
          );
          _scheduleReassert();
        }
      case SystemPipEventType.expanded:
        // 用户点了 PiP 窗口的"展开": 交还播放页
        unawaited(restore());
      case SystemPipEventType.closed:
        // PiP 窗口被划掉/点 X: 播放到此为止
        close();
      case SystemPipEventType.failed:
        final waiter = _surfaceWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(event);
        }
      case SystemPipEventType.surfaceChanged:
      case SystemPipEventType.pipModeChanged:
      case SystemPipEventType.surfaceLost:
      case SystemPipEventType.unknown:
        break;
    }
  }

  /// PiP 期间把 mpv 自己的 warn/error 日志转进应用日志(「设置 → 日志」可导出)。
  ///
  /// 交接这条链在真机上出问题时必须能看到 mpv 怎么说(EGL surface 建不起来 /
  /// wid 无效 / vo 初始化失败…), 否则只能靠猜。
  void _watchMpvLogs(dynamic player) {
    _mpvLogSub?.cancel();
    try {
      _mpvLogSub = player.stream.log.listen((PlayerLog log) {
        final level = log.level.toLowerCase();
        if (level == 'warn' || level == 'error' || level == 'fatal') {
          logger.w('[pip][mpv][${log.prefix}] ${log.text}');
        }
      });
    } catch (_) {
      _mpvLogSub = null;
    }
  }

  void _stopWatchingMpvLogs() {
    _mpvLogSub?.cancel();
    _mpvLogSub = null;
  }

  /// 有限次"补刀": media_kit 的 AndroidVideoController 在 videoParams 变化时
  /// 会把 `wid` 抢回它自己的 Flutter 纹理(它不知道画面被借走了), 那样 PiP 窗口
  /// 就黑了。
  ///
  /// 上一轮的做法是**监听 videoParams 事件后重新下发**, 结果真机上画面与黑屏
  /// 来回闪烁 —— 我们自己那次 `vo=null -> vo=gpu` 又会引发新的事件, 两边互相
  /// 触发成了正反馈。改成: 只在交接后的几个固定时间点**检查一次**, 发现 wid
  /// 不在我们手里才重新接上(幂等, 不构成回路)。
  void _scheduleReassert() {
    _cancelReassert();
    for (final delay in const [
      Duration(milliseconds: 200),
      Duration(milliseconds: 800),
      Duration(seconds: 2),
    ]) {
      _reassertTimers.add(Timer(delay, _reassertPipSurface));
    }
  }

  void _cancelReassert() {
    for (final timer in _reassertTimers) {
      timer.cancel();
    }
    _reassertTimers.clear();
  }

  void _reassertPipSurface() {
    final player = _controller?.videoPlayerController;
    if (player == null || !isSystemPip || _pipWid <= 0) {
      return;
    }
    final current = int.tryParse(MpvWidHandoff.read(player, 'wid') ?? '') ?? 0;
    if (current == _pipWid) {
      return; // 还在我们手里, 不动它(每次重接都会黑一下, 能不动就不动)
    }
    logger.w('[pip] wid 被抢走(当前 $current, 应为 $_pipWid), 重新接回');
    MpvWidHandoff.attach(
      player,
      _pipWid,
      vo: _flutterVo,
      surfaceSize: _pipSurfaceSize,
    );
  }

  /// 把画面还给 Flutter 纹理(退出系统画中画)
  void _restoreFlutterSurface(PlPlayerController controller) {
    _cancelReassert();
    _stopWatchingMpvLogs();
    if (_flutterWid > 0) {
      MpvWidHandoff.attach(
        controller.videoPlayerController,
        _flutterWid,
        vo: _flutterVo,
        // 还原成 media_kit 当初设的片源尺寸(它的 SurfaceTexture 需要这个)
        surfaceSize: _flutterSurfaceSize,
      );
    }
    _pipWid = 0;
    _flutterWid = 0;
  }

  /// 回到播放页(原位续播)
  Future<void> restore() async {
    final controller = _controller;
    final args = _restoreArgs;
    if (controller == null || args == null) {
      close();
      return;
    }
    final progressMs = controller.positionInMilliseconds;
    final cid = args['cid'];
    final route = _restoreRoute;
    if (isSystemPip) {
      logger.w('[pip] 展开: 画面交还 Flutter 纹理 wid=$_flutterWid');
      // 接下来 finish PiP 窗口时 native 还会推 onClosed/onSurfaceLost 过来,
      // 那是我们自己发起的收尾, 不能再当成"用户关掉了窗口"去销毁播放器
      _ignoreNativeEvents = true;
      _restoreFlutterSurface(controller);
      unawaited(SystemPipBridge.stop());
    }
    _teardownEntry(saveProgress: true);
    // 交还给播放页: 页面会正常走 setDataSource(单例播放器复用),
    // 因此这里必须清掉保活标记, 否则用户再退出时播放器不会被销毁
    controller.floatingKeepAlive = false;
    _controller = null;
    _restoreArgs = null;
    final pushed = PageUtils.toDupNamed<dynamic>(
      route,
      arguments: <dynamic, dynamic>{
        ...args,
        // heroTag 必须换新的: 它是 GetX 的 tag, 旧页面虽然出栈了,
        // 但同名 tag 复用会让控制器绑定关系错乱
        'heroTag': Utils.makeHeroTag(cid ?? 0),
        'progress': progressMs,
      },
    );
    if (pushed != null) {
      await pushed;
    }
  }

  /// 关闭小窗(应用内浮窗 / 系统画中画)并销毁播放器
  void close() {
    final controller = _controller;
    if (isSystemPip) {
      logger.w('[pip] 关闭: 先摘 surface 再销毁播放器');
      _ignoreNativeEvents = true;
      _stopWatchingMpvLogs();
      // 先从 PiP 的 surface 上摘下来再销毁, 免得 mpv 往已销毁的窗口渲染
      MpvWidHandoff.detach(controller?.videoPlayerController);
      _cancelReassert();
      _pipWid = 0;
      _flutterWid = 0;
      unawaited(SystemPipBridge.stop());
    }
    _teardownEntry(saveProgress: true);
    _restoreArgs = null;
    if (controller != null) {
      controller.floatingKeepAlive = false;
      // 播放页早就出栈了, 销毁得由这里补上
      controller.dispose();
    }
    // SAF 条目的 fd 在小窗期间是**故意留着**的(浏览页那边不能关, 见
    // LocalMediaBrowserPage._play); 播放到此为止, 这里统一收尾。
    unawaited(SafFdRegistry.releaseAll());
  }

  /// 打开新播放页之前先收掉旧的小窗(播放器是单例, 不能被两个页面抢)
  void closeIfActive() {
    if (active.value) {
      close();
    }
  }

  /// 把小窗插到 root Overlay 上; 拿不到 Overlay 时返回 false(调用方回滚状态)
  bool _insertEntry() {
    final overlay = _rootOverlay();
    final controller = _controller;
    if (overlay == null || controller == null) {
      SmartDialog.showToast('无法创建小窗');
      controller?.floatingKeepAlive = false;
      _controller = null;
      return false;
    }
    final entry = OverlayEntry(
      builder: (context) => _FloatingPlayerWindow(
        service: this,
        controller: controller,
        title: _title,
      ),
      opaque: false,
      maintainState: true,
    );
    _entry = entry;
    overlay.insert(entry);
    return true;
  }

  /// 摘掉浮窗(顺带把小窗里看到的位置存一次盘)
  void _teardownEntry({bool saveProgress = false}) {
    _stopProgressSaver(save: saveProgress);
    active.value = false;
    _mode = DetachedPlaybackMode.inAppWindow;
    _surfaceWaiter = null;
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      entry
        ..remove()
        ..dispose();
    }
  }

  // ==================== 小窗期间的续播进度 ====================

  /// 播放页出栈时, 它的"每 5 秒落盘一次续播进度"监听也跟着没了。小窗里
  /// 看的时间同样要记住(否则关掉小窗再进这个文件, 会跳回进小窗前的位置),
  /// 所以这里补一个同样节奏的定时器。只针对本地/局域网媒体 —— 在线视频的
  /// 历史心跳由播放器自己维持, 不该在这里重复上报。
  void _startProgressSaver(
    PlPlayerController controller,
    Map<dynamic, dynamic>? args,
  ) {
    // 注意: 三元表达式里不要写 `args?['k']`(解析器会把第二个 ? 当成
    // 嵌套三元), 先做非空判断再取。
    final item = args != null && args['sourceType'] == SourceType.localMedia
        ? args['localMedia']
        : null;
    if (item is! LocalMediaItem || item.uri.startsWith('fd://')) {
      return; // fd:// 每次会话都不同, 存了也没意义(与播放页一致)
    }
    _progressItem = item;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(controller),
    );
  }

  void _saveProgress(PlPlayerController controller) {
    final item = _progressItem;
    if (item == null) {
      return;
    }
    final ms = controller.positionInMilliseconds;
    if (ms <= 0) {
      return;
    }
    final total = controller.durationInMilliseconds;
    LocalMediaProgress.put(
      item.uri,
      Duration(milliseconds: ms),
      duration: total > 0 ? Duration(milliseconds: total) : null,
    );
  }

  void _stopProgressSaver({bool save = false}) {
    _progressTimer?.cancel();
    _progressTimer = null;
    if (save) {
      final controller = _controller;
      if (controller != null) {
        _saveProgress(controller);
      }
    }
    _progressItem = null;
  }

  /// root Overlay(所有路由都在它下面) —— 小窗必须插在这一层, 否则用户一进
  /// 新页面就把小窗盖住了。
  OverlayState? _rootOverlay() {
    final fromNavigator = Get.key.currentState?.overlay;
    if (fromNavigator != null) {
      return fromNavigator;
    }
    final context = Get.context;
    return context == null ? null : Overlay.maybeOf(context, rootOverlay: true);
  }

  String get title => _title;
}

/// 小窗本体: 可拖拽、可点按回播放页、带 播放/暂停 · 展开 · 关闭。
class _FloatingPlayerWindow extends StatefulWidget {
  const _FloatingPlayerWindow({
    required this.service,
    required this.controller,
    required this.title,
  });

  final FloatingPlayerService service;
  final PlPlayerController controller;
  final String title;

  @override
  State<_FloatingPlayerWindow> createState() => _FloatingPlayerWindowState();
}

class _FloatingPlayerWindowState extends State<_FloatingPlayerWindow> {
  /// 小窗宽度占屏宽的比例(手机上约 200dp, 平板上不会大得离谱)
  static const double _widthRatio = 0.46;
  static const double _minWidth = 170;
  static const double _maxWidth = 300;
  static const double _barHeight = 34;
  static const double _margin = 12;

  Offset? _offset;

  double _widthFor(double screenWidth) =>
      (screenWidth * _widthRatio).clamp(_minWidth, _maxWidth).toDouble();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final width = _widthFor(screen.width);
    final videoHeight = width * 9 / 16;
    final size = Size(width, videoHeight + _barHeight);
    // 首次布局: 贴右下角(避开系统手势区), 之后跟随拖拽
    final offset = _offset ??= Offset(
      screen.width - size.width - _margin,
      screen.height -
          size.height -
          _margin -
          media.padding.bottom -
          media.viewInsets.bottom,
    );
    final controller = widget.controller;
    final videoController = controller.videoController;

    return Positioned(
      left: _clampDx(offset.dx, screen.width, size.width),
      top: _clampDy(offset.dy, screen.height, size.height, media),
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _offset = Offset(
              _clampDx(offset.dx + details.delta.dx, screen.width, size.width),
              _clampDy(
                offset.dy + details.delta.dy,
                screen.height,
                size.height,
                media,
              ),
            );
          });
        },
        child: Material(
          color: Colors.black,
          elevation: 10,
          shadowColor: Colors.black54,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Column(
              children: [
                SizedBox(
                  height: videoHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // SimpleVideo 会按片源的**逻辑像素尺寸**给自己定尺寸,
                      // 直接塞进 StackFit.expand 会被强行拉满(竖屏片源就变形了),
                      // 所以套一层 FittedBox.contain 做等比letterbox。
                      if (videoController != null)
                        FittedBox(
                          fit: BoxFit.contain,
                          child: SimpleVideo(
                            controller: videoController,
                            fill: Colors.black,
                          ),
                        )
                      else
                        const ColoredBox(color: Colors.black),
                      // 缓冲/暂停时给个中心按钮, 免得以为小窗卡死了
                      Obx(
                        () => controller.playerStatus.isPlaying ||
                                controller.isBuffering.value
                            ? const SizedBox.shrink()
                            : const Center(
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.white70,
                                  size: 34,
                                ),
                              ),
                      ),
                      // 点画面 = 回播放页(展开按钮的等价操作, 更好点)
                      Positioned.fill(
                        child: Tooltip(
                          message: '回到播放页',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => unawaited(widget.service.restore()),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: _barHeight,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(color: Color(0xE6101010)),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Obx(
                            () => _barButton(
                              tooltip: controller.playerStatus.isPlaying
                                  ? '暂停'
                                  : '播放',
                              icon: controller.playerStatus.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              onTap: () {
                                if (controller.playerStatus.isPlaying) {
                                  unawaited(controller.pause());
                                } else {
                                  unawaited(controller.play());
                                }
                              },
                            ),
                          ),
                          _barButton(
                            tooltip: '回到播放页',
                            icon: Icons.open_in_full_rounded,
                            onTap: () => unawaited(widget.service.restore()),
                          ),
                          _barButton(
                            tooltip: '关闭小窗(停止播放)',
                            icon: Icons.close_rounded,
                            onTap: widget.service.close,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _barButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: _barHeight,
          child: Icon(icon, size: 17, color: Colors.white),
        ),
      ),
    );
  }

  /// 横向允许稍微探出屏幕一点(方便把小窗"甩"到边上), 但不允许整个跑没
  double _clampDx(double dx, double screenWidth, double width) =>
      dx.clamp(_margin - width * 0.3, screenWidth - width * 0.7).toDouble();

  double _clampDy(
    double dy,
    double screenHeight,
    double height,
    MediaQueryData media,
  ) {
    final top = media.padding.top + _margin;
    final bottom = screenHeight - height - media.padding.bottom - _margin;
    return dy.clamp(top, bottom < top ? top : bottom).toDouble();
  }
}
