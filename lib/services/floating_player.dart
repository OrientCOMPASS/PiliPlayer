import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show SimpleVideo;

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

  bool get isActive => active.value;

  /// 从播放页收起成小窗。[context] 用于把播放页弹出栈。
  void enter({
    required BuildContext context,
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

    _controller = controller;
    _title = title;
    _restoreArgs = Map<dynamic, dynamic>.of(restoreArgs);
    _restoreRoute = restoreRoute;
    // 播放页 dispose 时据此放过播放器(否则出栈即销毁)
    controller.floatingKeepAlive = true;

    // 全屏(横屏锁定)状态下先退回窗口态: 小窗播放时不该把整个应用锁在横屏
    if (controller.isFullScreen.value) {
      controller.triggerFullScreen(status: false);
    }
    if (controller.controlsLock.value) {
      controller.onLockControl(false);
    }

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
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator != null) {
      navigator.pop();
    } else {
      Get.back<dynamic>();
    }
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

  /// 关闭小窗并销毁播放器
  void close() {
    final controller = _controller;
    _teardownEntry(saveProgress: true);
    _restoreArgs = null;
    if (controller != null) {
      controller.floatingKeepAlive = false;
      // 播放页早就出栈了, 销毁得由这里补上
      controller.dispose();
    }
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
                      if (videoController != null)
                        SimpleVideo(
                          controller: videoController,
                          fill: Colors.black,
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
