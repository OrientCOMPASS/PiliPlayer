import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/plugin/pl_player/utils/gamepad.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show HapticFeedback, DeviceOrientation;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

typedef PlayCallback = Future<void>? Function();

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  final playerStatus = PlPlayerStatus(.playing);

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode => Platform.isAndroid && AndroidHelper.isPipMode;

  /// piliplayer 为安卓专供构建: 桌面悬浮窗 PiP 已随 window_manager 整体移除。
  /// 该标志恒为 false, 仅为让播放器 UI 中大量 `isFullScreen || isDesktopPip`
  /// 之类的判断无需逐处改写(在安卓上始终走非 PiP 分支)。
  bool get isDesktopPip => false;

  /// **应用内画中画(小窗)保活**标记 —— 见 `services/floating_player.dart`。
  ///
  /// 为 true 时播放页出栈**不销毁**播放器: 小窗还在用它渲染(root Overlay
  /// 上的浮窗持有同一个 [VideoController]/mpv 实例), 最终的 dispose 由浮窗
  /// 服务负责(关闭小窗)或交还给新的播放页(点小窗回播放页)。
  bool floatingKeepAlive = false;

  /// 小窗接管播放器: 把播放页占的那一份引用计数还回来。
  ///
  /// 不减的话"播放页 -> 小窗 -> 回播放页"会让 `_playerCount` 变成 2, 用户
  /// 第二次退出播放页时 dispose 只会把它减到 1 就返回, 播放器**不会被销毁**
  /// (表现为退出播放页后声音还在、局域网还在拉流)。
  void releasePageSlotForFloating() {
    if (_playerCount > 0) {
      _playerCount -= 1;
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      PiliAndroidHelper.disableAutoEnterPip();
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(PlayCallback? playCallBack) {
    _playCallBack = playCallBack;
  }

  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus.value;
  }

  static Future<void> pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) async {
    if (_instance?.playerStatus.isPlaying ?? false) {
      await _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
  }

  static Future<void> seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) async {
    await _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        AndroidHelper$ToDart.onUserLeaveHint = Runnable.implement(
          $Runnable(run: _onUserLeaveHint),
        );
      } else {
        _isAutoEnterPip = true;
      }
    }
  }

  void _onUserLeaveHint() {
    // 画面已经交给应用内小窗 / 独立 PiP Activity 时, 主 Activity 不要再
    // 自己缩进系统 PiP(否则会出现两个小窗)
    if (floatingKeepAlive) {
      return;
    }
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  /// 真正的"离线播放": B 站离线缓存 **或** 「本地」板块的本机/局域网媒体。
  ///
  /// [isFileSource] 只看 `dataSource` 的类型, 而本地媒体的局域网来源是
  /// [NetworkSource](SMB 走本机回环 HTTP 代理, WebDAV/HTTP/FTP 直连),
  /// 用它来判断会把一堆只对 B 站在线视频成立的行为错误地打开
  /// (进度预览图 videoshot、弹幕趋势图、画质/音质选择、AI 字幕翻译...)。
  /// 凡是"这件事依赖 B 站接口"的判断都应该用它, 而不是 [isFileSource]。
  bool get isOfflinePlayback => isFileSource || isLocalMedia;

  /// 本地/局域网媒体(「本地」板块)。
  ///
  /// 播放的不是 B 站内容, 因此一切会上报到 B 站或依赖 B 站接口的行为都必须关闭:
  /// 心跳/历史上报、进度预览图(videoshot)、弹幕、评论、点赞投币收藏、
  /// SponsorBlock 分段、B 站 UA/Referer 请求头等。
  bool isLocalMedia = false;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
    // 本地/局域网媒体: 关闭一切 B 站上报与请求
    bool isLocalMedia = false,
    // VR/全景片源布局, 为 null 时按设置自动识别
    VrProjection? vrProjection,

    /// 用于 VR 自动识别的"文件名"。
    ///
    /// 不能一律拿 `dataSource.videoSource` 去猜: SMB 播放走本机回环代理,
    /// 地址形如 `http://127.0.0.1:54321/s/<token>`, 里面根本没有原文件名,
    /// `360`/`sbs` 之类关键词全部丢失, 自动识别必然失效。
    String? mediaName,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      this.isLocalMedia = isLocalMedia;
      // 自动识别只对本地/局域网媒体生效: 在线视频地址里常带 360/1080p 之类
      // 的清晰度字样, 误判会直接把正常视频弄花, 在线内容请手动开启
      _initVrState(
        vrProjection,
        mediaName ?? dataSource.videoSource,
        autoDetect: isLocalMedia,
      );
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化视频倍速
      // _playbackSpeed.value = speed;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    // VR 重投影在 mpv 渲染链末端做(平面画面 -> 球面), 用户着色器作用在
    // 之前的 MAIN 阶段, 两者不再互斥, 超分辨率对全景片源照常生效。
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  // ==================== 内嵌字幕 / 音轨(mpv 自己的轨道) ====================

  /// mpv 报告的全部轨道。
  ///
  /// media_kit 会在每个列表最前面塞 `auto` / `no` 两个伪轨道
  /// (见 media_kit `real.dart` 里 `track-list` 的处理), 展示时要过滤掉,
  /// 见 [internalSubtitleTracks] / [internalAudioTracks]。
  final Rx<Tracks> mpvTracks = Rx<Tracks>(const Tracks());

  /// 当前**实际生效**的轨道。直接来自 mpv(`stream.track`), 不是这边记的,
  /// 所以面板上显示的"当前字幕流"一定与画面一致。
  final Rx<Track> currentTrack = Rx<Track>(const Track());

  static bool _isPseudoTrack(String id) => id == 'auto' || id == 'no';

  /// 真正可选的内嵌字幕轨道(MKV/MP4 里封进去的 ass/srt/pgs...)
  List<SubtitleTrack> get internalSubtitleTracks => [
    for (final t in mpvTracks.value.subtitle)
      if (!_isPseudoTrack(t.id)) t,
  ];

  /// 真正可选的内嵌音轨(国配/原声之类)
  List<AudioTrack> get internalAudioTracks => [
    for (final t in mpvTracks.value.audio)
      if (!_isPseudoTrack(t.id)) t,
  ];

  /// 轨道展示名: 标题 > 语言 > 序号, 末尾附编码(VLC 的轨道菜单就是这个信息量)
  static String trackLabel({
    required String id,
    String? title,
    String? language,
    String? codec,
  }) {
    final name = title != null && title.isNotEmpty
        ? title
        : language != null && language.isNotEmpty
        ? language
        : '轨道 $id';
    return codec == null || codec.isEmpty ? name : '$name ($codec)';
  }

  /// 切换内嵌字幕轨道。传 [SubtitleTrack.no] 关闭, [SubtitleTrack.auto] 交给 mpv 自选。
  Future<void> setInternalSubtitleTrack(SubtitleTrack track) async {
    await _videoPlayerController?.setSubtitleTrack(track);
  }

  /// 按轨道 id 切换内嵌字幕('auto'=mpv 自选, 'no'=关闭), 供底栏字幕菜单用
  /// (view 层不必依赖 media_kit 的类型)。
  Future<void> selectInternalSubtitleById(String id) async {
    if (id == 'auto') {
      await setInternalSubtitleTrack(SubtitleTrack.auto());
      return;
    }
    if (id == 'no') {
      await setInternalSubtitleTrack(SubtitleTrack.no());
      return;
    }
    for (final t in internalSubtitleTracks) {
      if (t.id == id) {
        await setInternalSubtitleTrack(SubtitleTrack(t.id, t.title, t.language));
        return;
      }
    }
  }

  /// 当前生效字幕的展示名(底栏字幕按钮旁的标签)。
  ///
  /// 优先级与设置面板一致: B 站 CC/外置字幕([ccLabel] 由调用方给出当前
  /// 选中项的名字, null 表示未开启) > mpv 内嵌轨道。
  String currentSubtitleLabel({String? ccLabel}) {
    if (ccLabel != null) {
      return ccLabel;
    }
    final cur = currentTrack.value.subtitle;
    if (cur.id == 'no' || cur.id.isEmpty) {
      return '关闭';
    }
    for (final t in internalSubtitleTracks) {
      if (t.id == cur.id) {
        return trackLabel(
          id: t.id,
          title: t.title,
          language: t.language,
          codec: t.codec,
        );
      }
    }
    return cur.id == 'auto' ? '自动' : cur.id;
  }

  /// 切换内嵌音轨
  Future<void> setInternalAudioTrack(AudioTrack track) async {
    await _videoPlayerController?.setAudioTrack(track);
  }

  /// 按标题选中一条**刚加进去**的外挂字幕轨。
  ///
  /// media_kit 的 `setSubtitleTrack(SubtitleTrack.uri(...))` 走的是 mpv 的
  /// `sub-add <url> cached <title> <lang>`，`cached` 表示只加进列表、不自动选中，
  /// 所以还要等 mpv 把它报进 `track-list` 后按 id 选一次。
  /// 返回是否选中成功（超时没等到就放弃，不影响播放）。
  Future<bool> selectSubtitleByTitle(
    String title, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final t in internalSubtitleTracks) {
        if (t.title == title) {
          await setInternalSubtitleTrack(SubtitleTrack(t.id, t.title, t.language));
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  /// 把外挂字幕加进 mpv 的字幕列表（不选中）
  Future<void> addExternalSubtitle(String url, {required String title}) async {
    await _videoPlayerController?.setSubtitleTrack(
      SubtitleTrack(url, title, 'auto', uri: true),
    );
  }

  // ==================== VR / 全景 ====================
  //
  // VR 重投影在 **mpv 内部**完成(本分支定制的 libmpv, 构建见 tool/libmpv-vr,
  // 设计见 docs/piliplayer.md §15): 硬解之后的常规渲染链先输出"平面画面",
  // 再由球面网格重投影到屏幕(渲染数学与 Cardboard OrientationEKF 头追移植自
  // xl_player); 头追在 libmpv 的 native 侧逐帧运行, 不经过 Dart。
  // Dart 侧只负责下发 mpv 属性:
  //
  //   vr / vr-layout / vr-projection / vr-eye / vr-stereo-output
  //   vr-fov / vr-yaw / vr-pitch / vr-head-tracking / vr-reset-view
  //
  // 反向只读取两个元数据属性(vr_metadata.patch, 「自动(按片源元数据)」
  // 模式的数据来源, 见 _maybeResolveVrAuto):
  //
  //   vr-metadata-projection / vr-metadata-layout
  //
  // 这些属性在 mpv 侧是"热参数": 改动**不会**触发渲染链重建或 GLSL 重编译
  // (那是旧用户着色器方案的根本限制, 见 docs/piliplayer.md §9.1),
  // 拖拽跟手下发即可, 也不再有"变体预算"。手动环视的视角收敛(180° 偏航
  // 边界 / 极点俯仰)由 Dart(clamped)与 native(vr_manual_angles)双层兜底,
  // 头追开启时两侧都放宽(需求第 3 条)。

  /// 当前**生效**的片源布局, [VrProjection.off] 表示普通视频。
  /// 永远不会是 [VrProjection.auto]: auto 是"待解析"状态(见 [vrRequested]),
  /// 解析成功后这里会变成具体的格式。
  final Rx<VrProjection> vrProjection = Rx<VrProjection>(VrProjection.off);

  /// 用户/自动识别**请求**的片源布局, 可以是 [VrProjection.auto]
  /// (按片源元数据识别)。设置面板的「VR/全景」菜单显示与修改的是它;
  /// 环视夹取、属性下发等一律以 [vrProjection](生效值)为准。
  final Rx<VrProjection> vrRequested = Rx<VrProjection>(VrProjection.off);

  /// 本次播放会话内 auto 是否已解析(避免 tracks 事件反复触发解析)
  bool _vrAutoResolved = false;

  /// 本次会话内用户是否**手动**改过片源布局(播放页「VR/全景」菜单)。
  /// 记忆播放设置时用它区分"用户就要平面播"与"这片源本来就不是全景"
  /// —— 前者要记住(下次别再自动识别成 VR), 后者不该写进记忆。
  bool vrUserTouched = false;

  /// VR 渲染视口的宽高比, 由 VrControlLayer 上报;
  /// 用于计算俯仰角的极点收敛边界(与 mpv 侧 vr_manual_angles 同一公式)
  double? _vrAspect;

  void setVrViewport(double width, double height) {
    if (width > 0 && height > 0) {
      _vrAspect = width / height;
    }
  }

  /// VR 操作模式(参考 PiliPlus#364 提出的"切换操作模式"方案)。
  ///
  /// 开启后由 `VrControlLayer` 接管手势, 播放器原有手势(左右进退、
  /// 上下亮度/音量、上下滑全屏、双指缩放画面)全部让位, 因此不会与
  /// PiliPlus 自身的双指缩放冲突; 退出后立刻恢复常规操作(方便进退/调音量)。
  final RxBool vrControlMode = RxBool(false);

  /// 屏幕按钮的步进量: 每次转动 10°, 视场角每次变化 8°
  static const double vrStepDeg = 10.0;
  static const double vrFovStep = 8.0;

  /// 双目片源渲染哪只眼睛(单屏输出只显示一只)
  late final Rx<VrEye> vrEye = Rx<VrEye>(Pref.vrEye);

  // 「VR 立体分屏输出」(Cardboard 双眼分屏)已按 REQUIREMENTS.md 范围外条款
  // 移除(第十五轮): 真机切换该开关触发 native 渲染路径闪退, 且需求方确认
  // 分屏输出不在交付范围。libmpv 侧 vr-stereo-output 选项保留但不再下发。

  /// 当前视角(手动分量)。实际画面朝向 = 头姿 × 折叠偏置 × 手动偏移
  /// (native 侧合成); HUD 读数用 [vrHudAngles](有效视角), 这里只承载
  /// 拖拽/按钮的手动输入。
  late final Rx<VrViewState> vrView = Rx<VrViewState>(
    VrViewState(fov: Pref.vrDefaultFov),
  );

  bool get vrEnabled => vrProjection.value.enabled;

  /// 当前 libmpv 是否带 VR 渲染补丁(本分支 CI 构建的安卓 arm64 包)。
  /// 播放器创建后探测一次; 未打补丁的平台(桌面)或旧包上, VR 入口会明确
  /// 提示不可用, 而不是静默没反应。
  final RxBool vrMpvSupported = RxBool(false);

  /// 新播放器实例创建后需要先探测一次 VR 支持(见 `_createVideoController`)
  bool _vrProbePending = false;

  /// 本 fork 的 media_kit 里 `Player` 就是 `NativePlayer`(typedef),
  /// setProperty/getProperty 都是直连 libmpv 的同步 FFI 调用。
  NativePlayer? get _vrNativePlayer => _videoPlayerController;

  /// 探测 libmpv 是否支持 VR: 补丁把 `vr` 注册成了全局属性(flag, 读到
  /// yes/no); 未打补丁的 libmpv 对不存在的属性返回空串。
  void _detectVrSupport() {
    final player = _vrNativePlayer;
    if (player == null) {
      vrMpvSupported.value = false;
      return;
    }
    try {
      final probe = player.getProperty('vr');
      vrMpvSupported.value = probe == 'yes' || probe == 'no';
    } catch (_) {
      vrMpvSupported.value = false;
    }
    if (!vrMpvSupported.value && vrEnabled && Platform.isAndroid) {
      vrControlMode.value = false;
      setVrGyro(false, persist: false, toast: false);
      _toastVrEngineUnsupported();
    }
  }

  /// 下发节奏: **每帧最多一次**(第二十轮 需求6)。
  ///
  /// 旧实现按 30ms 节流(≈33Hz), 而陀螺仪头追是在补丁版 libmpv 里**逐帧**
  /// 跑的(还带 33ms 前视补偿)。真机对比下来就是"摇杆/拖拽明显不如陀螺仪
  /// 跟手": 60/90/120Hz 的屏幕上, 画面角度只有 33Hz 在动, 台阶感很强。
  ///
  /// 现在改用 SchedulerBinding 的帧回调合并: 一帧内来多少次输入都只写一次
  /// 属性, 但**每一帧都会写** —— 更新率与屏幕刷新率一致。下发次数仍然可控:
  /// yaw/pitch/fov 早已合并进单个 `vr-view` 属性(第十五轮的优化), 差分下发
  /// 又保证值没变的属性不重复写, 所以每帧最多 1 次跨线程往返
  /// (对比第十五轮出问题时的是 ~300 次/s)。
  bool _vrFrameScheduled = false;

  void _initVrState(
    VrProjection? hint,
    String source, {
    bool autoDetect = false,
  }) {
    VrProjection requested;
    if (hint != null) {
      requested = hint;
    } else if (autoDetect) {
      // 本地/局域网源: 「VR/全景自动识别」开启时按文件名关键词识别, 识别不到
      // 回退「自动(按片源元数据)」(需求第 5 条), 待文件加载后由
      // _maybeResolveVrAuto 解析; 该开关关闭时不做任何自动进入(用户可在
      // 播放页菜单手动选, 含「自动」)。
      requested = Pref.vrAutoDetect
          ? VrProjection.detectFromName(mediaName(source))
          : VrProjection.off;
    } else {
      // 在线源地址里常带 360/1080p 之类的清晰度字样, 不猜;
      // 需要 VR 时在播放页菜单里手动选择(含「自动」)
      requested = VrProjection.off;
    }
    vrRequested.value = requested;
    _vrAutoResolved = false;
    vrUserTouched = false;
    // auto 解析前按平面播放(解析结果出来才切 VR, 见 _maybeResolveVrAuto)
    vrProjection.value =
        requested == VrProjection.auto ? VrProjection.off : requested;
    vrView.value = VrViewState(fov: Pref.vrDefaultFov);
    _vrFrameScheduled = false;
    if (!vrEnabled) {
      vrControlMode.value = false;
      setVrGyro(false, persist: false, toast: false);
      return;
    }
    if (!Platform.isAndroid) {
      // 桌面端 libmpv 未打 VR 补丁: 明确提示, 不进入操作模式
      vrControlMode.value = false;
      setVrGyro(false, persist: false, toast: false);
      SmartDialog.showToast(_vrEngineUnsupportedMessage);
      return;
    }
    vrControlMode.value = true;
    setVrGyro(Pref.vrGyro, persist: false, toast: false);
    SmartDialog.showToast(
      '已识别为${vrProjection.value.label}片源，已进入 VR 操作模式\n'
      '单指拖拽环视，双指缩放视场角，也可用屏幕按钮微调',
      displayTime: const Duration(milliseconds: 3000),
    );
  }

  /// 引擎不支持 VR 时的统一提示文案(需求第 8 条: 必须明确提示, 不静默失效)
  String get _vrEngineUnsupportedMessage => Platform.isAndroid
      ? '当前 libmpv 不含 VR 渲染支持，请安装本分支 CI 构建的包'
      : '当前平台的 libmpv 不支持 VR 渲染(仅安卓)';

  void _toastVrEngineUnsupported() =>
      SmartDialog.showToast(_vrEngineUnsupportedMessage);

  /// 「自动(按片源元数据)」解析: 读取定制 libmpv 的 `vr-metadata-*` 只读属性
  /// (vr_metadata.patch 从容器 side data 提取), 映射成具体片源布局。
  ///
  /// 触发时机: ① 文件加载后轨道列表就绪(stream.tracks 首次带视频轨);
  /// ② 用户在播放中手动选「自动」(此时文件已加载, 立即解析)。
  /// [userRequested] 为 true 时, "没有元数据"也要明确提示(用户主动选的);
  /// 文件名回退进来的 auto 则静默保持平面(普通视频不该被打扰)。
  void _maybeResolveVrAuto({bool userRequested = false, int attempt = 0}) {
    if (vrRequested.value != VrProjection.auto || _vrAutoResolved) {
      return;
    }
    final player = _vrNativePlayer;
    // 延迟重试可能落在播放器销毁之后(退出页面), 别再碰属性
    if (player == null || _playerCount == 0) {
      return;
    }
    if (!vrMpvSupported.value) {
      _vrAutoResolved = true;
      if (userRequested) {
        _toastVrEngineUnsupported();
      }
      return;
    }
    String projection;
    try {
      projection = player.getProperty('vr-metadata-projection');
    } catch (_) {
      // 与销毁竞态等: 放弃本次解析, 不打扰播放
      _vrAutoResolved = true;
      return;
    }
    if (projection.isEmpty) {
      // 文件还没加载完 / 当前视频轨还没选定(TRACKS_CHANGED 可能早于选定轨),
      // 或纯音频文件根本没有视频轨: 有限次重试, 不置 resolved。
      if (attempt < 6) {
        Future.delayed(
          const Duration(milliseconds: 400),
          () => _maybeResolveVrAuto(
            userRequested: userRequested,
            attempt: attempt + 1,
          ),
        );
        return;
      }
      // 重试耗尽仍读不到: 放弃。用户手动选「自动」时明确提示(需求第 8 条);
      // 文件名回退进来的 auto 保持静默(普通/纯音频视频不该被打扰)。
      _vrAutoResolved = true;
      if (userRequested) {
        SmartDialog.showToast('读不到片源全景元数据，按普通视频播放');
      }
      return;
    }
    _vrAutoResolved = true;
    String layout;
    try {
      layout = player.getProperty('vr-metadata-layout');
    } catch (_) {
      layout = '';
    }
    final resolution = VrProjection.resolveMetadata(
      projection: projection,
      layout: layout,
    );
    if (resolution.isVr) {
      _applyAutoResolvedVr(resolution.projection);
    } else if (resolution.unsupportedReason != null) {
      // 范围外格式(cubemap/鱼眼/棋盘格…): 明确提示, 按平面播放
      SmartDialog.showToast(
        resolution.unsupportedReason!,
        displayTime: const Duration(seconds: 4),
      );
    } else if (userRequested) {
      SmartDialog.showToast('片源没有全景元数据，按普通视频播放');
    }
  }

  /// auto 解析出全景片源: 原位切到 VR(不重载文件、不丢进度),
  /// 进入操作模式并提示识别结果
  void _applyAutoResolvedVr(VrProjection projection) {
    if (!Platform.isAndroid) {
      SmartDialog.showToast(_vrEngineUnsupportedMessage);
      return;
    }
    vrProjection.value = projection;
    vrView.value = VrViewState(fov: vrView.value.fov);
    applyVrView(force: true);
    vrControlMode.value = true;
    setVrGyro(Pref.vrGyro, persist: false, toast: false);
    SmartDialog.showToast(
      '按片源元数据识别为${projection.label}，已进入 VR 操作模式\n'
      '单指拖拽环视，双指缩放视场角，也可用屏幕按钮微调',
      displayTime: const Duration(milliseconds: 3000),
    );
  }

  /// 从路径/URL 中取出文件名
  static String mediaName(String source) {
    var name = source;
    final query = name.indexOf('?');
    if (query >= 0) {
      name = name.substring(0, query);
    }
    final slash = name.lastIndexOf('/');
    return slash >= 0 ? name.substring(slash + 1) : name;
  }

  /// 进入/退出 VR 操作模式
  void setVrControlMode(bool value) {
    if (value && !vrEnabled) {
      SmartDialog.showToast('请先在「播放器设置 → VR/全景」选择片源布局');
      return;
    }
    if (vrControlMode.value == value) {
      return;
    }
    vrControlMode.value = value;
    if (value) {
      // 进入操作模式先点亮控件(VR 的 HUD/按钮随 showControls 自动隐藏)
      controls = true;
      // 进入时强制下发一次: 单例播放器可能在属性下发之前就已创建
      applyVrView(force: true);
      // 头追跟随设置项自动启停(退出控制模式即停, 不与常规手势抢方向)
      setVrGyro(Pref.vrGyro, persist: false, toast: false);
      SmartDialog.showToast(
        'VR 操作模式：单指拖拽环视，双指缩放视场角\n'
        '手柄：右摇杆环视，△ 摆正视角，□ 切换眼位\n'
        '点按顶部提示条可退回常规操作',
        displayTime: const Duration(milliseconds: 3500),
      );
    } else {
      setVrGyro(false, persist: false, toast: false);
    }
  }

  /// 切换片源布局。播放中切换只改 mpv 热属性, 不重载文件,
  /// 当前进度原位生效(需求第 6 条)。
  Future<void> setVrProjection(
    VrProjection projection, {
    bool resetView = true,
  }) async {
    vrUserTouched = true;
    vrRequested.value = projection;
    if (projection == VrProjection.auto) {
      // 立即按元数据解析(文件已加载); 引擎不支持时 _maybeResolveVrAuto
      // 会明确提示
      _vrAutoResolved = false;
      _maybeResolveVrAuto(userRequested: true);
      return;
    }
    if (projection.enabled && !vrMpvSupported.value) {
      _toastVrEngineUnsupported();
      return;
    }
    _vrAutoResolved = true; // 手动选定后不再自动改写本次会话的布局
    vrProjection.value = projection;
    if (resetView) {
      vrView.value = VrViewState(fov: vrView.value.fov);
    }
    if (projection.enabled) {
      applyVrView(force: true);
      // 选定布局即进入 VR 操作模式, 可随时退出以使用常规手势
      vrControlMode.value = true;
      setVrGyro(Pref.vrGyro, persist: false, toast: false);
    } else {
      vrControlMode.value = false;
      setVrGyro(false, persist: false, toast: false);
      // 退出 VR: 下发 vr=no, 画面回到常规渲染(超分辨率着色器与 VR
      // 不再互斥, 无需恢复处理)
      applyVrView(force: true);
    }
  }

  Future<void> setVrEye(VrEye eye) async {
    if (vrEye.value == eye) {
      return;
    }
    vrEye.value = eye;
    applyVrView(force: true);
  }

  /// 屏幕按钮步进: 偏航/俯仰/视场角
  void vrStep({double dyaw = 0, double dpitch = 0, double dfov = 0}) {
    if (!vrEnabled) {
      return;
    }
    final cur = vrView.value;
    vrView.value = cur
        .copyWith(
          yaw: cur.yaw + dyaw,
          pitch: cur.pitch + dpitch,
          fov: (cur.fov + dfov).clamp(
            VrViewState.minFov,
            VrViewState.maxFov,
          ),
        )
        .clamped(
          vrProjection.value,
          aspect: _vrAspect,
          gyro: vrGyroEnabled.value,
        );
    applyVrView();
  }

  /// 单指拖拽环视
  void onVrLook(
    double dx,
    double dy, {
    required double width,
    required double height,
  }) {
    if (!vrEnabled) {
      return;
    }
    final cur = vrView.value;
    // 一屏宽度对应 1.5 倍水平视场角。
    // 方向对齐 xl_player(SinglePlayerActivity.onScroll 用 GestureDetector 的
    // distanceX/Y = 手指位移取反, 累积进 rotX/rotY): 两轴统一为"拖动世界"
    // 语义 —— 手指右移视线向左, 手指下移视线向上。此前俯仰与手指同向、
    // 水平与手指反向, 两轴不一致(第十五轮真机反馈)。
    final scale = cur.fov * 1.5;
    vrView.value = cur
        .copyWith(
          yaw: cur.yaw - dx * scale / max(width, 1.0),
          pitch: cur.pitch - dy * scale / max(height, 1.0),
        )
        .clamped(
          vrProjection.value,
          aspect: _vrAspect,
          gyro: vrGyroEnabled.value,
        );
    applyVrView();
  }

  // ==================== VR 手柄控制(第十九轮 需求5) ====================

  /// 手柄右摇杆环视。[axisX]/[axisY] 为安卓轴值(右/下为 +1),
  /// [dtSeconds] 是距上次采样的间隔(轮询节奏会抖动, 用它积分才匀速)。
  ///
  /// 死区/角速度/方向约定都在 `GamepadMath`(纯函数, 有单测):
  /// 摇杆推右 = 视线向右(yaw 增大), 摇杆推上 = 视线向上(pitch 减小,
  /// 与 [onVrLook] 的"拖动世界"语义一致)。
  ///
  /// **不会**点亮播放器控件层: 手柄环视时弹出 UI 只会挡住 VR 按钮和画面。
  void onVrGamepadLook(double axisX, double axisY, double dtSeconds) {
    if (!vrEnabled) {
      return;
    }
    final delta = GamepadMath.look(axisX, axisY, dtSeconds);
    if (delta.yaw == 0 && delta.pitch == 0) {
      return;
    }
    vrStep(dyaw: delta.yaw, dpitch: delta.pitch);
  }

  // ==================== 手柄按键长按连发(第二十轮 需求3) ====================

  /// 长按连发的节奏: 与屏幕上 VR 步进按钮(`_VrStepButton`)完全一致 ——
  /// 按下先走一步, 400ms 后开始每 110ms 一步, 松手停。
  static const Duration keyRepeatDelay = Duration(milliseconds: 400);
  static const Duration keyRepeatInterval = Duration(milliseconds: 110);

  Timer? _keyRepeatDelay;
  Timer? _keyRepeatTimer;

  /// 开始连发: 立刻执行一次 [action], 按住不放则持续执行。
  ///
  /// 用**自己的定时器**而不是依赖系统按键重复(KeyRepeatEvent): 各机型/
  /// 各手柄的重复速率差异很大, 而且 Flutter 只在部分平台把长按转成
  /// KeyRepeatEvent, 自己计时才能保证"点一下走一步、按住连续走"。
  void startKeyRepeat(VoidCallback action) {
    stopKeyRepeat();
    action();
    _keyRepeatDelay = Timer(keyRepeatDelay, () {
      _keyRepeatTimer = Timer.periodic(keyRepeatInterval, (_) => action());
    });
  }

  void stopKeyRepeat() {
    _keyRepeatDelay?.cancel();
    _keyRepeatDelay = null;
    _keyRepeatTimer?.cancel();
    _keyRepeatTimer = null;
  }

  /// 切换眼位(手柄方块键 / VR 按钮共用)。
  /// 单目片源明确提示, 不静默无反应(REQUIREMENTS.md 第 8 条)。
  /// 眼位切换的冷却: 单次动作, 长按/按键抖动都不该连着切
  static const Duration vrEyeToggleCooldown = Duration(milliseconds: 400);
  DateTime? _lastVrEyeToggle;

  void toggleVrEye() {
    if (!vrEnabled) {
      return;
    }
    final now = DateTime.now();
    final last = _lastVrEyeToggle;
    if (last != null && now.difference(last) < vrEyeToggleCooldown) {
      return;
    }
    _lastVrEyeToggle = now;
    if (!vrProjection.value.isStereo) {
      SmartDialog.showToast('当前是单目片源，没有左右眼可切换');
      return;
    }
    final next = vrEye.value == VrEye.left ? VrEye.right : VrEye.left;
    unawaited(setVrEye(next));
    SmartDialog.showToast('已切换到${next.label}');
  }

  /// 设置水平视场角(双指缩放的绝对映射)
  void setVrFov(double fov) {
    if (!vrEnabled) {
      return;
    }
    vrView.value = vrView.value
        .copyWith(fov: fov.clamp(VrViewState.minFov, VrViewState.maxFov))
        .clamped(
          vrProjection.value,
          aspect: _vrAspect,
          gyro: vrGyroEnabled.value,
        );
    applyVrView();
  }

  /// 双指缩放的相对映射
  void onVrZoom(double factor) {
    if (!vrEnabled || factor <= 0) {
      return;
    }
    setVrFov(vrView.value.fov / factor);
  }

  // ==================== VR 头追 ====================

  /// 头追开关(运行时; 新会话的默认值见 `Pref.vrGyro`)。
  /// 实现在 libmpv native 侧(NDK 传感器线程 + Cardboard OrientationEKF,
  /// 移植自 xl_player, 含 33ms 前视补偿), Dart 只下发 `vr-head-tracking`
  /// 属性; 拖拽/按钮的手动偏移与头姿在 native 侧叠加。
  final RxBool vrGyroEnabled = RxBool(false);

  void setVrGyro(bool value, {bool persist = true, bool toast = true}) {
    if (value && !vrEnabled) {
      if (toast) {
        SmartDialog.showToast('请先在「播放器设置 → VR/全景」选择片源布局');
      }
      return;
    }
    if (persist) {
      GStorage.setting.put(SettingBoxKey.vrGyro, value);
    }
    if (vrGyroEnabled.value == value) {
      return;
    }
    vrGyroEnabled.value = value;
    applyVrView(force: true);
  }

  /// 重置视角: 手动偏移清零, 并让 native 以当前头姿作为新的参考朝向
  /// (`vr-reset-view` 是递增计数, mpv 侧检测到变化才动作)
  int _vrResetSeq = 0;
  void resetVrView() {
    vrView.value = VrViewState(fov: vrView.value.fov);
    _vrResetSeq++;
    final player = _vrNativePlayer;
    if (player != null && vrMpvSupported.value) {
      try {
        player.setProperty('vr-reset-view', '$_vrResetSeq');
      } catch (_) {
        // 下发失败不阻断: 手动偏移已经清零
      }
    }
    applyVrView(force: true);
  }

  /// 把当前视角/布局应用到 mpv(每帧合并一次; [force] 立即全量重发)
  void applyVrView({bool force = false}) {
    if (force) {
      // 立即下发(进/出 VR 模式、切布局、摆正视角这些一次性动作),
      // 帧回调那条路照常, 反正写的是同一份最新状态
      _applyVrProperties(force: true);
      return;
    }
    if (_vrFrameScheduled) {
      return; // 本帧已经排上了, 回调里取的是那一刻的最新角度
    }
    _vrFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _vrFrameScheduled = false;
      _applyVrProperties();
    });
  }

  /// 上次成功下发的 VR 属性值(差分下发用)。新建播放器实例时清空。
  final Map<String, String> _vrSent = {};

  void _vrSend(NativePlayer player, String key, String value) {
    if (_vrSent[key] == value) {
      return;
    }
    player.setProperty(key, value);
    _vrSent[key] = value;
  }

  /// 下发 VR 属性(差分 + 合并)。
  ///
  /// **每个 setProperty 都是一次"客户端→mpv core 同步派发→core→VO 同步
  /// 握手"的跨线程往返**(第十五轮真机"手势拖动卡顿而陀螺仪流畅"的根因:
  /// 旧实现每批全量 9 个属性 × ~33 批/s ≈ 300 次往返/s)。因此:
  ///   * 值没变的属性不再重复下发([force] 时全量重发);
  ///   * 连续的视角参数(yaw/pitch/fov)合并进单个 `vr-view` 字符串属性,
  ///     拖拽一批只有 1 次往返(libmpv 补丁侧解析, 见 docs §20)。
  void _applyVrProperties({bool force = false}) {
    final player = _vrNativePlayer;
    if (player == null || !vrMpvSupported.value) {
      return;
    }
    if (force) {
      _vrSent.clear();
    }
    final projection = vrProjection.value;
    final view = vrView.value;
    try {
      _vrSend(player, 'vr', projection.enabled ? 'yes' : 'no');
      if (!projection.enabled) {
        return;
      }
      _vrSend(player, 'vr-layout', projection.mpvLayout);
      _vrSend(player, 'vr-projection', projection.mpvCoverage);
      _vrSend(player, 'vr-eye', vrEye.value == VrEye.left ? 'left' : 'right');
      _vrSend(
        player,
        'vr-view',
        'yaw=${view.yaw.toStringAsFixed(2)},'
        'pitch=${view.pitch.toStringAsFixed(2)},'
        'fov=${view.fov.toStringAsFixed(2)}',
      );
      _vrSend(
        player,
        'vr-head-tracking',
        vrGyroEnabled.value ? 'yes' : 'no',
      );
      vrError.value = null;
    } catch (err) {
      _reportVrError('下发 VR 属性失败: $err');
    }
  }

  /// native 每帧缓存的**有效**视角中心(手动偏移+折叠偏置+头姿的合成结果,
  /// `vr-view-yaw`/`vr-view-pitch` 只读属性)。HUD 显示它而不是 vrView——
  /// 陀螺仪/折叠偏置参与后 vrView 只是手动分量(第十五轮真机反馈:
  /// "陀螺仪运动不影响 HUD 读数, 两种输入的量是分开的")。
  /// null = 尚不可用(旧引擎/未渲染), HUD 回退显示 vrView。
  final Rxn<(double, double)> vrHudAngles = Rxn<(double, double)>();

  /// 轮询有效视角(VrControlLayer 可见期间 ~5Hz; getProperty 是同步往返,
  /// 频率刻意压低)
  void pollVrHudAngles() {
    final player = _vrNativePlayer;
    if (player == null || !vrMpvSupported.value || !vrEnabled) {
      return;
    }
    try {
      final yaw = double.tryParse(player.getProperty('vr-view-yaw'));
      final pitch = double.tryParse(player.getProperty('vr-view-pitch'));
      if (yaw != null && pitch != null) {
        vrHudAngles.value = (yaw, pitch);
      }
    } catch (_) {
      // 旧引擎没有该属性: 保持 null, HUD 回退 vrView
    }
  }

  void _reportVrError(String message) {
    vrError.value = message;
    SmartDialog.showToast(
      'VR 未生效: $message',
      displayTime: const Duration(seconds: 6),
    );
  }

  /// 最近一次 VR 相关错误, 便于定位"操作没反应"的问题
  final RxnString vrError = RxnString();

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);

    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
      'volume-max': kMaxVolume.toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );

    // 本地/局域网媒体不带 B 站 UA 与 Referer: 既无必要, 也会被部分
    // NAS/HTTP 服务器当作非法请求拒绝
    if (!isLocalMedia) {
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: HttpString.baseUrl,
      );
    }

    _startListeners(player);

    _vrProbePending = true;
    _vrSent.clear();
    vrHudAngles.value = null;
    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    // VR 属性每次装载新源都要重新下发: PlPlayerController 是单例,
    // 切集/换视频时播放器不会重建; 非 VR 片源也要下发一次 vr=no,
    // 防止复用播放器上残留着上一个片源的 VR 状态。
    // (新播放器先探测一次 libmpv 是否带 VR 补丁)
    if (_vrProbePending) {
      _vrProbePending = false;
      _detectVrSupport();
    }
    if (vrMpvSupported.value) {
      _applyVrProperties();
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLocalMedia)
        // 本地/局域网网络源: VLC 式小缓冲。在线档的 cache-secs 会被 mpv
        // 抬成前向预读目标, 大跨度 seek 后等于把十几秒内容重新下载一遍;
        // 局域网随机访问廉价(Range -> 带偏移 SMB2 READ), 小缓冲即可
        ...Pref.initLocalBuffer()
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (isLive) {
      await setPlaybackSpeed(1.0);
    } else {
      if (_videoPlayerController?.state.rate != _playbackSpeed.value) {
        await setPlaybackSpeed(_playbackSpeed.value);
      }
    }
    _initVideoFit();
    // if (_looping) {
    //   await setLooping(_looping);
    // }

    // 跳转播放
    // if (seekTo != Duration.zero) {
    //   await this.seekTo(seekTo);
    // }

    // 自动播放
    if (_autoPlay) {
      playIfExists();
      // await play(duration: duration);
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// mpv 自己的轨道表: 内嵌字幕/音轨要靠它才能列给用户
      /// (B 站视频没有内嵌轨, 本地/局域网片源经常有)
      stream.tracks.listen((tracks) {
        mpvTracks.value = tracks;
        // 轨道表就绪: 尝试解析「自动(按片源元数据)」。注意 mpv 的
        // TRACKS_CHANGED 可能在"选定当前视频轨"之前触发, 此刻读 vr-metadata-*
        // 可能仍是"不可用"(空串), 故 _maybeResolveVrAuto 内带有限重试;
        // 下面 stream.track(选定轨变化)是更可靠的时机, 两处都触发一次。
        if (tracks.video.isNotEmpty) {
          _maybeResolveVrAuto();
        }
      }),

      /// 当前实际选中的轨道, 面板上"当前字幕流"以此为准
      stream.track.listen((track) {
        currentTrack.value = track;
        // 选定视频轨后 current_track 才就位, vr-metadata-* 属性此时可读,
        // 这是「自动(按片源元数据)」解析最可靠的触发点(与字幕同一套 id 约定:
        // 'no'/空 表示没有选定视频轨)
        final vid = track.video.id;
        if (vid != 'no' && vid.isNotEmpty) {
          _maybeResolveVrAuto();
        }
      }),

      /// playing
      stream.playing.listen((bool playing) {
        WakelockPlus.toggle(enable: playing);
        if (playing) {
          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
          playerStatus.value = .playing;
        } else {
          _disableAutoEnterPip();
          playerStatus.value = .paused;
        }

        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          isBuffering.value,
          isLive,
        );

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus.value = .completed;

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          this.position.value = posInSeconds;

          videoPlayerServiceHandler?.onPositionChange(position);

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen(updateDuration),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          buffering,
          isLive,
        );
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Future.delayed(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Future.delayed(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == 0) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer();
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    Future<void> seek() async {
      if (isSeek) {
        /// 拖动进度条调节时，不等待第一帧，防止抖动
        await _videoPlayerController?.stream.buffer.first;
      }
      danmakuController?.clear();
      try {
        await _videoPlayerController?.seek(position);
      } catch (e) {
        if (kDebugMode) debugPrint('seek failed: $e');
      }
    }

    if (duration.value != 0) {
      seek();
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek();
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) {
      return;
    }

    await _videoPlayerController?.setRate(speed);
    _playbackSpeed.value = speed;
    if (danmakuController != null) {
      try {
        DanmakuOption currentOption = danmakuController!.option;
        double defaultDuration = currentOption.duration * lastPlaybackSpeed;
        double defaultStaticDuration =
            currentOption.staticDuration * lastPlaybackSpeed;
        DanmakuOption updatedOption = currentOption.copyWith(
          duration: defaultDuration / speed,
          staticDuration: defaultStaticDuration / speed,
        );
        danmakuController!.updateOption(updatedOption);
      } catch (_) {}
    }
  }

  // 还原默认速度
  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await _videoPlayerController?.setRate(playSpeedDefault);
    _playbackSpeed.value = playSpeedDefault;
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      // await seekTo(Duration.zero);
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus.value = PlayerStatus.playing;
    // screenManager.setOverlays(false);
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus.value = PlayerStatus.paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        // 本地/局域网媒体: 不上报 B 站播放历史
        isLocalMedia ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    stopKeyRepeat();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    // 真机反馈「退出视频后仍在传输」的加固(第十三轮): mpv 活着 = demuxer
    // 缓存继续从局域网/在线源拉流。两处保险:
    //   ① 先摘监听、立刻向 mpv 下发 stop(网络取流马上停, 不等销毁流程);
    //   ② 播放器销毁放进 finally —— 下面这条清理链很长, 任何一步抛异常
    //      都不能再把播放器落下(落下就是无限期继续下载)。
    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    setPlayCallBack(null);
    try {
      final player = _videoPlayerController;
      if (player != null) {
        unawaited(player.command(const ['stop']).catchError((Object _) {}));
      }
    } catch (_) {
      // 已销毁等竞态: dispose 内部还会再 stop 一次, 忽略
    }
    try {
      if (removeSafeArea) {
        showSystemBar();
      }
      danmakuController = null;
      mpvTracks.value = const Tracks();
      currentTrack.value = const Track();
      // VR 状态是单次播放会话的, 播放器销毁后复位
      // (头追随 mpv 实例一起销毁, Dart 侧没有需要停的传感器)
      vrProjection.value = VrProjection.off;
      vrRequested.value = VrProjection.off;
      _vrAutoResolved = false;
      _vrAspect = null;
      vrControlMode.value = false;
      vrError.value = null;
      vrGyroEnabled.value = false;
      vrMpvSupported.value = false;
      _vrFrameScheduled = false;
      isLocalMedia = false;
      _stopOrientationListener();
      _disableAutoEnterPip();
      dmState.clear();
      if (showSeekPreview) {
        _clearPreview();
      }
      if (Platform.isAndroid) {
        AndroidHelper$ToDart.onUserLeaveHint?.release();
        AndroidHelper$ToDart.onUserLeaveHint = null;
      }
      _timer?.cancel();
      // _position.close();
      // _playerEventSubs?.cancel();
      // _sliderPosition.close();
      // _sliderTempPosition.close();
      // _isSliderMoving.close();
      // _duration.close();
      // _buffered.close();
      // _showControls.close();
      // _controlsLock.close();

      // playerStatus.close();
      // dataStatus.close();

      if (playerStatus.isPlaying) {
        WakelockPlus.disable();
      }
    } finally {
      if (kDebugMode) {
        debugPrint('dispose player');
      }
      _videoPlayerController?.dispose();
      _videoPlayerController = null;
      _videoController = null;
      _instance = null;
      videoPlayerServiceHandler?.clear();
    }
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    // 本地/局域网媒体没有 bvid/cid, 也不该向 B 站请求预览图
    if (isLocalMedia || _bvid == null || cid == null) {
      return;
    }
    videoShot = await VideoHttp.videoshot(bvid: _bvid!, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗保存截图');
      showDialog(
        context: Get.context!,
        builder: (context) => GestureDetector(
          onTap: () async {
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          },
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      ).whenComplete(image.dispose);
    } else {
      SmartDialog.showToast('截图失败');
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
