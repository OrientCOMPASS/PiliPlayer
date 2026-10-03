import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/pages/video/introduction/local_media/controller.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 本地/局域网媒体的简介面板: 同目录播放列表。
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Obx(() {
      final currIndex = _controller.index.value;
      final list = _controller.list;
      return SliverFixedExtentList.builder(
        itemCount: list.length,
        itemExtent: 64,
        itemBuilder: (context, index) =>
            _buildItem(theme, list[index], currIndex == index),
      );
    });
  }

  Widget _buildItem(ThemeData theme, LocalMediaItem item, bool isCurr) {
    final progress = LocalMediaProgress.get(item.uri);
    final color = isCurr
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () {
          if (!isCurr) {
            _controller.playIndex(_controller.list.indexOf(item));
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
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 3,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: theme.textTheme.bodyMedium!.fontSize,
                        color: isCurr ? theme.colorScheme.primary : null,
                        fontWeight: isCurr ? FontWeight.bold : null,
                      ),
                    ),
                    Text(
                      [
                        LocalMediaService.maskedUrl(item.uri),
                        if (progress case final p?)
                          '看到 ${DurationUtils.formatDuration(p.inSeconds)}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
