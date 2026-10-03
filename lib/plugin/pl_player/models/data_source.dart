import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );

  /// 直接播放一个本地文件(「本地」板块), 不涉及 B 站缓存目录结构。
  ///
  /// 仍然是 [FileSource], 因此播放器里所有"离线"判断(不上报历史、
  /// 不请求预览图、打开失败不重试等)都会自动生效。
  FileSource.direct({required String filePath})
    : dir = path.dirname(filePath),
      isMp4 = true,
      super(videoSource: filePath, audioSource: null);
}
