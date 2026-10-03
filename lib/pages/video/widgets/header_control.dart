import 'dart:async' show Timer, unawaited;
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show Platform, File;
import 'dart:typed_data' show Uint8List;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/button/icon_button.dart';
import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/dialog/report.dart';
import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/common/widgets/marquee.dart';
import 'package:PiliPlus/http/danmaku.dart';
import 'package:PiliPlus/http/danmaku_block.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show showPlayerVolumeDialog;
import 'package:PiliPlus/pages/setting/widgets/popup_item.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/action_item.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/pages/video/widgets/header_mixin.dart';
import 'package:PiliPlus/pages/video/introduction/local_media/controller.dart';
import 'package:PiliPlus/services/floating_player.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart'
    show shutdownTimerService, ShutdownPanel;
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart' hide showBottomSheet;
import 'package:media_kit/media_kit.dart'
    show AudioTrack, NativePlayer, SubtitleTrack;

mixin TimeBatteryMixin<T extends StatefulWidget> on State<T> {
  PlPlayerController get plPlayerController;
  late final titleKey = GlobalKey();
  ContextSingleTicker? provider;
  ContextSingleTicker get effectiveProvider => provider ??= ContextSingleTicker(
    context,
    autoStart: () =>
        plPlayerController.showControls.value &&
        !plPlayerController.controlsLock.value,
  );

  bool get isPortrait;
  bool get isFullScreen;
  bool get horizontalScreen;

  Timer? _clock;
  RxString now = ''.obs;

  static final _format = DateFormat('HH:mm');

  @override
  void dispose() {
    stopClock();
    super.dispose();
  }

  void startClock() {
    if (!_showCurrTime) return;
    if (_clock == null) {
      now.value = _format.format(DateTime.now());
      _clock ??= Timer.periodic(const Duration(seconds: 1), (Timer t) {
        if (!mounted) {
          stopClock();
          return;
        }
        now.value = _format.format(DateTime.now());
      });
    }
  }

  void stopClock() {
    _clock?.cancel();
    _clock = null;
  }

  bool _showCurrTime = false;
  void showCurrTimeIfNeeded(bool isFullScreen) {
    _showCurrTime = !isPortrait && (isFullScreen || !horizontalScreen);
    if (!_showCurrTime) {
      stopClock();
    }
  }

  late final _battery = Battery();
  late final RxnInt _batteryLevel = RxnInt();
  late final _showBatteryLevel = Pref.showBatteryLevel;
  void getBatteryLevelIfNeeded() {
    if (!_showCurrTime || !_showBatteryLevel) return;
    EasyThrottle.throttle(
      'getBatteryLevel$hashCode',
      const Duration(seconds: 30),
      () async {
        try {
          _batteryLevel.value = await _battery.batteryLevel;
        } catch (_) {}
      },
    );
  }

  List<Widget>? get timeBatteryWidgets {
    if (_showCurrTime) {
      return [
        if (_showBatteryLevel) ...[
          Obx(
            () {
              final batteryLevel = _batteryLevel.value;
              if (batteryLevel == null) {
                return const SizedBox.shrink();
              }
              return Text(
                '$batteryLevel%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                ),
              );
            },
          ),
          const SizedBox(width: 10),
        ],
        Obx(
          () => Text(
            now.value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
            ),
          ),
        ),
      ];
    }
    return null;
  }
}

class HeaderControl extends StatefulWidget {
  const HeaderControl({
    required this.isPortrait,
    required this.controller,
    required this.videoDetailCtr,
    required this.heroTag,
    super.key,
  });

  final bool isPortrait;
  final PlPlayerController controller;
  final VideoDetailController videoDetailCtr;
  final String heroTag;

  @override
  State<HeaderControl> createState() => HeaderControlState();

  static Future<bool> likeDanmaku(VideoDanmaku extra, int cid) async {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('请先登录');
      return false;
    }
    final isLike = !extra.isLike;
    final res = await DanmakuHttp.danmakuLike(
      isLike: isLike,
      cid: cid,
      id: extra.id,
    );
    if (res.isSuccess) {
      extra.isLike = isLike;
      if (isLike) {
        extra.like++;
      } else {
        extra.like--;
      }
      SmartDialog.showToast('${isLike ? '' : '取消'}点赞成功');
      return true;
    } else {
      res.toast();
      if (res case Error(:final code)) {
        if (code == 65006) {
          extra.isLike = true;
          return true;
        }
        if (code == 65004) {
          extra.isLike = false;
          return true;
        }
      }
      return false;
    }
  }

  static Future<bool> deleteDanmaku(int id, int cid) async {
    final res = await DanmakuHttp.danmakuRecall(
      cid: cid,
      id: id,
    );
    if (res.isSuccess) {
      SmartDialog.showToast('删除成功');
      return true;
    } else {
      res.toast();
      return false;
    }
  }

  static Future<void> reportDanmaku(
    BuildContext context, {
    required VideoDanmaku extra,
    required PlPlayerController ctr,
  }) {
    if (Accounts.main.isLogin) {
      return autoWrapReportDialog(
        context,
        ReportOptions.danmakuReport,
        withContent: ReportOptions.danmakuReportCheck,
        contentRequired: ReportOptions.danmakuReportCheck,
        (reasonType, reasonDesc, banUid) {
          if (banUid) {
            final filter = ctr.filters;
            if (filter.dmUid.add(extra.mid)) {
              filter.count++;
              GStorage.localCache.put(LocalCacheKey.danmakuFilterRules, filter);
            }
            DanmakuFilterHttp.danmakuFilterAdd(filter: extra.mid, type: 2);
          }
          return DanmakuHttp.danmakuReport(
            reason: reasonType,
            cid: ctr.cid!,
            id: extra.id,
            content: reasonDesc,
          );
        },
      );
    } else {
      return SmartDialog.showToast('请先登录');
    }
  }

  static Future<void> reportLiveDanmaku(
    BuildContext context, {
    required int roomId,
    required String msg,
    required LiveDanmaku extra,
  }) {
    if (Accounts.main.isLogin) {
      return autoWrapReportDialog(
        context,
        ban: false,
        ReportOptions.liveDanmakuReport,
        withContent: ReportOptions.liveDanmakuReportCheck,
        contentRequired: ReportOptions.liveDanmakuReportCheck,
        (reasonType, reasonDesc, banUid) {
          // if (banUid) {
          //   final filter = ctr.filters;
          //   if (filter.dmUid.add(extra.mid)) {
          //     filter.count++;
          //     GStorage.localCache.put(
          //       LocalCacheKey.danmakuFilterRules,
          //       filter,
          //     );
          //   }
          //   DanmakuFilterHttp.danmakuFilterAdd(
          //     filter: extra.mid,
          //     type: 2,
          //   );
          // }
          return LiveHttp.liveDmReport(
            roomId: roomId,
            mid: extra.mid,
            msg: msg,
            reason: ReportOptions.liveDanmakuReport['']![reasonType]!,
            reasonId: reasonType,
            dmType: extra.dmType,
            idStr: extra.id,
            ts: extra.ts,
            sign: extra.ct,
          );
        },
      );
    } else {
      return SmartDialog.showToast('请先登录');
    }
  }
}

