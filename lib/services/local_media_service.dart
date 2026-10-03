import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart' show downloadPath;
import 'package:dio/dio.dart';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/services/smb/smb2_client.dart' show NtStatus, SmbException;
import 'package:PiliPlus/services/smb/smb_browse.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// 「本地」板块的数据层: 本机目录浏览 + WebDAV 浏览 + 播放地址拼接。
///
/// 设计上只依赖两样东西:
///   * `dart:io` 直接读文件系统(安卓 13+ 由 READ_MEDIA_VIDEO 授权, 13 以下由
///     READ_EXTERNAL_STORAGE 授权, 两者都已在 AndroidManifest 中声明);
///   * 已有的 `webdav_client`(原本用于设置备份)浏览局域网 WebDAV。
/// 播放交给 mpv: 安卓端打包的 FFmpeg 启用了 file/http/https/ftp 协议,
/// 所以本机和 WebDAV/HTTP/FTP 都能直接播, 不需要在应用内做代理转发。
abstract final class LocalMediaService {
  /// 安卓主存储的根目录
  static const String primaryStorage = '/storage/emulated/0';

  // ==================== 来源管理 ====================

  static List<LocalMediaSource> loadSources() {
    final saved = GStorage.setting.get(SettingBoxKey.localMediaSources);
    final result = <LocalMediaSource>[];
    if (saved is List) {
      for (final e in saved) {
        if (LocalMediaSource.fromJson(e) case final source?) {
          result.add(source);
        }
      }
    }
    return result;
  }

  static Future<void> saveSources(List<LocalMediaSource> sources) =>
      GStorage.setting.put(
        SettingBoxKey.localMediaSources,
        sources.map((e) => e.toJson()).toList(),
      );

  /// 本机默认来源: 主存储 + 已挂载的 SD 卡/U 盘
  static Future<List<LocalMediaSource>> deviceSources() async {
    final roots = <String>[primaryStorage];
    if (Platform.isAndroid) {
      try {
        final dirs = await getExternalStorageDirectories();
        for (final dir in dirs ?? <Directory>[]) {
          // .../storage/XXXX-XXXX/Android/data/<pkg>/files -> /storage/XXXX-XXXX
          final volume = _volumeRootOf(dir.path);
          if (volume != null && !roots.contains(volume)) {
            roots.add(volume);
          }
        }
      } catch (_) {
        // 取不到就只用主存储
      }
    }
    return [
      for (final root in roots)
        if (Directory(root).existsSync())
          LocalMediaSource(
            type: LocalMediaSourceType.device,
            name: roots.length == 1 ? '本机存储' : '存储 ${p.basename(root)}',
            url: root,
          ),
    ];
  }

  /// 从应用专属外部目录反推存储卷根目录:
  /// `/storage/emulated/0/Android/data/<pkg>/files` -> `/storage/emulated/0`
  /// `/storage/9C33-1234/Android/data/<pkg>/files` -> `/storage/9C33-1234`
  static String? _volumeRootOf(String path) {
    final parts = p.split(path);
    if (parts.length < 3 || parts[0] != p.separator || parts[1] != 'storage') {
      return null;
    }
    if (parts[2] == 'emulated') {
      return parts.length < 4
          ? null
          : p.join(p.separator, parts[1], parts[2], parts[3]);
    }
    return p.join(p.separator, parts[1], parts[2]);
  }

  // ==================== 权限 ====================

  /// 读取本机媒体文件所需权限(安卓 13+ 为 READ_MEDIA_VIDEO)
  static Future<bool> ensureDevicePermission() async {
    if (!PlatformUtils.isMobile) {
      return true;
    }
    try {
      final status = await Permission.videos.request();
      if (status.isGranted || status.isLimited) {
        return true;
      }
      // 安卓 12 及以下没有 videos 权限, 退回 storage
      final legacy = await Permission.storage.request();
      return legacy.isGranted || legacy.isLimited;
    } catch (_) {
      return false;
    }
  }

