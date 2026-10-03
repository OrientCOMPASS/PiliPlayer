import 'dart:async' show unawaited;
import 'dart:math' show max;

import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/models_new/video/video_detail/stat_detail.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:get/get.dart';

/// 本地/局域网媒体的简介面板控制器。
///
/// 只负责「同目录播放列表」与上一个/下一个, 不请求任何 B 站接口:
/// 点赞、投币、收藏、分享、同时在看人数等一律为空实现。
class LocalMediaIntroController extends CommonIntroController {
  @override
  void queryVideoIntro() {}

  @override
  int get copyright => throw UnimplementedError();

  @override
  void actionLikeVideo() {}

  @override
  void actionShareVideo(context) {}

  @override
  void actionTriple() {}

  @override
  Future<void> actionFavVideo({bool isQuick = false}) async {}

  @override
  (Object, int) get getFavRidType => throw UnimplementedError();

  @override
  StatDetail? getStat() => null;

  @override
  bool get isShowOnlineTotal => false;

  /// 同目录的播放列表
  final RxList<LocalMediaItem> list = <LocalMediaItem>[].obs;

  final RxInt index = (-1).obs;

  /// 播放列表表头的快速检索关键词(第十九轮新增)。
  ///
  /// 只过滤**展示**, 不改变 [list] 本身: 上一个/下一个、列表循环、随机播放
  /// 依旧走完整列表, 检索只是"在几十上百个文件里快速定位那一个"。
  final RxString query = ''.obs;

  /// 过滤后仍然展示的条目在 [list] 中的下标(关键词为空 = 全量、原序)
  List<int> get visibleIndices {
    final keyword = query.value.trim().toLowerCase();
    if (keyword.isEmpty) {
      return [for (var i = 0; i < list.length; i++) i];
    }
    return [
      for (var i = 0; i < list.length; i++)
        if (list[i].name.toLowerCase().contains(keyword)) i,
    ];
  }

  /// 正在播的条目在**过滤后**列表里的位置; 被过滤掉时返回 -1
  int get visibleIndexOfCurrent => visibleIndices.indexOf(index.value);

  void setQuery(String value) => query.value = value;

  void clearQuery() => query.value = '';

  @override
  void onInit() {
    super.onInit();
    final args = videoDetailCtr.args;
    videoDetail.value.title = args['title'] ?? '';
    final playlist = args['localPlaylist'];
    list.value = playlist is List
        ? playlist.whereType<LocalMediaItem>().toList()
        : <LocalMediaItem>[videoDetailCtr.localItem];
    if (list.isEmpty) {
      list.add(videoDetailCtr.localItem);
    }
    final requested = args['localIndex'];
    final byUri = list.indexWhere((e) => e.uri == videoDetailCtr.localItem.uri);
    index.value = requested is int && requested >= 0 && requested < list.length
        ? requested
        : max(0, byUri);
    if (PlatformUtils.isMobile) {
      onVideoDetailChange(list[index.value.clamp(0, list.length - 1)]);
    }
  }

  @override
  void onClose() {
    videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
    super.onClose();
  }

  @override
  bool nextPlay() {
    final playCtr = videoDetailCtr.plPlayerController;
    // 随机播放: 同目录列表内随机挑一条(避开当前); 单条从头重播
    if (playCtr.playRepeat == PlayRepeat.shuffleList) {
      if (list.length > 1) {
        playIndex(PlayRepeat.randomIndex(list.length, index.value));
      } else if (playCtr.videoPlayerController case final ctr?) {
        ctr.seek(Duration.zero).whenComplete(ctr.play);
      }
      return true;
    }
    final next = index.value + 1;
    if (next < list.length) {
      playIndex(next);
      return true;
    }
    if (playCtr.playRepeat == PlayRepeat.listCycle) {
      if (list.length == 1) {
        if (playCtr.videoPlayerController case final ctr?) {
          ctr.seek(Duration.zero).whenComplete(ctr.play);
        }
      } else {
        playIndex(0);
      }
      return true;
    }
    return false;
  }

  @override
  bool prevPlay() {
    // 随机播放: "上一个"同样随机挑(随机模式下顺序语义不存在)
    if (videoDetailCtr.plPlayerController.playRepeat ==
            PlayRepeat.shuffleList &&
        list.length > 1) {
      playIndex(PlayRepeat.randomIndex(list.length, index.value));
      return true;
    }
    final prev = index.value - 1;
    if (prev >= 0) {
      playIndex(prev);
      return true;
    }
    return false;
  }

  void playIndex(int i, {LocalMediaItem? entry}) {
    final item = entry ?? list[i];
    videoDetail
      ..value.title = item.name
      ..refresh();
    index.value = i;
    unawaited(_switchTo(item));
  }

  /// 切换播放条目。SMB 条目要先在本机代理上注册地址, 所以这一步是异步的。
  Future<void> _switchTo(LocalMediaItem item) async {
    final url = await LocalMediaService.resolvePlayUrl(item);
    if (isClosed) {
      return;
    }
    videoDetailCtr
      ..onReset()
      ..cover.value = ''
      ..cid.value = item.cid
      ..initLocalMediaSource(item, playUrl: url)
      ..playerInit();
    if (PlatformUtils.isMobile) {
      onVideoDetailChange(item);
    }
  }

  void onVideoDetailChange(LocalMediaItem item) {
    videoPlayerServiceHandler?.onVideoDetailChange(
      item,
      videoDetailCtr.cid.value,
      heroTag,
    );
  }
}