class HeaderControlState extends State<HeaderControl>
    with HeaderMixin, TimeBatteryMixin {
  @override
  late final PlPlayerController plPlayerController = widget.controller;
  late final VideoDetailController videoDetailCtr = widget.videoDetailCtr;
  late final PlayUrlModel videoInfo = videoDetailCtr.data;
  static const TextStyle subTitleStyle = TextStyle(fontSize: 12);
  static const TextStyle titleStyle = TextStyle(fontSize: 14);

  String get heroTag => widget.heroTag;
  late final UgcIntroController ugcIntroController;
  late final PgcIntroController pgcIntroController;
  late final LocalIntroController localIntroController;
  late final LocalMediaIntroController localMediaIntroController;
  late CommonIntroController introController = videoDetailCtr.isLocalMedia
      ? localMediaIntroController
      : isFileSource
      ? localIntroController
      : videoDetailCtr.isUgc
      ? ugcIntroController
      : pgcIntroController;

  @override
  bool get isPortrait => widget.isPortrait;
  @override
  late final horizontalScreen = videoDetailCtr.horizontalScreen;

  Box setting = GStorage.setting;

  @override
  void initState() {
    super.initState();
    if (videoDetailCtr.isLocalMedia) {
      introController = Get.find<LocalMediaIntroController>(tag: heroTag);
    } else if (isFileSource) {
      introController = Get.find<LocalIntroController>(tag: heroTag);
    } else if (videoDetailCtr.isUgc) {
      introController = Get.find<UgcIntroController>(tag: heroTag);
    } else {
      introController = Get.find<PgcIntroController>(tag: heroTag);
    }
  }

  /// 画中画(点按入口): 优先**系统** PiP(独立 Activity, 应用内可继续浏览);
  /// 这条路走不通(设备不支持/系统拒绝/surface 没起来)时依次退回
  /// ① 老的"整应用系统 PiP" ② 应用内浮窗 —— 保证按钮永远有反应。
  Future<void> enterPip(BuildContext context) async {
    final service = FloatingPlayerService.instance;
    final args = videoDetailCtr.args;
    final title = args['title']?.toString() ?? '正在播放';
    // context 只在同步阶段用一次(await 之后不再碰, 免得页面已销毁)
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    final ok = await service.enterSystemPip(
      navigator: navigator,
      controller: plPlayerController,
      title: title,
      restoreArgs: args,
    );
    if (ok) {
      return;
    }
    if (AndroidHelper.isPipAvailable) {
      plPlayerController.enterPip();
      return;
    }
    service.enter(
      navigator: navigator,
      controller: plPlayerController,
      title: title,
      restoreArgs: args,
    );
  }

  /// 应用内浮窗(长按入口): 不出系统 PiP, 纯 Flutter 层的 root Overlay 小窗
  void enterInAppPip(BuildContext context) {
    final args = videoDetailCtr.args;
    FloatingPlayerService.instance.enter(
      navigator: Navigator.maybeOf(context, rootNavigator: true),
      controller: plPlayerController,
      title: args['title']?.toString() ?? '正在播放',
      restoreArgs: args,
    );
  }

  /// 设置面板
  void showSettingSheet() {
    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 14),
              children: [
                // 稍后再看/笔记都是 B 站账号体系下的功能, 本地媒体没有对应实体
                if (!isLocalMedia) ...[
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      introController.viewLater();
                    },
                    leading: const Icon(Icons.watch_later_outlined, size: 20),
                    title: const Text('添加至「稍后再看」', style: titleStyle),
                  ),
                  if (videoDetailCtr.epId == null)
                    ListTile(
                      dense: true,
                      onTap: () {
                        Get.back();
                        videoDetailCtr.showNoteList(context);
                      },
                      leading: const Icon(Icons.note_alt_outlined, size: 20),
                      title: const Text('查看笔记', style: titleStyle),
                    ),
                ],
                if (!isFileSource)
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      videoDetailCtr.onDownload(this.context);
                    },
                    leading: const Icon(
                      MdiIcons.folderDownloadOutline,
                      size: 20,
                    ),
                    title: const Text('离线缓存', style: titleStyle),
                  ),
                if (widget.videoDetailCtr.cover.value.isNotEmpty)
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      ImageUtils.downloadImg([
                        widget.videoDetailCtr.cover.value,
                      ]);
                    },
                    leading: const Icon(Icons.image_outlined, size: 20),
                    title: const Text('保存封面', style: titleStyle),
                  ),
                ListTile(
                  dense: true,
                  onTap: () {
                    Get.back();
                    shutdownTimerService.showScheduleExitDialog(
                      this.context,
                      isFullScreen: isFullScreen,
                    );
                  },
                  leading: const Icon(Icons.hourglass_top_outlined, size: 20),
                  title: const Text('定时关闭', style: titleStyle),
                  subtitle: shutdownTimerService.isActive
                      ? ShutdownPanel(
                          buildCountdownText: (text) =>
                              Text(text == null ? '已结束' : '剩余 $text'),
                          builder: (
                            context,
                            countdown,
                            onCountdown,
                            setState,
                          ) => countdown,
                        )
                      : null,
                ),
                if (!isFileSource) ...[
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      videoDetailCtr.editPlayUrl();
                    },
                    leading: const Icon(
                      Icons.link,
                      size: 20,
                    ),
                    title: const Text('播放地址', style: titleStyle),
                  ),
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      videoDetailCtr.queryVideoUrl(fromReset: true);
                    },
                    leading: const Icon(Icons.refresh_outlined, size: 20),
                    title: const Text('重载视频', style: titleStyle),
                  ),
                ],
                PopupListTile<SuperResolutionType>(
                  dense: true,
                  leading: const Icon(
                    Icons.stay_current_landscape_outlined,
                    size: 20,
                  ),
                  title: const Text('超分辨率', style: titleStyle),
                  titleStyle: theme.textTheme.bodyLarge,
                  value: () {
                    final value = plPlayerController.superResolutionType.value;
                    return (value, value.label);
                  },
                  itemBuilder: (_) => enumItemBuilder(
                    SuperResolutionType.values,
                  ),
                  onSelected: (value, setState) {
                    plPlayerController.setShader(value);
                    setState();
                  },
                  descPosType: .subtitle,
                  descStyle: subTitleStyle,
                ),
                PopupListTile<VrProjection>(
                  dense: true,
                  leading: const Icon(Icons.vrpano_outlined, size: 20),
                  title: const Text('VR/全景', style: titleStyle),
                  titleStyle: theme.textTheme.bodyLarge,
                  value: () {
                    // 菜单绑定"请求"的布局: 可以是「自动(元数据)」;
                    // 实际生效的布局(auto 解析后)见 vrProjection
                    final value = plPlayerController.vrRequested.value;
                    return (value, value.label);
                  },
                  itemBuilder: (_) => enumItemBuilder(VrProjection.values),
                  onSelected: (value, setState) {
                    // VR 重投影在定制 libmpv 内完成, 选布局即生效,
                    // 弹幕/字幕/手势等播放器能力全部保留
                    plPlayerController.setVrProjection(value);
                    setState();
                  },
                  descPosType: .subtitle,
                  descStyle: subTitleStyle,
                ),
                if (plPlayerController.vrEnabled) ...[
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      plPlayerController.setVrControlMode(
                        !plPlayerController.vrControlMode.value,
                      );
                    },
                    leading: const Icon(Icons.gesture_outlined, size: 20),
                    title: const Text('VR 操作模式', style: titleStyle),
                    subtitle: Text(
                      plPlayerController.vrControlMode.value
                          ? '已接管手势：拖拽环视、双指缩放视场角'
                          : '未接管：拖拽仍是进退/音量，点击开启后再操作视角',
                      style: subTitleStyle,
                    ),
                  ),
                  Obx(
                    () => ListTile(
                      dense: true,
                      onTap: () => plPlayerController.setVrGyro(
                        !plPlayerController.vrGyroEnabled.value,
                      ),
                      leading: const Icon(
                        Icons.screen_rotation_outlined,
                        size: 20,
                      ),
                      title: const Text('陀螺仪视角', style: titleStyle),
                      subtitle: Text(
                        plPlayerController.vrGyroEnabled.value
                            ? '已开启：转动设备环视(头追在 mpv 内逐帧运行)'
                            : '未开启：开启后转动设备即可环视',
                        style: subTitleStyle,
                      ),
                      trailing: Icon(
                        plPlayerController.vrGyroEnabled.value
                            ? Icons.toggle_on
                            : Icons.toggle_off,
                        size: 32,
                        color: plPlayerController.vrGyroEnabled.value
                            ? theme.colorScheme.primary
                            : null,
                      ),
                    ),
                  ),
                  // 「立体分屏输出」(Cardboard) 已按 REQUIREMENTS.md 范围外
                  // 条款移除(第十五轮真机闪退)
                  if (plPlayerController.vrProjection.value.isStereo)
                    PopupListTile<VrEye>(
                      dense: true,
                      leading: const Icon(Icons.visibility_outlined, size: 20),
                      title: const Text('VR 眼位', style: titleStyle),
                      titleStyle: theme.textTheme.bodyLarge,
                      value: () {
                        final value = plPlayerController.vrEye.value;
                        return (value, value.label);
                      },
                      itemBuilder: (_) => enumItemBuilder(VrEye.values),
                      onSelected: (value, setState) {
                        plPlayerController.setVrEye(value);
                        setState();
                      },
                      descPosType: .subtitle,
                      descStyle: subTitleStyle,
                    ),
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      plPlayerController.resetVrView();
                      SmartDialog.showToast('视角已摆正，双指可缩放');
                    },
                    leading: const Icon(
                      Icons.center_focus_strong_outlined,
                      size: 20,
                    ),
                    title: const Text('VR 重置视角', style: titleStyle),
                  ),
                ],
                if (PlatformUtils.isMobile)
                  if (plPlayerController.videoPlayerController
                      case final player?)
                    Builder(
                      builder: (context) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.volume_up, size: 20),
                        title: const Text('播放器音量'),
                        subtitle: Text(
                          '当前: ${Pref.playerVolume.toStringAsFixed(0)}%',
                        ),
                        onTap: () => showPlayerVolumeDialog(
                          context,
                          () => (context as Element).markNeedsBuild(),
                          onChanged: player.setVolume,
                        ),
                      ),
                    ),
                if (!isFileSource)
                  ListTile(
                    dense: true,
                    title: const Text('CDN 设置', style: titleStyle),
                    leading: const Icon(MdiIcons.cloudPlusOutline, size: 20),
                    subtitle: Text(
                      '当前：${VideoUtils.cdnService.desc}，无法播放请切换',
                      style: subTitleStyle,
                    ),
                    onTap: () async {
                      Get.back();
                      final result = await showDialog<CDNService>(
                        context: context,
                        builder: (context) => CdnSelectDialog(
                          sample: videoInfo.dash?.video?.firstOrNull,
                        ),
                      );
                      if (result != null) {
                        VideoUtils.cdnService = result;
                        setting.put(SettingBoxKey.CDNService, result.name);
                        SmartDialog.showToast('已设置为 ${result.desc}，正在重载视频');
                        videoDetailCtr.queryVideoUrl(fromReset: true);
                      }
                    },
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    spacing: 10,
                    children: [
                      Obx(
                        () {
                          final flipX = plPlayerController.flipX.value;
                          return ActionRowLineItem(
                            iconData: Icons.flip,
                            onTap: () =>
                                plPlayerController.flipX.value = !flipX,
                            text: " 左右翻转 ",
                            selectStatus: flipX,
                          );
                        },
                      ),
                      Obx(
                        () {
                          final flipY = plPlayerController.flipY.value;
                          return ActionRowLineItem(
                            icon: Icon(
                              CustomIcons.flip_rotate_90,
                              size: 13,
                              color: flipY
                                  ? theme.colorScheme.onSecondaryContainer
                                  : theme.colorScheme.outline,
                            ),
                            onTap: () {
                              plPlayerController.flipY.value = !flipY;
                            },
                            text: " 上下翻转 ",
                            selectStatus: flipY,
                          );
                        },
                      ),
                      // "只听音频"只在视频/音频是两条独立流时才有意义:
                      // 离线缓存(dash, 非 mp4)或在线视频(有独立 audioUrl)。
                      // 必须按 dataSource 的**真实类型**判断, 不能用页面的
                      // isFileSource 去强转 —— 本地/局域网媒体的 dataSource 是
                      // NetworkSource(SMB 回环代理 / WebDAV / HTTP),
                      // 之前 `as FileSource` 在这里必崩(打开三点菜单就报
                      // type 'NetworkSource' is not a subtype of type 'FileSource')。
                      if (_canOnlyPlayAudio)
                        Obx(
                          () {
                            final onlyPlayAudio =
                                plPlayerController.onlyPlayAudio.value;
                            return ActionRowLineItem(
                              iconData: Icons.headphones,
                              onTap: () {
                                plPlayerController.onlyPlayAudio.value =
                                    !onlyPlayAudio;
                                final player =
                                    plPlayerController.videoPlayerController!;
                                if (onlyPlayAudio &&
                                    player.state.tracks.video.length <= 2) {
                                  videoDetailCtr.playerInit();
                                } else {
                                  player.setProperty(
                                    'file-local-options/vid',
                                    onlyPlayAudio ? 'auto' : 'no',
                                  );
                                }
                              },
                              text: " 听视频 ",
                              selectStatus: onlyPlayAudio,
                            );
                          },
                        ),
                      if (PlatformUtils.isMobile)
                        Obx(
                          () => ActionRowLineItem(
                            iconData: Icons.play_circle_outline,
                            onTap:
                                plPlayerController.setContinuePlayInBackground,
                            text: " 后台播放 ",
                            selectStatus: plPlayerController
                                .continuePlayInBackground
                                .value,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!isFileSource) ...[
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      showSetVideoQa();
                    },
                    leading: const Icon(Icons.play_circle_outline, size: 20),
                    title: const Text('选择画质', style: titleStyle),
                    subtitle: Text(
                      '当前画质 ${videoDetailCtr.currentVideoQa.value?.desc}',
                      style: subTitleStyle,
                    ),
                  ),
                  if (videoDetailCtr.currentAudioQa != null)
                    ListTile(
                      dense: true,
                      onTap: () {
                        Get.back();
                        showSetAudioQa();
                      },
                      leading: const Icon(Icons.album_outlined, size: 20),
                      title: const Text('选择音质', style: titleStyle),
                      subtitle: Text(
                        '当前音质 ${videoDetailCtr.currentAudioQa!.desc}',
                        style: subTitleStyle,
                      ),
                    ),
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      showSetDecodeFormats();
                    },
                    leading: const Icon(Icons.av_timer_outlined, size: 20),
                    title: const Text('解码格式', style: titleStyle),
                    subtitle: Text(
                      '当前解码格式 ${videoDetailCtr.currentDecodeFormats.description}',
                      style: subTitleStyle,
                    ),
                  ),
                ],
                PopupListTile(
                  dense: true,
                  leading: const Icon(Icons.repeat, size: 20),
                  title: const Text('播放顺序', style: titleStyle),
                  titleStyle: theme.textTheme.bodyLarge,
                  value: () {
                    final value = plPlayerController.playRepeat;
                    return (value, value.label);
                  },
                  itemBuilder: (_) => enumItemBuilder(PlayRepeat.values),
                  onSelected: (value, setState) {
                    plPlayerController.setPlayRepeat(value);
                    setState();
                  },
                  descPosType: .subtitle,
                  descStyle: subTitleStyle,
                ),
                // 本地/局域网视频没有弹幕源(B 站弹幕按 cid 拉取, 离线缓存才有
                // 同目录的 danmaku 文件), 相关入口一律不展示
                if (!isLocalMedia) ...[
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      showDanmakuPool();
                    },
                    leading: const Icon(CustomIcons.dm_on, size: 20),
                    title: const Text('弹幕列表', style: titleStyle),
                  ),
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      showSetDanmaku();
                    },
                    leading: const Icon(CustomIcons.dm_settings, size: 20),
                    title: const Text('弹幕设置', style: titleStyle),
                  ),
                ],
                // 字幕设置 / 加载字幕 已移到播放器顶栏的「字幕」按钮里
                // (与 VLC 一致: 字幕是一个独立入口, 里面能看到当前用的是哪条流)
                if (!videoDetailCtr.isFileSource &&
                    videoDetailCtr.subtitles.isNotEmpty)
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      onExportSubtitle();
                    },
                    leading: const Icon(Icons.download_outlined, size: 20),
                    title: const Text('保存字幕', style: titleStyle),
                  ),
                if (plPlayerController.videoPlayerController case final player?)
                  ListTile(
                    dense: true,
                    title: const Text('播放信息', style: titleStyle),
                    leading: const Icon(Icons.info_outline, size: 20),
                    onTap: () => showPlayerInfo(context, player: player),
                  ),
                // 举报需要 aid, 本地媒体没有(传 0 过去只会报错)
                if (!isLocalMedia)
                  ListTile(
                    dense: true,
                    onTap: () {
                      if (!Accounts.main.isLogin) {
                        SmartDialog.showToast('账号未登录');
                        return;
                      }
                      Get.back();
                      PageUtils.reportVideo(videoDetailCtr.aid);
                    },
                    leading: const Icon(Icons.error_outline, size: 20),
                    title: const Text('举报', style: titleStyle),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static void showPlayerInfo(
    BuildContext context, {
    required NativePlayer player,
  }) {
    final hwdec = player.getProperty('hwdec-current');
    final volume = player.getProperty('volume');
    showDialog(
      context: context,
      builder: (context) {
        final state = player.state;
        final colorScheme = ColorScheme.of(context);
        return AlertDialog(
          title: const Text('播放信息'),
          contentPadding: const EdgeInsets.only(top: 16),
          content: Material(
            type: MaterialType.transparency,
            child: ListTileTheme(
              contentPadding: const .symmetric(horizontal: 24),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ListTile(
                      dense: true,
                      title: const Text("Resolution"),
                      subtitle: Text('${state.width}x${state.height}'),
                      onTap: () => Utils.copyText(
                        'Resolution\n${state.width}x${state.height}',
                      ),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("VideoParams"),
                      subtitle: Text(state.videoParams.toString()),
                      onTap: () =>
                          Utils.copyText('VideoParams\n${state.videoParams}'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("AudioParams"),
                      subtitle: Text(state.audioParams.toString()),
                      onTap: () =>
                          Utils.copyText('AudioParams\n${state.audioParams}'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("Media"),
                      subtitle: Text(state.playlist.toString()),
                      onTap: () => Utils.copyText('Media\n${state.playlist}'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("AudioTrack"),
                      subtitle: Text(state.track.audio.toString()),
                      onTap: () =>
                          Utils.copyText('AudioTrack\n${state.track.audio}'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("VideoTrack"),
                      subtitle: Text(state.track.video.toString()),
                      onTap: () =>
                          Utils.copyText('VideoTrack\n${state.track.video}'),
                    ),
                    // 原来只列 video/audio, 内嵌字幕有没有被选上根本看不出来
                    ListTile(
                      dense: true,
                      title: const Text("SubtitleTrack"),
                      subtitle: Text(state.track.subtitle.toString()),
                      onTap: () => Utils.copyText(
                        'SubtitleTrack\n${state.track.subtitle}',
                      ),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("Tracks(可用轨道数)"),
                      subtitle: Text(
                        'video=${state.tracks.video.length} '
                        'audio=${state.tracks.audio.length} '
                        'subtitle=${state.tracks.subtitle.length}',
                      ),
                      onTap: () => Utils.copyText('Tracks\n${state.tracks}'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("rate"),
                      subtitle: Text(state.rate.toString()),
                      onTap: () => Utils.copyText('rate\n${state.rate}'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text("Volume"),
                      subtitle: Text(volume),
                      onTap: () => Utils.copyText('Volume\n$volume'),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text('hwdec'),
                      subtitle: Text(hwdec),
                      onTap: () => Utils.copyText('hwdec\n$hwdec'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: Get.back,
              child: Text(
                '确定',
                style: TextStyle(color: colorScheme.outline),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 选择画质
  void showSetVideoQa() {
    if (videoInfo.dash == null) {
      SmartDialog.showToast('当前视频不支持选择画质');
      return;
    }
    final VideoQuality? currentVideoQa = videoDetailCtr.currentVideoQa.value;
    if (currentVideoQa == null) return;

    final List<FormatItem> videoFormat = videoInfo.supportFormats!;
    final availableQa = videoInfo.dash!.video!.availableVideoQualities;

    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 45,
                    child: GestureDetector(
                      onTap: () => SmartDialog.showToast(
                        '标灰画质需要bilibili会员（已是会员？请关闭无痕模式）；4k和杜比视界播放效果可能不佳',
                      ),
                      child: Row(
                        spacing: 8,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('选择画质', style: titleStyle),
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: theme.colorScheme.outline,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: videoFormat.length,
                  itemBuilder: (context, index) {
                    final item = videoFormat[index];
                    final isCurr = currentVideoQa.code == item.quality;
                    return ListTile(
                      dense: true,
                      onTap: () async {
                        if (isCurr) {
                          return;
                        }
                        Get.back();
                        final int quality = item.quality!;
                        final newQa = VideoQuality.fromCode(quality);
                        videoDetailCtr
                          ..plPlayerController.cacheVideoQa = newQa.code
                          ..currentVideoQa.value = newQa
                          ..updatePlayer();

                        SmartDialog.showToast("画质已变为：${newQa.desc}");

                        // update
                        if (!plPlayerController.tempPlayerConf) {
                          setting.put(
                            await ConnectivityUtils.isWiFi
                                ? SettingBoxKey.defaultVideoQa
                                : SettingBoxKey.defaultVideoQaCellular,
                            quality,
                          );
                        }
                      },
                      // 可能包含会员解锁画质
                      enabled: availableQa.contains(item.quality),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      title: Text(item.newDesc!),
                      trailing: isCurr
                          ? Icon(
                              Icons.done,
                              color: theme.colorScheme.primary,
                            )
                          : Text(
                              item.format!,
                              style: subTitleStyle,
                            ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 选择音质
  void showSetAudioQa() {
    final AudioQuality currentAudioQa = videoDetailCtr.currentAudioQa!;
    final List<AudioItem> audio = videoInfo.dash!.audio!;
    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: SizedBox(
                    height: 45,
                    child: Center(
                      child: Text('选择音质', style: titleStyle),
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: audio.length,
                  itemBuilder: (context, index) {
                    final item = audio[index];
                    final isCurr = currentAudioQa.code == item.id;
                    return ListTile(
                      dense: true,
                      onTap: () async {
                        if (isCurr) {
                          return;
                        }
                        Get.back();
                        final int quality = item.id;
                        final newQa = AudioQuality.fromCode(quality);
                        videoDetailCtr
                          ..plPlayerController.cacheAudioQa = newQa.code
                          ..currentAudioQa = newQa
                          ..updatePlayer();

                        SmartDialog.showToast("音质已变为：${newQa.desc}");

                        // update
                        if (!plPlayerController.tempPlayerConf) {
                          setting.put(
                            await ConnectivityUtils.isWiFi
                                ? SettingBoxKey.defaultAudioQa
                                : SettingBoxKey.defaultAudioQaCellular,
                            quality,
                          );
                        }
                      },
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      title: Text(item.quality),
                      subtitle: Text(
                        item.codecs!,
                        style: subTitleStyle,
                      ),
                      trailing: isCurr
                          ? Icon(
                              Icons.done,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 选择解码格式
  void showSetDecodeFormats() {
    final firstCode = videoDetailCtr.firstVideo.quality.code;
    // 当前视频可用的解码格式
    final videoFormat = videoInfo.supportFormats!;

    final list = videoFormat.firstWhere((e) => e.quality == firstCode).codecs;
    if (list == null) {
      SmartDialog.showToast('当前视频不支持选择解码格式');
      return;
    }

    // 当前选中的解码格式
    final curCodecs = videoDetailCtr.currentDecodeFormats.codes;
    showBottomSheet(
      (context, setState) {
        final colorScheme = ColorScheme.of(context);
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Column(
              children: [
                const SizedBox(
                  height: 45,
                  child: Center(
                    child: Text('选择解码格式', style: titleStyle),
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverList.builder(
                        itemCount: list.length,
                        itemBuilder: (context, index) {
                          final item = list[index];
                          final format = VideoDecodeFormatType.fromString(item);
                          final isCurr = curCodecs.any(item.startsWith);
                          return ListTile(
                            dense: true,
                            onTap: () {
                              if (isCurr) return;
                              Get.back();
                              videoDetailCtr
                                ..currentDecodeFormats = format
                                ..updatePlayer();
                              SmartDialog.showToast("解码已变为：${format.name}");
                            },
                            contentPadding: const .symmetric(horizontal: 20),
                            title: Text(format.description),
                            subtitle: Text(item, style: subTitleStyle),
                            trailing: isCurr
                                ? Icon(Icons.done, color: colorScheme.primary)
                                : null,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void onExportSubtitle() {
    showDialog(
      context: context,
      builder: (context) {
        SubtitleFormat format = .vtt;
        final subtitles = videoDetailCtr.subtitles;
        final secondary = ColorScheme.of(context).secondary;
        return SimpleDialog(
          clipBehavior: .hardEdge,
          contentPadding: const .only(bottom: 12),
          titlePadding: const .fromLTRB(20, 20, 20, 12),
          title: Row(
            children: [
              const Expanded(child: Text('保存字幕')),
              const Text('格式: ', style: TextStyle(fontSize: 14)),
              Builder(
                builder: (context) => PopupMenuButton<SubtitleFormat>(
                  tooltip: '',
                  initialValue: format,
                  onSelected: (value) {
                    format = value;
                    (context as Element).markNeedsBuild();
                  },
                  itemBuilder: (_) => SubtitleFormat.values
                      .map(
                        (e) => PopupMenuItem(
                          value: e,
                          height: 35,
                          child: Text(e.label),
                        ),
                      )
                      .toList(),
                  child: Padding(
                    padding: const .symmetric(horizontal: 2, vertical: 5),
                    child: Text.rich(
                      style: .new(fontSize: 14, color: secondary),
                      TextSpan(
                        children: [
                          TextSpan(text: format.label),
                          WidgetSpan(
                            alignment: .middle,
                            child: Icon(
                              size: 14,
                              MdiIcons.unfoldMoreHorizontal,
                              color: secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          children: List.generate(subtitles.length, (i) {
            final item = subtitles[i];
            return DialogOption(
              onPressed: () async {
                Get.back();
                final url = item.subtitleUrl;
                if (url == null || url.isEmpty) return;
                try {
                  final Uint8List bytes;
                  switch (format) {
                    case .vtt || .srt:
                      var subtitle = format == .vtt
                          ? videoDetailCtr.vttSubtitles[i]?.id
                          : null;
                      if (subtitle == null) {
                        final res = await VideoHttp.getSubtitles(
                          item.subtitleUrl!,
                          format: format,
                        );
                        if (res == null) return;
                        subtitle = res;
                        if (format == .vtt) {
                          videoDetailCtr.vttSubtitles[i] = (
                            isData: true,
                            id: res,
                          );
                        }
                      }
                      bytes = utf8.encode(subtitle);
                    case .json:
                      final res = await Request.dio.get<Uint8List>(
                        url.http2https,
                        options: Options(
                          responseType: .bytes,
                          headers: Constants.baseHeaders,
                          extra: {'account': const NoAccount()},
                        ),
                      );
                      if (res.statusCode != 200) return;
                      bytes = Uint8List.fromList(
                        Request.responseBytesDecoder(
                          res.data!,
                          res.headers.map,
                        ),
                      );
                  }
                  final videoDetail = introController.videoDetail.value;
                  final name =
                      '${videoDetail.title}-${videoDetail.owner?.name}(${videoDetail.owner?.mid})-${videoDetailCtr.bvid}-${videoDetailCtr.cid.value}-${item.lanDoc}.${format.name}'
                          .replaceAll(
                            Platform.isWindows ? RegExp(r'[<>:/\\|?*"]') : '/',
                            '_',
                          );
                  // Reserved characters may not be used in file names. See: https://docs.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions
                  StorageUtils.saveBytes2File(
                    name: name,
                    bytes: bytes,
                    allowedExtensions: [format.name],
                  );
                } catch (e, s) {
                  Utils.reportError(e, s);
                  SmartDialog.showToast(e.toString());
                }
              },
              child: Text(item.lanDoc ?? item.lan),
            );
          }),
        );
      },
    );
  }

  double get subtitleFontScale => plPlayerController.subtitleFontScale;
  double get subtitleFontScaleFS => plPlayerController.subtitleFontScaleFS;
  int get subtitlePaddingH => plPlayerController.subtitlePaddingH;
  int get subtitlePaddingB => plPlayerController.subtitlePaddingB;
  double get subtitleBgOpacity => plPlayerController.subtitleBgOpacity;
  double get subtitleStrokeWidth => plPlayerController.subtitleStrokeWidth;
  int get subtitleFontWeight => plPlayerController.subtitleFontWeight;

  /// 字幕设置
  /// 字幕面板(顶栏「字幕」按钮)。
  ///
  /// 三合一: **当前正在用的字幕流** + 可选轨道(B 站字幕 / mpv 内嵌轨道) +
  /// 加载外挂字幕 + 字幕设置。参照 VLC 的字幕菜单。
  ///
  /// 为什么要单独立一个入口: 内嵌字幕以前完全没有暴露给用户
  /// (底栏那个字幕按钮只在有 B 站字幕时才出现), 而且本地视频启动时会
  /// `setSubtitleTrack(no)` 把内嵌字幕一起关掉 —— 于是"有内嵌字幕却看不到"。
  void showSubtitlePanel() {
    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Obx(
              () {
                final biliSubs = videoDetailCtr.subtitles;
                final vttIndex = videoDetailCtr.vttSubtitlesIndex.value;
                final inner = plPlayerController.internalSubtitleTracks;
                final audios = plPlayerController.internalAudioTracks;
                final current = plPlayerController.currentTrack.value;
                final currentSubId = current.subtitle.id;
                final currentAudioId = current.audio.id;
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  children: [
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.subtitles_outlined, size: 20),
                      title: const Text('字幕', style: titleStyle),
                      subtitle: Text(
                        '当前: ${_currentSubtitleLabel(
                          biliSubs,
                          vttIndex,
                          inner,
                          currentSubId,
                        )}',
                        style: subTitleStyle,
                      ),
                    ),
                    if (biliSubs.isNotEmpty) ...[
                      // 本地视频这里是"自动匹配到的同目录外置字幕"和手动加载的
                      _sectionTitle(context, isLocalMedia ? '字幕文件' : 'B 站字幕'),
                      if (!isLocalMedia)
                        _trackTile(
                          context,
                          label: '关闭',
                          selected: vttIndex <= 0,
                          onTap: () {
                            Get.back();
                            videoDetailCtr.setSubtitle(0);
                          },
                        ),
                      for (var i = 0; i < biliSubs.length; i++)
                        _trackTile(
                          context,
                          label: biliSubs[i].lanDoc ?? biliSubs[i].lan,
                          selected: vttIndex == i + 1,
                          onTap: () {
                            Get.back();
                            videoDetailCtr.setSubtitle(i + 1);
                          },
                        ),
                    ],
                    if (inner.isNotEmpty) ...[
                      _sectionTitle(context, '内嵌字幕轨道'),
                      _trackTile(
                        context,
                        label: '自动',
                        selected: currentSubId == 'auto',
                        onTap: () {
                          Get.back();
                          plPlayerController.setInternalSubtitleTrack(
                            SubtitleTrack.auto(),
                          );
                        },
                      ),
                      _trackTile(
                        context,
                        label: '关闭',
                        selected: currentSubId == 'no',
                        onTap: () {
                          Get.back();
                          plPlayerController.setInternalSubtitleTrack(
                            SubtitleTrack.no(),
                          );
                        },
                      ),
                      for (final t in inner)
                        _trackTile(
                          context,
                          label: PlPlayerController.trackLabel(
                            id: t.id,
                            title: t.title,
                            language: t.language,
                            codec: t.codec,
                          ),
                          selected: currentSubId == t.id,
                          onTap: () {
                            Get.back();
                            plPlayerController.setInternalSubtitleTrack(
                              SubtitleTrack(t.id, t.title, t.language),
                            );
                          },
                        ),
                    ],
                    // 多音轨的本地片源很常见(国配/原声), 顺手一起给出来
                    if (audios.length > 1) ...[
                      _sectionTitle(context, '音轨'),
                      for (final t in audios)
                        _trackTile(
                          context,
                          label: PlPlayerController.trackLabel(
                            id: t.id,
                            title: t.title,
                            language: t.language,
                            codec: t.codec,
                          ),
                          selected: currentAudioId == t.id,
                          onTap: () {
                            Get.back();
                            plPlayerController.setInternalAudioTrack(
                              AudioTrack(t.id, t.title, t.language),
                            );
                          },
                        ),
                    ],
                    if (biliSubs.isEmpty && inner.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: Text(
                          '这个视频没有字幕轨，可以在下面手动加载外挂字幕',
                          style: subTitleStyle.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const Divider(height: 20),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.file_open_outlined, size: 20),
                      title: const Text('加载字幕…', style: titleStyle),
                      subtitle: const Text(
                        'srt / ass / vtt / json / bcc',
                        style: subTitleStyle,
                      ),
                      onTap: () {
                        Get.back();
                        loadExternalSubtitle();
                      },
                    ),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.tune, size: 20),
                      title: const Text('字幕设置', style: titleStyle),
                      subtitle: Text(
                        '字号 / 颜色 / 描边 / 位置 / 延迟',
                        style: subTitleStyle.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () {
                        Get.back();
                        showSetSubtitle();
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
    child: Text(
      text,
      style: subTitleStyle.copyWith(
        color: ColorScheme.of(context).primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _trackTile(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colorScheme = ColorScheme.of(context);
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 18,
        color: selected ? colorScheme.primary : colorScheme.outline,
      ),
      title: Text(
        label,
        style: titleStyle.copyWith(
          color: selected ? colorScheme.primary : null,
        ),
      ),
    );
  }

  /// 当前字幕流的展示名: B 站字幕优先(它是显式选出来的), 其次看 mpv 实际选中的轨
  String _currentSubtitleLabel(
    List<Subtitle> biliSubs,
    int vttIndex,
    List<SubtitleTrack> inner,
    String currentSubId,
  ) {
    if (vttIndex > 0 && vttIndex <= biliSubs.length) {
      final s = biliSubs[vttIndex - 1];
      return '${s.lanDoc ?? s.lan}(外挂)';
    }
    if (currentSubId == 'no') {
      return '关闭';
    }
    if (currentSubId == 'auto') {
      return inner.isEmpty ? '自动(无可用轨道)' : '自动';
    }
    for (final t in inner) {
      if (t.id == currentSubId) {
        return PlPlayerController.trackLabel(
          id: t.id,
          title: t.title,
          language: t.language,
          codec: t.codec,
        );
      }
    }
    return currentSubId.isEmpty ? '无' : currentSubId;
  }

  /// 加载外挂字幕(原来挂在三点菜单里, 现在从字幕面板进)。
  /// 逻辑与原菜单项一致: json/bcc 转成 vtt 数据内联加载, 其它按文件路径加载。
  Future<void> loadExternalSubtitle() async {
    try {
      final result = await FilePicker.pickFile(
        type: .custom,
        allowedExtensions: const ['json', 'vtt', 'srt', 'ass', 'bcc'],
      );
      if (result == null) {
        return;
      }
      final file = result.xFile;
      final path = file.path;
      final name = file.name;
      final length = videoDetailCtr.subtitles.length;
      if (name.endsWith('.json') || name.endsWith('.bcc')) {
        final stream = File(path).openRead().transform(utf8.decoder);
        final buffer = StringBuffer();
        await for (final chunk in stream) {
          if (!mounted) return;
          buffer.write(chunk);
        }
        if (!mounted) return;
        String sub = buffer.toString();
        sub = await compute<List, String>(
          SubtitleUtils.json2Vtt,
          jsonDecode(sub)['body'],
        );
        if (!mounted) return;
        videoDetailCtr.vttSubtitles[length] = (isData: true, id: sub);
      } else {
        videoDetailCtr.vttSubtitles[length] = (isData: false, id: path);
      }
      videoDetailCtr.subtitles.add(
        Subtitle(lan: '', lanDoc: name.split('.').firstOrNull ?? name),
      );
      await videoDetailCtr.setSubtitle(length + 1);
    } catch (e) {
      SmartDialog.showToast('加载失败: $e');
    }
  }

  void showSetSubtitle() {
    showBottomSheet(
      padding: () => isFullScreen ? const .only(bottom: 70) : .zero,
      (context, setState) {
        final theme = Theme.of(context);

        const EdgeInsets sliderPadding = .symmetric(vertical: 16);

        final sliderTheme = SliderThemeData(
          trackHeight: 10,
          padding: const .symmetric(horizontal: 6),
          trackShape: const MSliderTrackShape(),
          thumbColor: theme.colorScheme.primary,
          activeTrackColor: theme.colorScheme.primary,
          inactiveTrackColor: theme.colorScheme.onInverseSurface,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
        );

        void updateStrokeWidth(double val) {
          plPlayerController
            ..subtitleStrokeWidth = val
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateOpacity(double val) {
          plPlayerController
            ..subtitleBgOpacity = val.toPrecision(2)
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateBottomPadding(double val) {
          plPlayerController
            ..subtitlePaddingB = val.round()
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateHorizontalPadding(double val) {
          plPlayerController
            ..subtitlePaddingH = val.round()
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateFontScaleFS(double val) {
          plPlayerController
            ..subtitleFontScaleFS = val.toPrecision(2)
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateFontScale(double val) {
          plPlayerController
            ..subtitleFontScale = val.toPrecision(2)
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateFontWeight(double val) {
          plPlayerController
            ..subtitleFontWeight = val.toInt()
            ..updateSubtitleStyle();
          setState(() {});
        }

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SliderTheme(
                data: sliderTheme,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(
                      height: 45,
                      child: Center(child: Text('字幕设置', style: titleStyle)),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体大小 ${(subtitleFontScale * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '100.0%', () => updateFontScale(1.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: subtitleFontScale,
                        divisions: 200,
                        label:
                            '${(subtitleFontScale * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontScale,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '全屏字体大小 ${(subtitleFontScaleFS * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '150.0%', () => updateFontScaleFS(1.5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: subtitleFontScaleFS,
                        divisions: 200,
                        label:
                            '${(subtitleFontScaleFS * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontScaleFS,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('字体粗细 ${subtitleFontWeight + 1}（可能无法精确调节）'),
                        resetBtn(theme, 6, () => updateFontWeight(5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 8,
                        value: subtitleFontWeight.toDouble(),
                        divisions: 8,
                        label: '${subtitleFontWeight + 1}',
                        onChanged: updateFontWeight,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('描边粗细 $subtitleStrokeWidth'),
                        resetBtn(theme, 2.0, () => updateStrokeWidth(2.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 5,
                        value: subtitleStrokeWidth,
                        divisions: 10,
                        label: '$subtitleStrokeWidth',
                        onChanged: updateStrokeWidth,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('左右边距 $subtitlePaddingH'),
                        resetBtn(theme, 24, () => updateHorizontalPadding(24)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 100,
                        value: subtitlePaddingH.toDouble(),
                        divisions: 100,
                        label: '$subtitlePaddingH',
                        onChanged: updateHorizontalPadding,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('底部边距 $subtitlePaddingB'),
                        resetBtn(theme, 24, () => updateBottomPadding(24)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 200,
                        value: subtitlePaddingB.toDouble(),
                        divisions: 200,
                        label: '$subtitlePaddingB',
                        onChanged: updateBottomPadding,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '背景不透明度 ${(subtitleBgOpacity * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '67%', () => updateOpacity(0.67)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 1,
                        divisions: 100,
                        value: subtitleBgOpacity,
                        onChanged: updateOpacity,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    )?.whenComplete(plPlayerController.putSubtitleSettings);
  }

  void showDanmakuPool() {
    final ctr = plPlayerController.danmakuController;
    if (ctr == null) return;
    showBottomSheet((context, setState) {
      final theme = Theme.of(context);
      return Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Column(
          children: [
            Container(
              height: 45,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('弹幕列表'),
                  iconButton(
                    onPressed: () => setState(() {}),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Material(
                type: .transparency,
                clipBehavior: .hardEdge,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
                child: CustomScrollView(
                  slivers: [
                    ?_buildDanmakuList(ctr.staticDanmaku.nonNulls.toList()),
                    ?_buildDanmakuList(
                      ctr.scrollDanmaku.expand((e) => e).toList(),
                    ),
                    ?_buildDanmakuList(ctr.specialDanmaku.toList()),
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget? _buildDanmakuList(List<DanmakuItem<DanmakuExtra>> list) {
    if (list.isEmpty) return null;

    return SliverList.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        final extra = item.content.extra! as VideoDanmaku;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          onLongPress: () => Utils.copyText(item.content.text),
          title: Text(
            item.content.text,
            style: const TextStyle(fontSize: 14),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Builder(
                builder: (context) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    iconButton(
                      onPressed: () async {
                        if (await HeaderControl.likeDanmaku(
                              extra,
                              plPlayerController.cid!,
                            ) &&
                            context.mounted) {
                          (context as Element).markNeedsBuild();
                        }
                      },
                      icon: extra.isLike
                          ? const Icon(CustomIcons.player_dm_tip_like_solid)
                          : const Icon(CustomIcons.player_dm_tip_like),
                    ),
                    if (extra.like > 0)
                      Positioned(
                        left: 24.5,
                        top: 1.5,
                        child: Text(
                          extra.like.toString(),
                          style: const TextStyle(
                            fontSize: 10.5,
                            letterSpacing: 0,
                            // fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (item.content.selfSend)
                iconButton(
                  onPressed: () => HeaderControl.deleteDanmaku(
                    extra.id,
                    plPlayerController.cid!,
                  ).then((_) => item.expired = true),
                  icon: const Icon(CustomIcons.player_dm_tip_recall),
                )
              else
                iconButton(
                  onPressed: () => HeaderControl.reportDanmaku(
                    context,
                    extra: extra,
                    ctr: plPlayerController,
                  ),
                  icon: const Icon(CustomIcons.player_dm_tip_back),
                ),
            ],
          ),
        );
      },
    );
  }

  late final isFileSource = videoDetailCtr.isFileSource;

  /// 「本地」板块的媒体(本机/局域网)。
  ///
  /// 它和离线缓存共用 `isFileSource`(离线语义), 但**不是 B 站内容**, 因此
  /// 一批只对 B 站视频有意义的入口要单独按它关掉: 弹幕(没有弹幕源)、
  /// 稍后再看/笔记/举报(全是 B 站接口)。
  late final isLocalMedia = videoDetailCtr.isLocalMedia;

  /// 「只听音频」是否可用: 只有视频与音频是**两条独立流**时才有意义。
  ///
  /// 这里以前写的是 `isFileSource && !(dataSource as FileSource).isMp4`,
  /// 而本地/局域网媒体的 dataSource 是 [NetworkSource](SMB 回环代理 /
  /// WebDAV / HTTP), 页面的 `isFileSource` 却是 true —— 一强转就崩
  /// (打开三点菜单必现)。改成先判类型再用, 不做任何强转。
  bool get _canOnlyPlayAudio {
    if (isFileSource) {
      final dataSource = plPlayerController.dataSource;
      // 离线缓存的 dash(非 mp4)才是双流; 本机文件是单文件, 没有独立音轨
      return dataSource is FileSource && !dataSource.isMp4;
    }
    return videoDetailCtr.audioUrl?.isNotEmpty == true;
  }

  @override
  Widget build(BuildContext context) {
    final isFullScreen = this.isFullScreen;
    final isFSOrPip = isFullScreen || plPlayerController.isDesktopPip;
    final showFSActionItem =
        !isFileSource && plPlayerController.showFSActionItem && isFSOrPip;
    showCurrTimeIfNeeded(isFullScreen);
    Widget title;
    if (introController.videoDetail.value.title != null &&
        (isFullScreen ||
            ((!horizontalScreen || plPlayerController.isDesktopPip) &&
                !isPortrait))) {
      title = Padding(
        key: titleKey,
        padding: isPortrait
            ? EdgeInsets.zero
            : const EdgeInsets.only(right: 10),
        child: Obx(
          () {
            final videoDetail = introController.videoDetail.value;
            final String title;
            if (isFileSource || videoDetail.videos == 1) {
              title = videoDetail.title!;
            } else {
              title =
                  videoDetail.pages
                      ?.firstWhereOrNull(
                        (e) => e.cid == videoDetailCtr.cid.value,
                      )
                      ?.part ??
                  videoDetail.title!;
            }
            return MarqueeText(
              title,
              spacing: 30,
              velocity: 30,
              strutStyle: const StrutStyle(fontSize: 16, leading: 0),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              provider: effectiveProvider,
            );
          },
        ),
      );
      if (introController.isShowOnlineTotal) {
        title = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            Obx(
              () => Text(
                '${introController.total.value}人正在看',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        );
      }
      title = Expanded(child: title);
    } else {
      title = const Spacer();
    }

    const btnWidth = 42.0;
    const btnHeight = 34.0;
    const btnStyle = ButtonStyle(padding: WidgetStatePropertyAll(.zero));

    return Padding(
      padding: const .symmetric(vertical: 12),
      child: Column(
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              SizedBox(
                width: btnWidth,
                height: btnHeight,
                child: IconButton(
                  tooltip: '返回',
                  style: btnStyle,
                  icon: const Icon(
                    FontAwesomeIcons.arrowLeft,
                    size: 15,
                    color: Colors.white,
                  ),
                  onPressed: () =>
                      plPlayerController.onPopInvokedWithResult(false, null),
                ),
              ),
              if (!plPlayerController.isDesktopPip &&
                  (!isFullScreen || !isPortrait))
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: IconButton(
                    tooltip: '返回主页',
                    style: btnStyle,
                    icon: const Icon(
                      FontAwesomeIcons.house,
                      size: 15,
                      color: Colors.white,
                    ),
                    onPressed: plPlayerController.onCloseAll,
                  ),
                ),
              title,
              // show current datetime
              ...?timeBatteryWidgets,
              if (!isFileSource) ...[
                if (!isFSOrPip) ...[
                  if (videoDetailCtr.isUgc)
                    SizedBox(
                      width: btnWidth,
                      height: btnHeight,
                      child: IconButton(
                        tooltip: '听音频',
                        style: btnStyle,
                        onPressed: videoDetailCtr.toAudioPage,
                        icon: const Icon(
                          Icons.headphones_outlined,
                          size: 19,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: btnWidth,
                    height: btnHeight,
                    child: IconButton(
                      tooltip: '投屏',
                      style: btnStyle,
                      onPressed: videoDetailCtr.onCast,
                      icon: const Icon(
                        Icons.cast,
                        size: 19,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
                if (kDebugMode || plPlayerController.enableSponsorBlock)
                  SizedBox(
                    width: btnWidth,
                    height: btnHeight,
                    child: IconButton(
                      tooltip: '提交片段',
                      style: btnStyle,
                      onPressed: () => videoDetailCtr.onBlock(context),
                      icon: const Icon(
                        CustomIcons.shield_play_arrow,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                Obx(
                  () => videoDetailCtr.segmentProgressList.isNotEmpty
                      ? SizedBox(
                          width: btnWidth,
                          height: btnHeight,
                          child: IconButton(
                            tooltip: '片段信息',
                            style: btnStyle,
                            onPressed: videoDetailCtr.showSBDetail,
                            icon: const Icon(
                              MdiIcons.advertisements,
                              size: 19,
                              color: Colors.white,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
              if (!isLocalMedia &&
                  (!isPortrait || isFullScreen || PlatformUtils.isDesktop)) ...[
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: IconButton(
                    tooltip: '发弹幕',
                    style: btnStyle,
                    onPressed: videoDetailCtr.showShootDanmakuSheet,
                    icon: const Icon(
                      Icons.comment_outlined,
                      size: 19,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: Obx(
                    () {
                      final enableShowDanmaku =
                          plPlayerController.enableShowDanmaku.value;
                      return IconButton(
                        tooltip: "${enableShowDanmaku ? '关闭' : '开启'}弹幕",
                        style: btnStyle,
                        onPressed: () {
                          final newVal = !enableShowDanmaku;
                          plPlayerController.enableShowDanmaku.value = newVal;
                          if (!plPlayerController.tempPlayerConf) {
                            setting.put(
                              SettingBoxKey.enableShowDanmaku,
                              newVal,
                            );
                          }
                        },
                        icon: enableShowDanmaku
                            ? const Icon(
                                size: 20,
                                CustomIcons.dm_on,
                                color: Colors.white,
                              )
                            : const Icon(
                                size: 20,
                                CustomIcons.dm_off,
                                color: Colors.white,
                              ),
                      );
                    },
                  ),
                ),
              ],
              if (!isLocalMedia)
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: IconButton(
                    tooltip: '弹幕设置',
                    style: btnStyle,
                    onPressed: showSetDanmaku,
                    icon: const Icon(
                      size: 20,
                      CustomIcons.dm_settings,
                      color: Colors.white,
                    ),
                  ),
                ),
              // 字幕: 从三点菜单提到顶栏, 面板里能看到当前用的是哪条流
              SizedBox(
                width: btnWidth,
                height: btnHeight,
                child: IconButton(
                  tooltip: '字幕',
                  style: btnStyle,
                  onPressed: showSubtitlePanel,
                  icon: const Icon(
                    Icons.subtitles_outlined,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
              ),
              if (Platform.isAndroid ||
                  (PlatformUtils.isDesktop && !isFullScreen))
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: IconButton(
                    // 第二十轮 需求2: 点按 = **系统**画中画。画面交给独立的
                    // PipActivity(moonlight-android 的同款结构), 主 Activity
                    // 留在原任务里, 所以 PiP 期间照样能逛应用; 播放器不重建,
                    // 不重新拉流。长按 = 应用内浮窗(不依赖系统 PiP 的备选)。
                    tooltip: '系统画中画(可继续浏览应用)\n长按: 应用内小窗',
                    style: btnStyle,
                    onPressed: () => unawaited(enterPip(context)),
                    onLongPress: () => enterInAppPip(context),
                    icon: const Icon(
                      Icons.picture_in_picture_outlined,
                      size: 19,
                      color: Colors.white,
                    ),
                  ),
                ),
              SizedBox(
                width: btnWidth,
                height: btnHeight,
                child: IconButton(
                  tooltip: "更多设置",
                  style: btnStyle,
                  onPressed: showSettingSheet,
                  icon: const Icon(
                    Icons.more_vert_outlined,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (showFSActionItem)
            Row(
              mainAxisAlignment: .end,
              crossAxisAlignment: .start,
              children: [
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: Obx(
                    () => ActionItem(
                      expand: false,
                      icon: const Icon(
                        FontAwesomeIcons.thumbsUp,
                        color: Colors.white,
                      ),
                      selectIcon: const Icon(FontAwesomeIcons.solidThumbsUp),
                      selectStatus: introController.hasLike.value,
                      semanticsLabel: '点赞',
                      animation: introController.tripleAnimation,
                      onStartTriple: () {
                        plPlayerController.tripling = true;
                        introController.onStartTriple();
                      },
                      onCancelTriple: ([bool isTapUp = false]) {
                        plPlayerController
                          ..tripling = false
                          ..hideTaskControls();
                        introController.onCancelTriple(isTapUp);
                      },
                    ),
                  ),
                ),
                if (introController case final UgcIntroController ugc)
                  SizedBox(
                    width: btnWidth,
                    height: btnHeight,
                    child: Obx(
                      () => ActionItem(
                        expand: false,
                        icon: const Icon(
                          FontAwesomeIcons.thumbsDown,
                          color: Colors.white,
                        ),
                        selectIcon: const Icon(
                          FontAwesomeIcons.solidThumbsDown,
                        ),
                        onTap: () => ugc.handleAction(ugc.actionDislikeVideo),
                        selectStatus: ugc.hasDislike.value,
                        semanticsLabel: '点踩',
                      ),
                    ),
                  ),
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: Obx(
                    () => ActionItem(
                      expand: false,
                      animation: introController.tripleAnimation,
                      icon: const Icon(
                        FontAwesomeIcons.b,
                        color: Colors.white,
                      ),
                      selectIcon: const Icon(FontAwesomeIcons.b),
                      onTap: introController.actionCoinVideo,
                      selectStatus: introController.hasCoin,
                      semanticsLabel: '投币',
                    ),
                  ),
                ),
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: Obx(
                    () => ActionItem(
                      expand: false,
                      animation: introController.tripleAnimation,
                      icon: const Icon(
                        FontAwesomeIcons.star,
                        color: Colors.white,
                      ),
                      selectIcon: const Icon(FontAwesomeIcons.solidStar),
                      onTap: () => introController.showFavBottomSheet(context),
                      onLongPress: () => introController.showFavBottomSheet(
                        context,
                        isLongPress: true,
                      ),
                      selectStatus: introController.hasFav.value,
                      semanticsLabel: '收藏',
                    ),
                  ),
                ),
                SizedBox(
                  width: btnWidth,
                  height: btnHeight,
                  child: ActionItem(
                    expand: false,
                    icon: const Icon(
                      FontAwesomeIcons.shareFromSquare,
                      color: Colors.white,
                    ),
                    onTap: () => introController.actionShareVideo(context),
                    semanticsLabel: '分享',
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