  /// 是否**已经**有存储读取权限(只探测状态, 不弹授权框)。
  /// 供"缓存过期后台静默重扫"用: 没权限就跳过, 不打扰既有缓存的展示。
  static Future<bool> hasDevicePermission() async {
    if (!PlatformUtils.isMobile) {
      return true;
    }
    try {
      final status = await Permission.videos.status;
      if (status.isGranted || status.isLimited) {
        return true;
      }
      final legacy = await Permission.storage.status;
      return legacy.isGranted || legacy.isLimited;
    } catch (_) {
      return false;
    }
  }

  /// 安卓 14+「选择照片和视频」(部分访问)是否生效。
  /// 部分访问下**未勾选的文件对应用完全不可见**(FUSE 连列目录都不给),
  /// 用户会以为是列表"过滤"了自己的文件——必须明确提示, 不静默失效。
  static Future<bool> deviceAccessLimited() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      if ((await Permission.videos.status).isLimited) {
        return true;
      }
      return (await Permission.storage.status).isLimited;
    } catch (_) {
      return false;
    }
  }

  // ==================== 浏览 ====================

  /// 列目录。失败时返回 [Error](带人类可读的原因)。
  static Future<LoadingState<List<LocalMediaItem>>> list({
    required LocalMediaSource source,
    required String path,
    LocalMediaSort sort = LocalMediaSort.name,
    bool showHidden = false,
  }) async {
    try {
      final items = await listOrThrow(
        source: source,
        path: path,
        showHidden: showHidden,
      );
      return Success(sortItems(items, sort));
    } catch (err) {
      return Error(_humanize(err, source));
    }
  }

  /// 同 [list], 但**原样抛出**底层异常。
  ///
  /// 浏览页需要它来区分"SMB 要账号"(`SmbException.isAuthFailure`)和其它错误:
  /// 前者要弹凭据框重试并把账号存进来源, 后者只需展示原因。
  /// 排序交给调用方(浏览页有自己的排序状态)。
  ///
  /// **不做文件类型过滤**(第十三轮真机反馈"列表过滤了我准备的 VR 视频"
  /// 之后的彻底简化): 目录里拿到什么就返回什么, 是不是媒体交给 mpv 在
  /// 播放时按内容判断——最差就是点开报"无法播放", 也好过静默吞文件。
  static Future<List<LocalMediaItem>> listOrThrow({
    required LocalMediaSource source,
    required String path,
    bool showHidden = false,
  }) async {
    return switch (source.type) {
      LocalMediaSourceType.device => await _listDevice(
        source,
        path,
        showHidden: showHidden,
      ),
      LocalMediaSourceType.webdav => await _listWebDav(
        source,
        path,
        showHidden: showHidden,
      ),
      LocalMediaSourceType.smb => await _listSmb(
        source,
        path,
        showHidden: showHidden,
      ),
      _ => <LocalMediaItem>[],
    };
  }

  // ==================== 外置字幕自动匹配 ====================

  /// 视频所在目录。各来源的路径约定不同(本机=绝对路径, SMB=共享名打头的
  /// 反斜杠路径, WebDAV=以 / 开头的服务器路径), 直链来源没有目录可列。
  static String? parentDirOf(LocalMediaItem item) {
    switch (item.source.type) {
      case LocalMediaSourceType.device:
        final dir = p.dirname(item.uri);
        return dir.isEmpty ? null : dir;
      case LocalMediaSourceType.smb:
        final rp = item.remotePath;
        if (rp == null || rp.isEmpty) {
          // 共享级来源且文件就在共享根上 -> 空串(共享根);
          // 主机级来源不可能没有 remotePath, 保险起见返回 null
          return item.source.isSmbHostRoot ? null : '';
        }
        final norm = SmbBrowse.normalizePath(rp);
        final i = norm.lastIndexOf('\\');
        if (i < 0) {
          // 主机级来源里 remotePath 只有共享名一段 -> 那是共享, 不是文件
          return item.source.isSmbHostRoot ? null : '';
        }
        return norm.substring(0, i);
      case LocalMediaSourceType.webdav:
        final rp = item.remotePath ?? item.uri;
        final i = rp.lastIndexOf('/');
        return i <= 0 ? '/' : rp.substring(0, i);
      case LocalMediaSourceType.http:
      case LocalMediaSourceType.ftp:
        return null;
    }
  }

  /// 去掉扩展名(用于同名匹配)
  static String baseNameOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  /// 找出与视频**同目录、文件名匹配**的外置字幕(VLC / mpv 的同名规则)。
  ///
  /// 匹配(不区分大小写):
  ///   * 主名完全相同: `movie.mkv` -> `movie.srt` / `movie.ass` / `movie.vtt` …
  ///   * 主名 + 语言等后缀: `movie.zh-CN.srt`、`movie.chs.ass`、`movie.中文.srt`
  /// 排序: 主名完全相同的排前面, 其余按文件名自然序(第2集 在 第10集 前)。
  ///
  /// 读不到同目录(无权限/断链)时返回空 —— **绝不能因为找字幕而影响播放**。
  static Future<List<LocalMediaItem>> findMatchingSubtitles(
    LocalMediaItem video,
  ) async {
    final dir = parentDirOf(video);
    if (dir == null) {
      return const [];
    }
    final base = baseNameOf(video.name).toLowerCase();
    if (base.isEmpty) {
      return const [];
    }
    List<LocalMediaItem> siblings;
    try {
      siblings = await listOrThrow(source: video.source, path: dir);
    } catch (_) {
      return const [];
    }
    final exact = <LocalMediaItem>[];
    final withSuffix = <LocalMediaItem>[];
    for (final item in siblings) {
      if (item.isDirectory || !item.isSubtitle) {
        continue;
      }
      final subBase = baseNameOf(item.name).toLowerCase();
      if (subBase == base) {
        exact.add(item);
      } else if (subBase.startsWith('$base.')) {
        withSuffix.add(item);
      }
    }
    exact.sort((a, b) => _compareName(a.name, b.name));
    withSuffix.sort((a, b) => _compareName(a.name, b.name));
    return [...exact, ...withSuffix];
  }

  /// 从「父目录 path + 条目」推出下一层的 path。
  ///
  /// 三种来源的约定不同(本机是绝对路径, 网络是服务器相对路径), 浏览页下钻与
  /// 递归检索都必须用同一套, 否则很容易多套一层共享名。
  static String childPath(
    LocalMediaSource source,
    LocalMediaItem item,
  ) => switch (source.type) {
    LocalMediaSourceType.device => item.uri,
    _ => item.remotePath ?? item.uri,
  };

  /// 在 [rootPath] **及其所有子目录**里检索文件名包含 [query] 的条目
  /// (与列表一致: 不按扩展名过滤, 能不能播交给播放器判断)。
  ///
  /// 广度优先: 离当前目录越近的结果越靠前(要搜的东西多半就在附近),
  /// 因此结果**不再按名称重排**, 保留这个顺序。
  ///
  /// [maxResults] / [maxDirs] 是硬上限: 整卡递归动辄上万个目录, SMB 更是
  /// 每个目录一次网络往返, 不设上限会把 UI 和连接一起拖死; 触到上限时
  /// 通过 [onProgress] 让调用方能把"已扫描/已找到"显示出来。
  /// [cancelled] 返回 true 立刻收手(改关键词、退出页面、销毁控制器)。
  /// [onFound] 每命中一条就立刻回调 —— 结果**边扫边出**, 不用等整棵树遍历完
  /// (大目录/局域网下等全部扫完可能要几十秒, 期间界面一片空白是不可接受的)。
  static Future<List<LocalMediaItem>> search({
    required LocalMediaSource source,
    required String rootPath,
    required String query,
    int maxResults = 500,
    int maxDirs = 1500,
    bool showHidden = false,
    bool Function()? cancelled,
    void Function(int scannedDirs, int matches)? onProgress,
    void Function(LocalMediaItem item)? onFound,
  }) async {
    final keyword = query.trim().toLowerCase();
    if (keyword.isEmpty) {
      return const [];
    }
    final results = <LocalMediaItem>[];
    final queue = <String>[rootPath];
    var dirs = 0;
    while (queue.isNotEmpty) {
      if (cancelled?.call() ?? false) {
        break;
      }
      if (dirs >= maxDirs || results.length >= maxResults) {
        break;
      }
      final dir = queue.removeAt(0);
      dirs++;
      List<LocalMediaItem> items;
      try {
        items = await listOrThrow(
          source: source,
          path: dir,
          showHidden: showHidden,
        );
      } catch (_) {
        // 单个目录读不出来(没权限/断链/服务端拒绝)不影响整体检索
        continue;
      }
      for (final item in items) {
        if (item.isDirectory) {
          queue.add(childPath(source, item));
          continue;
        }
        if (item.name.toLowerCase().contains(keyword)) {
          results.add(item);
          onFound?.call(item);
          if (results.length >= maxResults) {
            break;
          }
        }
      }
      onProgress?.call(dirs, results.length);
    }
    return results;
  }

  /// 错误原因的人类可读版本(浏览页自己 catch 时用)
  static String humanize(Object err, LocalMediaSource source) =>
      _humanize(err, source);

  /// 是不是"服务端要求账号/密码不对"
  static bool isAuthFailure(Object err) =>
      err is SmbException && err.isAuthFailure;

  static Future<List<LocalMediaItem>> _listDevice(
    LocalMediaSource source,
    String path, {
    required bool showHidden,
  }) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      throw '目录不存在: $path';
    }
    final items = <LocalMediaItem>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.isEmpty) {
        continue;
      }
      if (!showHidden && name.startsWith('.')) {
        continue;
      }
      final isDir = entity is Directory;
      if (!isDir && entity is! File) {
        continue;
      }
      // 单个条目读不到属性就跳过, 不影响整个目录
      final stat = await _statOrNull(entity);
      if (stat == null) {
        continue;
      }
      items.add(
        LocalMediaItem(
          name: name,
          uri: entity.path,
          source: source,
          size: isDir ? null : stat.size,
          modified: stat.modified,
          isDirectory: isDir,
        ),
      );
    }
    return items;
  }

  /// 目录里条目可能很多, 用异步 stat 避免阻塞 UI 线程
  /// (avoid_slow_async_io 建议同步版本, 这里刻意不用)
  static Future<FileStat?> _statOrNull(FileSystemEntity entity) async {
    try {
      // ignore: avoid_slow_async_io
      return await entity.stat();
    } catch (_) {
      return null;
    }
  }

  static Future<List<LocalMediaItem>> _listWebDav(
    LocalMediaSource source,
    String path, {
    required bool showHidden,
  }) async {
    final client = _webDavClient(source);
    final files = await client.readDir(path.isEmpty ? '/' : path);
    final items = <LocalMediaItem>[];
    for (final f in files) {
      final name = f.name ?? p.basename(f.path ?? '');
      final remotePath = f.path ?? '';
      if (name.isEmpty || name == '.' || name == '..') {
        continue;
      }
      if (!showHidden && name.startsWith('.')) {
        continue;
      }
      final isDir = f.isDir ?? false;
      items.add(
        LocalMediaItem(
          name: name,
          uri: isDir ? remotePath : joinUrl(source.playbackBase, remotePath),
          source: source,
          remotePath: remotePath,
          size: f.size,
          modified: f.mTime,
          isDirectory: isDir,
        ),
      );
    }
    return items;
  }

  static webdav.Client _webDavClient(LocalMediaSource source) =>
      webdav.newClient(
        source.url,
        user: source.username ?? '',
        password: source.password ?? '',
      )
        ..setConnectTimeout(8000)
        ..setReceiveTimeout(20000)
        ..setSendTimeout(20000);

  /// 浏览 SMB(协议实现见 `services/smb/`, 纯 Dart, 可对真实 smbd 联调)。
  ///
  /// 两种来源:
  ///   * **主机级**(`smb://NAS`): 根目录列共享(SRVSVC NetShareEnum),
  ///     共享就是一级子目录; 再往下按 `共享\子路径` 列目录。
  ///   * **共享级**(`smb://NAS/video`): 直接从共享内路径开始列。
  static Future<List<LocalMediaItem>> _listSmb(
    LocalMediaSource source,
    String path, {
    required bool showHidden,
  }) async {
    if (source.isSmbHostRoot) {
      return _listSmbHost(source, path, showHidden: showHidden);
    }
    final ep = source.smbEndpoint;
    if (ep == null) {
      throw 'SMB 地址格式不正确, 应为 smb://主机 或 smb://主机/共享名: '
          '${source.url}';
    }
    final entries = await SmbBrowse.list(
      host: ep.host,
      port: ep.port,
      share: ep.share,
      path: path,
      user: source.username,
      password: source.password,
      domain: source.domain ?? '',
      address: source.address,
      showHidden: showHidden,
    );
    return [
      for (final e in entries)
        LocalMediaItem(
          name: e.name,
          uri: SmbBrowse.uri(
            host: ep.host,
            port: ep.port,
            share: ep.share,
            remotePath: e.remotePath,
          ),
          source: source,
          remotePath: e.remotePath,
          size: e.size,
          modified: e.modified,
          isDirectory: e.isDirectory,
        ),
    ];
  }

  /// 主机级浏览: [path] 是"主机内路径"(第一段为共享名), 空串表示列共享
  static Future<List<LocalMediaItem>> _listSmbHost(
    LocalMediaSource source,
    String path, {
    required bool showHidden,
  }) async {
    final h = source.smbHost;
    if (h == null) {
      throw 'SMB 地址格式不正确, 应为 smb://主机: ${source.url}';
    }
    final rel = SmbBrowse.normalizePath(path);
    if (rel.isEmpty) {
      final result = await SmbBrowse.listShares(
        host: h.host,
        port: h.port,
        user: source.username,
        password: source.password,
        domain: source.domain ?? '',
        address: source.address,
      );
      // 与 VLC/资源管理器一致: 只展示可浏览的磁盘共享(IPC$/ADMIN$/打印队列不要)
      return [
        for (final share in result.browsable)
          LocalMediaItem(
            name: share.name,
            uri: SmbBrowse.uri(
              host: h.host,
              port: h.port,
              share: share.name,
              remotePath: '',
            ),
            source: source,
            remotePath: share.name,
            isDirectory: true,
          ),
      ];
    }
    final (share, inner) = SmbBrowse.splitSharePath(rel);
    if (share.isEmpty) {
      throw 'SMB 路径缺少共享名: $path';
    }
    final entries = await SmbBrowse.list(
      host: h.host,
      port: h.port,
      share: share,
      path: inner,
      user: source.username,
      password: source.password,
      domain: source.domain ?? '',
      address: source.address,
      showHidden: showHidden,
    );
    return [
      for (final e in entries)
        LocalMediaItem(
          name: e.name,
          uri: SmbBrowse.uri(
            host: h.host,
            port: h.port,
            share: share,
            remotePath: e.remotePath,
          ),
          source: source,
          // 主机级来源里 remotePath 必须是"主机内路径"(共享名打头),
          // 浏览页据此继续下钻
          remotePath: '$share\\${e.remotePath}',
          size: e.size,
          modified: e.modified,
          isDirectory: e.isDirectory,
        ),
    ];
  }

  /// 交给播放器之前解析出真正可播的地址。
  ///
  /// SMB 默认走定制 libmpv 内置的 **smb:// 协议**(ffmpeg --enable-libsmb2,
  /// 与 VLC 安卓端同一实现库): mpv 直接持有 SMB 会话 —— seek 是同句柄
  /// 定位读(不重连、不易断流)、退出播放立即断开(不再有代理泵残余传输)、
  /// 会话池完全留给目录浏览(跳转不再与播放抢连接)。设置里可切回旧的
  /// 回环 HTTP 代理路径(兜底)。其余协议(WebDAV/HTTP/FTP/本机)原样返回。
  static Future<String> resolvePlayUrl(LocalMediaItem item) async {
    final source = item.source;
    if (!source.type.needsProxy) {
      return playbackUrl(item);
    }
    // 以**条目自身的 URI** 为准, 而不是来源的 endpoint:
    // 主机级来源(`smb://NAS`)的 endpoint 是 null, 共享名在条目 URI 里。
    final ep = SmbBrowse.parseEndpoint(item.uri) ?? source.smbEndpoint;
    if (ep == null) {
      return playbackUrl(item);
    }
    if (Pref.smbNativeProtocol) {
      return SmbBrowse.directUrl(
        host: ep.host,
        port: ep.port,
        share: ep.share,
        remotePath: ep.path.isEmpty ? (item.remotePath ?? '') : ep.path,
        user: source.username,
        password: source.password,
        domain: source.domain ?? '',
        address: source.address,
      );
    }
    return SmbBrowse.serveUrl(
      host: ep.host,
      port: ep.port,
      share: ep.share,
      remotePath: ep.path.isEmpty ? (item.remotePath ?? '') : ep.path,
      user: source.username,
      password: source.password,
      domain: source.domain ?? '',
      address: source.address,
    );
  }

  /// 下载到本机用的地址: dio 不认识 smb://, SMB 一律经回环 HTTP 代理
  /// (支持 Range, 能断点/进度), 其余来源与 [resolvePlayUrl] 相同。
  static Future<String> resolveTransferUrl(LocalMediaItem item) async {
    final source = item.source;
    if (!source.type.needsProxy) {
      return playbackUrl(item);
    }
    final ep = SmbBrowse.parseEndpoint(item.uri) ?? source.smbEndpoint;
    if (ep == null) {
      return playbackUrl(item);
    }
    return SmbBrowse.serveUrl(
      host: ep.host,
      port: ep.port,
      share: ep.share,
      remotePath: ep.path.isEmpty ? (item.remotePath ?? '') : ep.path,
      user: source.username,
      password: source.password,
      domain: source.domain ?? '',
      address: source.address,
    );
  }

  // ==================== 下载到本机 ====================

  /// 把网络来源(局域网 SMB/WebDAV/HTTP)的文件下载到本机下载目录。
  ///
  /// 目标目录用 app 既有的 [downloadPath]（设置里可改；默认在应用外部存储的
  /// `download/`），重名自动加 ` (1)`/` (2)` 后缀，绝不覆盖已有文件。
  ///
  /// 地址走 [resolveTransferUrl]，三种网络来源是**同一条下载路径**：
  /// SMB 经本机回环 HTTP 代理（支持 Range，dio 能断点/进度），
  /// WebDAV/HTTP 直接下（URL 里的 userinfo 由 dart:io 自动转成 Basic 认证）。
  ///
  /// 返回保存后的文件；用户取消或失败返回 null。
  static Future<File?> downloadTo(
    LocalMediaItem item, {
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
    String? dirPath,
  }) async {
    final url = await resolveTransferUrl(item);
    final dir = Directory(dirPath ?? downloadPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final dest = uniqueFilePath(dir.path, item.name);
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        // 大文件整体传输时间不设上限, 只约束"多久没收到数据"
        receiveTimeout: const Duration(seconds: 60),
        followRedirects: true,
      ),
    );
    final cancelToken = CancelToken();
    try {
      await dio.download(
        url,
        dest,
        cancelToken: cancelToken,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (cancelled?.call() ?? false) {
            if (!cancelToken.isCancelled) {
              cancelToken.cancel('user cancelled');
            }
            return;
          }
          onProgress?.call(received, total < 0 ? (item.size ?? -1) : total);
        },
      );
      if (cancelToken.isCancelled) {
        return null;
      }
      final file = File(dest);
      return file.existsSync() ? file : null;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return null;
      }
      rethrow;
    } finally {
      dio.close(force: true);
    }
  }

  /// 重名不覆盖: `a.mp4` -> `a (1).mp4` -> `a (2).mp4` …
  static String uniqueFilePath(String dir, String fileName) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
    final ext = dot <= 0 ? '' : fileName.substring(dot);
    var candidate = p.join(dir, fileName);
    var n = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '$stem ($n)$ext');
      n++;
      if (n > 999) {
        // 极端情况兜底: 用时间戳, 保证一定能写下去
        return p.join(
          dir,
          '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
        );
      }
    }
    return candidate;
  }

  /// 连通性检查(添加/编辑来源时立即验证)
  static Future<LoadingState<int>> testConnection(
    LocalMediaSource source,
  ) async {
    switch (source.type) {
      case LocalMediaSourceType.webdav:
        return testWebDav(source);
      case LocalMediaSourceType.smb:
        return _testSmb(source);
      default:
        return const Error('直链来源无法预先校验，保存后直接播放即可');
    }
  }

  static Future<LoadingState<int>> _testSmb(LocalMediaSource source) async {
    try {
      // 主机级来源没有共享名, "能不能连"用共享枚举来验证(顺带就是浏览根目录)
      if (source.isSmbHostRoot) {
        final h = source.smbHost!;
        final result = await SmbBrowse.listShares(
          host: h.host,
          port: h.port,
          user: source.username,
          password: source.password,
          domain: source.domain ?? '',
          address: source.address,
        );
        return Success(result.browsable.length);
      }
      final ep = source.smbEndpoint;
      if (ep == null) {
        return Error(
          'SMB 地址格式不正确, 应为 smb://主机 或 smb://主机/共享名: '
          '${source.url}',
        );
      }
      final count = await SmbBrowse.probe(
        host: ep.host,
        port: ep.port,
        share: ep.share,
        path: ep.path,
        user: source.username,
        password: source.password,
        domain: source.domain ?? '',
        address: source.address,
      );
      return Success(count);
    } on SmbException catch (e) {
      return Error(_translateSmb(e, source));
    } catch (err) {
      return Error(_humanize(err, source));
    }
  }

  /// 把 SMB 协议错误翻译成用户能看懂的话
  static String _translateSmb(SmbException e, LocalMediaSource source) {
    final what = '${source.name} (${e.context})';
    if (e.isAuthFailure) {
      return '$what: 用户名或密码错误';
    }
    final isTree = e.context.startsWith('tree connect');
    if (e.status == NtStatus.badNetworkName ||
        (isTree && e.isNotFound)) {
      // 不同服务端对"共享不存在"的回码不一样(Samba 回 BAD_NETWORK_NAME,
      // 部分 NAS 回 OBJECT_NAME_NOT_FOUND), 统一翻译并给出自动枚举的出路
      return '$what: 共享不存在或无权访问。可在「网络」页点主机名自动获取共享列表';
    }
    // 主机级浏览靠 SRVSVC 枚举共享, 服务端禁用 RPC / 不允许匿名枚举时
    // 要给出手动填写的出路, 否则用户只看到一句协议错误
    if (e.context.contains('srvsvc') || e.context.contains('NetShareEnum')) {
      return '$what: 这台主机不提供共享列表(${e.statusText})。'
          '可用「添加网络共享」手动填写 smb://主机/共享名';
    }
    if (e.isNotFound) {
      return '$what: 路径不存在';
    }
    return '$what: ${e.statusText}';
  }

  /// WebDAV 连通性检查
  static Future<LoadingState<int>> testWebDav(LocalMediaSource source) async {
    try {
      final files = await _webDavClient(source).readDir(source.rootPath);
      return Success(files.length);
    } catch (err) {
      return Error(_humanize(err, source));
    }
  }

  static List<LocalMediaItem> sortItems(
    List<LocalMediaItem> items,
    LocalMediaSort sort,
  ) {
    return [...items]..sort((a, b) {
      // 目录永远在前
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      final bySort = switch (sort) {
        LocalMediaSort.name => _compareName(a.name, b.name),
        LocalMediaSort.modified =>
          (b.modified?.millisecondsSinceEpoch ?? 0).compareTo(
            a.modified?.millisecondsSinceEpoch ?? 0,
          ),
        LocalMediaSort.size => (b.size ?? 0).compareTo(a.size ?? 0),
      };
      return bySort != 0 ? bySort : _compareName(a.name, b.name);
    });
  }

  /// 自然排序: 让 `第2集` 排在 `第10集` 前面
  static int _compareName(String a, String b) {
    final ra = RegExp(r'(\d+)');
    var ia = 0;
    var ib = 0;
    while (ia < a.length && ib < b.length) {
      final ma = ra.matchAsPrefix(a, ia);
      final mb = ra.matchAsPrefix(b, ib);
      if (ma != null && mb != null) {
        final na = int.tryParse(ma.group(1)!) ?? 0;
        final nb = int.tryParse(mb.group(1)!) ?? 0;
        if (na != nb) {
          return na.compareTo(nb);
        }
        ia = ma.end;
        ib = mb.end;
        continue;
      }
      final ca = a.toLowerCase().codeUnitAt(ia);
      final cb = b.toLowerCase().codeUnitAt(ib);
      if (ca != cb) {
        return ca.compareTo(cb);
      }
      ia++;
      ib++;
    }
    return (a.length - ia).compareTo(b.length - ib);
  }

  // ==================== 播放地址 ====================

  /// 拼接可直接交给 mpv 的播放地址
  static String playbackUrl(LocalMediaItem item) {
    if (!item.source.type.isNetwork) {
      return item.uri;
    }
    if (item.uri.startsWith('http') || item.uri.startsWith('ftp')) {
      return item.uri;
    }
    return joinUrl(item.source.playbackBase, item.remotePath ?? item.uri);
  }

  /// 把服务器路径安全地拼到基址后面(逐段编码, 避免中文/空格导致 404)
  static String joinUrl(String base, String remotePath) {
    final trimmed = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final segments = remotePath
        .split('/')
        .where((e) => e.isNotEmpty)
        .map(_encodeSegment);
    return '$trimmed/${segments.join('/')}';
  }

  static String _encodeSegment(String segment) {
    var decoded = segment;
    try {
      // 服务器可能已经编码过, 先解码再编码, 避免出现 %2520
      decoded = Uri.decodeComponent(segment);
    } catch (_) {
      decoded = segment;
    }
    return Uri.encodeComponent(decoded);
  }

  /// 播放地址去掉凭据后的形式, 用于界面展示与复制(避免密码外泄)
  static String maskedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.userInfo.isEmpty) {
      return url;
    }
    final user = uri.userInfo.split(':').first;
    final at = url.indexOf('@');
    if (at < 0) {
      return url;
    }
    final schemeEnd = url.indexOf('://');
    if (schemeEnd < 0 || schemeEnd > at) {
      return url;
    }
    return '${url.substring(0, schemeEnd + 3)}${user.isEmpty ? '' : '$user:'}***'
        '${url.substring(at)}';
  }

  static String _humanize(Object err, LocalMediaSource source) {
    // SMB 的协议错误单独翻译(状态码对用户没有意义)
    if (err is SmbException) {
      return _translateSmb(err, source);
    }
    final msg = err.toString();
    if (msg.contains('401') || msg.contains('Unauthorized')) {
      return '${source.name}: 用户名或密码错误';
    }
    if (msg.contains('404') || msg.contains('Not Found')) {
      return '${source.name}: 路径不存在';
    }
    if (msg.contains('SocketException') || msg.contains('timeout')) {
      return '${source.name}: 无法连接, 请检查地址与是否在同一局域网';
    }
    if (msg.contains('Permission denied') || msg.contains('EACCES')) {
      return '${source.name}: 没有读取权限';
    }
    return '${source.name}: $msg';
  }
}
