import 'dart:convert' show utf8;

import 'package:PiliPlus/utils/storage.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:hive_ce/hive.dart';

/// 本地/局域网媒体的播放进度记忆。
///
/// 复用 watchProgress 盒子, key 加 `local:` 前缀, 避免与 B 站 cid 冲突;
/// 本地媒体不向 B 站上报任何进度(见 [PlPlayerController.isLocalMedia])。
abstract final class LocalMediaProgress {
  static const String _prefix = 'local:';

  /// 看到结尾前这么多毫秒就认为看完了, 下次从头播放
  static const int _finishThresholdMs = 10000;

  static Box<int> get _box => GStorage.watchProgress;

  static String keyOf(String uri) => '$_prefix${getCrc32(utf8.encode(uri))}';

  /// 上次播放位置, 没有记录时返回 null
  static Duration? get(String uri) {
    final ms = _box.get(keyOf(uri));
    if (ms == null || ms <= 0) {
      return null;
    }
    return Duration(milliseconds: ms);
  }

  static void put(String uri, Duration position, {Duration? duration}) {
    final ms = position.inMilliseconds;
    if (ms <= 0) {
      return;
    }
    final total = duration?.inMilliseconds ?? 0;
    if (total > 0 && total - ms < _finishThresholdMs) {
      _box.delete(keyOf(uri));
      return;
    }
    _box.put(keyOf(uri), ms);
  }

  static void clear(String uri) => _box.delete(keyOf(uri));

  /// 播放进度比例(0~1), 未知时长或无记录时返回 null
  static double? ratio(String uri, Duration? duration) {
    final pos = get(uri);
    final total = duration?.inMilliseconds ?? 0;
    if (pos == null || total <= 0) {
      return null;
    }
    return (pos.inMilliseconds / total).clamp(0.0, 1.0);
  }
}
