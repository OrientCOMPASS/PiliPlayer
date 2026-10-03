import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel, PlatformException;

/// SAF(系统「选择文件夹」授权)目录树。
///
/// [uri] 是持久化授权的树地址(`content://…/tree/primary%3ADownload`),
/// [docId] 是树根的文档 id(`primary:Download`), [name] 是系统给的显示名。
class SafTree {
  const SafTree({
    required this.uri,
    required this.docId,
    required this.name,
  });

  final String uri;
  final String docId;
  final String name;

  /// 人类可读的路径标签: `primary:Download/电影` -> `内部存储/Download/电影`
  String get readablePath => SafBridge.readablePath(docId);

  static SafTree? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final uri = raw['uri'];
    final docId = raw['docId'];
    if (uri is! String || uri.isEmpty || docId is! String) {
      return null;
    }
    final name = raw['name'];
    return SafTree(
      uri: uri,
      docId: docId,
      name: name is String && name.isNotEmpty
          ? name
          : SafBridge.fallbackName(docId),
    );
  }

  @override
  bool operator ==(Object other) => other is SafTree && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'SafTree($name, $uri)';
}

/// SAF 目录里的一条记录(文件或子目录)。
class SafEntry {
  const SafEntry({
    required this.name,
    required this.docId,
    required this.uri,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  final String name;
  final String docId;

  /// 可直接 `openFileDescriptor` 的文档地址(播放时经它导出 fd)
  final String uri;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;

  static SafEntry? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final name = raw['name'];
    final docId = raw['docId'];
    final uri = raw['uri'];
    if (name is! String || docId is! String || uri is! String) {
      return null;
    }
    final size = _asInt(raw['size']);
    final mtime = _asInt(raw['mtime']);
    return SafEntry(
      name: name,
      docId: docId,
      uri: uri,
      isDirectory: raw['dir'] == true,
      size: size,
      modified: (mtime == null || mtime <= 0)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(mtime),
    );
  }

  /// 标准消息编解码回来可能是 int / double / String, 统一成 int?
  static int? _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v),
    _ => null,
  };

  @override
  String toString() => 'SafEntry($name, $docId)';
}

/// 用户能看懂的 SAF 失败原因(浏览页直接展示, 不再套一层"来源: xxx")
class SafFailure implements Exception {
  const SafFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 与 `MainActivity` / `SafBrowser.kt` 对接的 SAF 桥。
///
/// 存在意义见 SafBrowser.kt 的头注释: 安卓 11+ 作用域存储下 `dart:io` 只能
/// 看到媒体文件, 用户"文件管理器里有、应用里找不到"就是它; 走系统文件夹
/// 授权 + DocumentsContract 才能看到目录里的**全部**条目。
abstract final class SafBridge {
  static const MethodChannel _channel = MethodChannel('piliplus/local_media');

  /// 系统文件夹选择器的等待上限(用户可能在里面翻很久, 但不能永远挂着)
  static const Duration _pickTimeout = Duration(minutes: 5);

  static bool get isAndroid => Platform.isAndroid;

  /// 系统是否支持 SAF(理论上恒为 true, 只是不让老设备直接崩)
  static Future<bool> isSupported() async {
    if (!isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('safSupported') ?? false;
    } on Object {
      return false;
    }
  }

  /// 弹系统「选择文件夹」; 用户取消返回 null。
  ///
  /// [initialUri] 可选, 形如
  /// `content://com.android.externalstorage.documents/document/primary%3A`,
  /// 让选择器直接落在某个卷上。
  static Future<SafTree?> pickTree({String? initialUri}) async {
    if (!isAndroid) {
      return null;
    }
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>?>(
            'safPickTree',
            <String, Object?>{'initialUri': ?initialUri},
          )
          .timeout(_pickTimeout);
      return SafTree.fromMap(raw);
    } on TimeoutException {
      return null;
    } on PlatformException catch (e) {
      if (e.code == 'busy') {
        return null;
      }
      throw SafFailure(e.message ?? '打开系统文件夹选择器失败');
    }
  }

  /// 卷根的初始 uri(内部存储 / 指定卷), 给 [pickTree] 用
  static String initialUriForVolume(String? volumeId) {
    final id = (volumeId == null || volumeId.isEmpty) ? 'primary' : volumeId;
    return 'content://com.android.externalstorage.documents/document/'
        '${Uri.encodeComponent('$id:')}';
  }

  /// 已授权的目录树(持久化权限, 重启后仍在)
  static Future<List<SafTree>> persistedTrees() async {
    if (!isAndroid) {
      return const [];
    }
    try {
      final raw = await _channel.invokeMethod<List<dynamic>?>('safTrees');
      return [
        for (final e in raw ?? const <dynamic>[]) ?SafTree.fromMap(e),
      ];
    } on PlatformException catch (e) {
      throw SafFailure(e.message ?? '读取已授权目录失败');
    }
  }

  /// 列一个目录。[docId] 为空表示树根。
  static Future<List<SafEntry>> listChildren({
    required String treeUri,
    String? docId,
  }) async {
    if (!isAndroid) {
      return const [];
    }
    try {
      final raw = await _channel.invokeMethod<List<dynamic>?>(
        'safList',
        <String, Object?>{'uri': treeUri, 'docId': docId},
      );
      final out = <SafEntry>[];
      for (final e in raw ?? const <dynamic>[]) {
        if (SafEntry.fromMap(e) case final entry?) {
          out.add(entry);
        }
      }
      return out;
    } on PlatformException catch (e) {
      throw SafFailure(e.message ?? '读取目录失败');
    }
  }

