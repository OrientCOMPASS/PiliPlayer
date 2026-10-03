import 'dart:async' show unawaited;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/pages/video/introduction/local_media/controller.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 播放列表单条条目的固定高度(表头定位/自动滚动都按它算)
const double kLocalMediaPlaylistItemExtent = 64;

/// 播放列表表头的高度(与 [LocalMediaPlaylistHeader] 内部一致)
const double kLocalMediaPlaylistHeaderExtent = 46;

/// 播放列表表头: 条目计数 + **快速检索**。
///
/// 检索只过滤展示, 不改变播放列表本身(上一个/下一个、循环、随机依旧走全量),
/// 所以正在播的条目被过滤掉也不会中断播放——表头上会提示"当前播放已被过滤"。
class LocalMediaPlaylistHeader extends StatefulWidget {
  const LocalMediaPlaylistHeader({super.key, required this.heroTag});

  final String heroTag;

  @override
  State<LocalMediaPlaylistHeader> createState() =>
      _LocalMediaPlaylistHeaderState();
}

class _LocalMediaPlaylistHeaderState extends State<LocalMediaPlaylistHeader> {
  late final LocalMediaIntroController _controller =
      Get.find<LocalMediaIntroController>(tag: widget.heroTag);
  final TextEditingController _textCtr = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _textCtr.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SizedBox(
      height: kLocalMediaPlaylistHeaderExtent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Style.safeSpace, 4, 10, 6),
        child: Row(
          spacing: 8,
          children: [
            Obx(() {
              final total = _controller.list.length;
              final keyword = _controller.query.value.trim();
              final shown = keyword.isEmpty
                  ? total
                  : _controller.visibleIndices.length;
              return Text(
                keyword.isEmpty ? '播放列表 $total' : '$shown / $total',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              );
            }),
            Expanded(
              child: SizedBox(
                height: 34,
                child: TextField(
                  controller: _textCtr,
                  focusNode: _focusNode,
                  onChanged: _controller.setQuery,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '快速搜索播放列表',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints: const BoxConstraints(minWidth: 34),
                    suffixIcon: Obx(
                      () => _controller.query.value.isEmpty
                          ? const SizedBox.shrink()
                          : IconButton(
                              tooltip: '清除',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              constraints: const BoxConstraints(minWidth: 34),
                              padding: .zero,
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _textCtr.clear();
                                _controller.clearQuery();
                              },
                            ),
                    ),
                    suffixIconConstraints: const BoxConstraints(minWidth: 34),
                    contentPadding: .zero,
                    border: OutlineInputBorder(
                      borderRadius: const BorderRadius.all(Radius.circular(17)),
                      borderSide: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: const BorderRadius.all(Radius.circular(17)),
                      borderSide: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: const BorderRadius.all(Radius.circular(17)),
                      borderSide: BorderSide(color: colorScheme.primary),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 本地/局域网媒体的简介面板: 同目录播放列表。
///
/// 第十九轮: 切换视频时列表**自动滚动到正在播的那一条**(此前只高亮不滚动,
/// 几十集的目录里切几集就找不到焦点了), 表头见 [LocalMediaPlaylistHeader]。
class LocalMediaIntroPanel extends StatefulWidget {
  const LocalMediaIntroPanel({super.key, required this.heroTag});

  final String heroTag;

  @override
  State<LocalMediaIntroPanel> createState() => _LocalMediaIntroPanelState();
}

class _LocalMediaIntroPanelState extends State<LocalMediaIntroPanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final _controller = Get.find<LocalMediaIntroController>(
    tag: widget.heroTag,
  );

  final List<Worker> _workers = [];

  @override
  void initState() {
    super.initState();
    // 焦点跟随: 开播/切集/检索过滤变化后, 把正在播的那一条滚进可视区
    _workers
      ..add(ever<int>(_controller.index, (_) => scrollToCurrent()))
      ..add(ever<String>(_controller.query, (_) => scrollToCurrent()));
    // 首帧之后才有 ScrollPosition, 首次定位不带动画(避免进页面就晃一下)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        scrollToCurrent(animate: false);
      }
    });
  }

  @override
  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    super.dispose();
  }

  /// 把正在播放的条目滚到可视区域(贴表头下方 / 底部留一条)。
  ///
  /// 用 [ScrollPosition] 直接算偏移而不是 `Scrollable.ensureVisible`:
  /// 列表是 `SliverFixedExtentList`, 目标条目很可能**还没被构建**(懒加载),
  /// 拿不到它的 context; 而定高列表的偏移是可以精确算出来的。
  /// 面板可能挂在外层 CustomScrollView 上(竖屏用 intro 的 controller,
  /// 横屏布局不带 controller), 所以一律从 context 找最近的 Scrollable。
  void scrollToCurrent({bool animate = true}) {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null ||
        !position.hasClients ||
        !position.hasContentDimensions ||
        !position.hasViewportDimension) {
      return;
    }
    final visible = _controller.visibleIndexOfCurrent;
    if (visible < 0) {
      return; // 正在播的被检索过滤掉了, 不抢用户的滚动位置
    }
    const extent = kLocalMediaPlaylistItemExtent;
    const header = kLocalMediaPlaylistHeaderExtent;
    final itemTop = header + visible * extent;
    final itemBottom = itemTop + extent;
    // 表头是 pinned 的, 它一直占着视口顶部 header 的高度
    final viewTop = position.pixels + header;
    final viewBottom = position.pixels + position.viewportDimension;
    final double target;
    if (itemTop < viewTop) {
      target = itemTop - header;
    } else if (itemBottom > viewBottom) {
      target = itemBottom - position.viewportDimension + extent / 2;
    } else {
      return; // 已经看得见, 不打扰
    }
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - position.pixels).abs() < 1) {
      return;
    }
    if (animate) {
      unawaited(
        position.animateTo(
          clamped,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      position.jumpTo(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Obx(() {
      // visibleIndices 内部读了 query.value, Obx 因此在关键词变化时重建
      final indices = _controller.visibleIndices;
      final currIndex = _controller.index.value;
      if (indices.isEmpty) {
        return SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: Column(
                mainAxisSize: .min,
                spacing: 8,
                children: [
                  const Icon(Icons.search_off_outlined, size: 40),
                  Text(
                    '播放列表里没有匹配「${_controller.query.value.trim()}」的条目',
                    textAlign: .center,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return SliverFixedExtentList.builder(
        itemCount: indices.length,
        itemExtent: kLocalMediaPlaylistItemExtent,
        itemBuilder: (context, position) {
          final index = indices[position];
          return _buildItem(
            theme,
            _controller.list[index],
            index,
            currIndex == index,
          );
        },
      );
    });
  }

  Widget _buildItem(
    ThemeData theme,
    LocalMediaItem item,
    int index,
    bool isCurr,
  ) {
    final progress = LocalMediaProgress.get(item.uri);
    final color = isCurr
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      type: .transparency,
      child: InkWell(
        onTap: () {
          if (!isCurr) {
            _controller.playIndex(index);
            // 点完就把焦点滚过来, 不等播放真正切过去(SMB 解析地址要一会儿)
            scrollToCurrent();
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Style.safeSpace),
          child: Row(
            spacing: 10,
            children: [
              Icon(
                item.isAudio ? Icons.audiotrack_outlined : Icons.movie_outlined,
                size: 20,
                color: color,
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: .center,
                  crossAxisAlignment: .start,
                  spacing: 3,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: .ellipsis,
                      style: TextStyle(
                        fontSize: theme.textTheme.bodyMedium!.fontSize,
                        color: isCurr ? theme.colorScheme.primary : null,
                        fontWeight: isCurr ? FontWeight.bold : null,
                      ),
                    ),
                    Text(
                      [
                        LocalMediaService.displayPath(item),
                        if (progress case final p?)
                          '看到 ${DurationUtils.formatDuration(p.inSeconds)}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: .ellipsis,
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                  ],
                ),
              ),
              if (isCurr)
                Icon(Icons.play_arrow, size: 20, color: color)
              else if (progress != null)
                Icon(Icons.history, size: 16, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
