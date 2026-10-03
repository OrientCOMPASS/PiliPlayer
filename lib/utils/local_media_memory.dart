import 'dart:convert' show jsonDecode, jsonEncode, utf8;

import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:archive/archive.dart' show getCrc32;
// firstWhereOrNull 是扩展方法, 要导入扩展本身而不是方法名
import 'package:collection/collection.dart' show IterableExtension;
import 'package:hive_ce/hive.dart';

/// 单个本地/局域网视频"怎么播"的记忆(第二十轮 需求1)。
///
/// 播放**位置**的记忆一直在 [LocalMediaProgress](`Box<int>`, 一个 int 一个 key),
/// 这里补上位置之外的设置: 倍速、VR 片源布局、眼位、视场角、陀螺仪。
///
/// 字段为 null 表示**不记忆该项**(下次跟随全局默认), 而不是"记住一个空值":
///   * 倍速与全局默认一致时不写 —— 否则用户改了全局默认倍速, 看过的老视频
///     还 stuck 在旧值上;
///   * 普通 2D 片源不写 VR 块 —— 否则会把"自动识别"钉死成 off。
///
/// 存储在 `GStorage.video`(Box<dynamic>) 里, 值是 JSON 字符串,
/// key 为 `localMem:<crc32(uri)>`(与位置记忆同一套 uri 标识, 前缀不冲突)。
class LocalMediaSettings {
  const LocalMediaSettings({
    this.speed,
    this.vrProjection,
    this.vrEye,
    this.vrFov,
    this.vrGyro,
  });

  /// 播放倍速; null = 跟随全局默认
  final double? speed;

  /// VR 片源布局(用户当时的选择或自动识别的**生效值**); null = 交给自动识别
  final VrProjection? vrProjection;

  /// 双目片源渲染哪只眼
  final VrEye? vrEye;

  /// 水平视场角(度)
  final double? vrFov;

  /// 陀螺仪环视
  final bool? vrGyro;

  bool get hasVr =>
      vrProjection != null || vrEye != null || vrFov != null || vrGyro != null;

  bool get isEmpty => speed == null && !hasVr;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (speed != null) 'speed': speed,
    if (vrProjection != null) 'vr': vrProjection!.name,
    if (vrEye != null) 'eye': vrEye!.name,
    if (vrFov != null) 'fov': vrFov,
    if (vrGyro != null) 'gyro': vrGyro,
  };

  static LocalMediaSettings? fromEncoded(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) {
      return null;
    }
    final speed = decoded['speed'];
    final fov = decoded['fov'];
    final gyro = decoded['gyro'];
    return LocalMediaSettings(
      speed: speed is num ? speed.toDouble() : null,
      vrProjection: _projectionOf(decoded['vr']),
      vrEye: _eyeOf(decoded['eye']),
      vrFov: fov is num ? fov.toDouble() : null,
      vrGyro: gyro is bool ? gyro : null,
    );
  }

  static VrProjection? _projectionOf(Object? value) => value is String
      ? VrProjection.values.firstWhereOrNull((e) => e.name == value)
      : null;

  static VrEye? _eyeOf(Object? value) => value is String
      ? VrEye.values.firstWhereOrNull((e) => e.name == value)
      : null;

  @override
  String toString() =>
      'LocalMediaSettings(speed: $speed, vr: $vrProjection, eye: $vrEye, '
      'fov: $vrFov, gyro: $vrGyro)';
}

/// 读写 [LocalMediaSettings]。
abstract final class LocalMediaMemory {
  static const String _prefix = 'localMem:';

  /// 条目上限: 超了按时间戳淘汰最旧的(每条几十字节, 500 条也就几十 KB,
  /// 但不设上限的话用久了会一直涨)
  static const int _maxEntries = 500;

  static Box<dynamic> get _box => GStorage.video;

  static String keyOf(String uri) => '$_prefix${getCrc32(utf8.encode(uri))}';

  static LocalMediaSettings? get(String uri) =>
      LocalMediaSettings.fromEncoded(_box.get(keyOf(uri)));

  /// 覆盖写入(整条替换)。[settings] 为空时等价于删除记忆。
  static void put(String uri, LocalMediaSettings settings) {
    if (settings.isEmpty) {
      clear(uri);
      return;
    }
    final json = settings.toJson()..['t'] = DateTime.now().millisecondsSinceEpoch;
    _box.put(keyOf(uri), jsonEncode(json));
    _pruneIfNeeded();
  }

  static void clear(String uri) => _box.delete(keyOf(uri));

  /// 清掉全部本地媒体播放设置记忆(设置页"清除缓存"会连整个盒子一起清)
  static int clearAll() {
    final keys = _box.keys.where(_isOwnKey).toList();
    _box.deleteAll(keys);
    return keys.length;
  }

  static bool _isOwnKey(Object? key) =>
      key is String && key.startsWith(_prefix);

  static void _pruneIfNeeded() {
    final entries = <(Object, int)>[];
    for (final key in _box.keys) {
      if (!_isOwnKey(key)) {
        continue;
      }
      final settings = LocalMediaSettings.fromEncoded(_box.get(key));
      if (settings == null) {
        continue;
      }
      entries.add((key, _timestampOf(_box.get(key))));
    }
    if (entries.length <= _maxEntries) {
      return;
    }
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    final drop = entries.length - _maxEntries;
    _box.deleteAll([for (var i = 0; i < drop; i++) entries[i].$1]);
  }

  static int _timestampOf(Object? raw) {
    if (raw is! String) {
      return 0;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['t'] is num) {
        return (decoded['t'] as num).toInt();
      }
    } on FormatException {
      // 脏数据按最旧处理, 优先被淘汰
    }
    return 0;
  }
}