  /// 撤销一个目录树的授权
  static Future<bool> releaseTree(String treeUri) async {
    if (!isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
        'safReleaseTree',
        <String, Object?>{'uri': treeUri},
      ) ??
          false;
    } on Object {
      return false;
    }
  }

  /// 系统「所有文件访问权限」(MANAGE_EXTERNAL_STORAGE)是否已开
  static Future<bool> hasAllFilesAccess() async {
    if (!isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('safHasAllFilesAccess') ?? false;
    } on Object {
      return false;
    }
  }

  /// 打开「所有文件访问权限」设置页
  static Future<bool> openAllFilesAccessSettings() async {
    if (!isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('safOpenAllFilesSettings') ??
          false;
    } on Object {
      return false;
    }
  }

  // ==================== 播放用的 fd ====================

  /// 把 content:// 文档导出成 fd, 返回可直接交给 mpv 的 `fd://N`。
  ///
  /// 走的是 MainActivity 里既有的 `resolveContentMedia`(系统「用其它应用
  /// 打开」进来的视频就是这条路), fd 由 [SafFdRegistry] 记账, 播放页退出
  /// 或切换条目时统一回收。
  static Future<String?> playUrlOf(String contentUri) async {
    if (!isAndroid || !contentUri.startsWith('content://')) {
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
        'resolveContentMedia',
        <String, Object?>{'uri': contentUri},
      );
      final fd = raw?['fd'];
      if (fd is int) {
        SafFdRegistry.remember(contentUri, fd);
        return 'fd://$fd';
      }
      final path = raw?['path'];
      if (path is String && path.isNotEmpty) {
        return path;
      }
      return null;
    } on PlatformException catch (e) {
      throw SafFailure(e.message ?? '无法打开文件(授权可能已失效)');
    }
  }

  static Future<void> closeFd(int fd) async {
    if (!isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('closeFd', <String, Object?>{'fd': fd});
    } on Object {
      // fd 可能已被 Kotlin 侧的 LRU 兜底关掉, 无所谓
    }
  }

  static Future<void> closeAllFds() async {
    if (!isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('closeAllFds');
    } on Object {
      // 关不掉也有 Kotlin 侧的 LRU 兜底, 不影响功能
    }
  }

  // ==================== 纯函数(docId 语义) ====================

  /// docId 的兜底显示名: `primary:Download/电影` -> `电影`
  static String fallbackName(String docId) {
    final tail = docId.split('/').last.split(':').last;
    if (tail.isNotEmpty) {
      return tail;
    }
    final volume = docId.split(':').first;
    if (volume == 'primary') {
      return '内部存储';
    }
    return volume.isEmpty ? '本机目录' : volume;
  }

  /// docId 的人类可读路径: `primary:Download/电影` -> `内部存储/Download/电影`
  static String readablePath(String docId) {
    final colon = docId.indexOf(':');
    if (colon < 0) {
      return docId;
    }
    final volume = docId.substring(0, colon);
    final rest = docId.substring(colon + 1);
    final head = switch (volume) {
      'primary' => '内部存储',
      '' => '本机',
      _ => volume,
    };
    return rest.isEmpty ? head : '$head/$rest';
  }

  /// 从树根 docId 推出**父目录** docId(外置字幕同目录匹配要用)。
  /// 已经在树根上时返回 null。
  static String? parentDocId(String docId) {
    final slash = docId.lastIndexOf('/');
    if (slash < 0) {
      return null;
    }
    final parent = docId.substring(0, slash);
    return parent.contains(':') ? parent : null;
  }

  /// 子目录 docId(与 [parentDocId] 互逆)
  static String childDocId(String parentDocId, String name) =>
      parentDocId.isEmpty ? name : '$parentDocId/$name';

  /// 从树地址里取出树根文档 id:
  /// `content://com.android.externalstorage.documents/tree/primary%3ADownload`
  /// -> `primary:Download`([Uri.pathSegments] 会自动解百分号转义)
  static String? treeDocIdOf(String treeUri) {
    final segments = Uri.tryParse(treeUri)?.pathSegments;
    if (segments == null || segments.isEmpty) {
      return null;
    }
    return segments.last;
  }

  /// 是不是 content:// 地址(SAF 条目 / 系统分享进来的文件)
  static bool isContentUri(String uri) => uri.startsWith('content://');
}

/// 本次播放会话导出过的 fd 记账本。
///
/// Kotlin 侧另有 LRU 兜底(最多 8 个), 但**主动回收**才干净: 切换条目、
/// 退出播放页时把上一批(视频本体 + 外挂字幕)一起关掉。
abstract final class SafFdRegistry {
  static final List<(String, int)> _open = [];

  static void remember(String uri, int fd) => _open.add((uri, fd));

  static List<(String, int)> get open => List.unmodifiable(_open);

  /// 关掉全部(播放页退出 / 切换来源)
  static Future<void> releaseAll() async {
    final pending = List<(String, int)>.of(_open);
    _open.clear();
    for (final entry in pending) {
      await SafBridge.closeFd(entry.$2);
    }
  }
}
