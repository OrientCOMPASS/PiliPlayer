import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/saf/saf_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// SAF(系统「选择文件夹」授权)本机浏览的纯逻辑回归测试 —— 第十九轮重写。
///
/// 真机反馈的两个问题都出在"本机目录怎么列"上:
///   * 作用域存储下 dart:io 只能看到媒体文件 → 用户"文件管理器里有、
///     应用里找不到";
///   * `await for` 遇到单个坏条目就把整层结果丢掉 → "目录显示不全"。
/// 前者靠 SAF(DocumentsContract)解决, 于是 docId 成了本机浏览的路径语义,
/// 这里把 docId <-> 路径/显示名/父子关系 的换算全部钉死。
void main() {
  const treeUri =
      'content://com.android.externalstorage.documents/tree/primary%3ADownload';

  group('SafBridge docId 换算', () {
    test('从树地址取出树根 docId(百分号转义要解开)', () {
      expect(SafBridge.treeDocIdOf(treeUri), 'primary:Download');
      expect(
        SafBridge.treeDocIdOf(
          'content://com.android.externalstorage.documents/'
          'tree/primary%3ADownload%2Fmovies',
        ),
        'primary:Download/movies',
      );
      expect(SafBridge.treeDocIdOf(''), isNull);
    });

    test('可读路径: primary = 内部存储, 其它卷用卷标', () {
      expect(
        SafBridge.readablePath('primary:Download/电影'),
        '内部存储/Download/电影',
      );
      expect(SafBridge.readablePath('primary:'), '内部存储');
      expect(SafBridge.readablePath('primary'), 'primary');
      expect(SafBridge.readablePath('9C33-1234:Videos'), '9C33-1234/Videos');
    });

    test('兜底显示名取最后一段', () {
      expect(SafBridge.fallbackName('primary:Download/电影'), '电影');
      expect(SafBridge.fallbackName('primary:'), '内部存储');
      expect(SafBridge.fallbackName('9C33-1234:'), '9C33-1234');
    });

    test('父子 docId 互逆', () {
      expect(
        SafBridge.childDocId('primary:Download', '电影'),
        'primary:Download/电影',
      );
      expect(SafBridge.childDocId('', '电影'), '电影');
      expect(
        SafBridge.parentDocId('primary:Download/电影/a.mkv'),
        'primary:Download/电影',
      );
      expect(SafBridge.parentDocId('primary:Download/a.mkv'), 'primary:Download');
      // 卷根上的文件: 父目录不是合法的树内 docId, 返回 null(不去猜)
      expect(SafBridge.parentDocId('primary:a.mkv'), isNull);
    });

    test('content:// 识别', () {
      expect(SafBridge.isContentUri('content://a/b'), isTrue);
      expect(SafBridge.isContentUri('/storage/emulated/0/a.mp4'), isFalse);
      expect(SafBridge.isContentUri('fd://12'), isFalse);
      expect(SafBridge.isContentUri('smb://nas/pub/a.mp4'), isFalse);
    });

    test('条目解析: 缺字段/脏类型不抛异常', () {
      expect(SafEntry.fromMap(null), isNull);
      expect(SafEntry.fromMap(<dynamic, dynamic>{'name': 'a.mp4'}), isNull);
      final entry = SafEntry.fromMap(<dynamic, dynamic>{
        'name': 'a.mp4',
        'docId': 'primary:Download/a.mp4',
        'uri': '$treeUri/document/primary%3ADownload%2Fa.mp4',
        'dir': false,
        'size': 1024,
        'mtime': 1700000000000,
      });
      expect(entry, isNotNull);
      expect(entry!.name, 'a.mp4');
      expect(entry.size, 1024);
      expect(entry.isDirectory, isFalse);
      expect(entry.modified, isNotNull);
      // 类型判定是 LocalMediaItem 的事(按扩展名), SafEntry 只搬数据
      expect(
        LocalMediaItem(
          name: entry.name,
          uri: entry.uri,
          source: const LocalMediaSource(
            type: LocalMediaSourceType.device,
            name: 'Download',
            url: treeUri,
          ),
          remotePath: entry.docId,
        ).isVideo,
        isTrue,
      );
    });

    test('树解析: 没有显示名时用 docId 兜底', () {
      final tree = SafTree.fromMap(<dynamic, dynamic>{
        'uri': treeUri,
        'docId': 'primary:Download',
      });
      expect(tree, isNotNull);
      expect(tree!.name, 'Download');
      expect(tree.readablePath, '内部存储/Download');
      expect(SafTree.fromMap(<dynamic, dynamic>{'uri': '', 'docId': 'x'}), isNull);
    });
  });

  group('LocalMediaSource(SAF)', () {
    const saf = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: 'Download',
      url: treeUri,
    );
    const direct = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: '本机存储',
      url: '/storage/emulated/0',
    );

    test('isSafTree 只认 device + content://', () {
      expect(saf.isSafTree, isTrue);
      expect(direct.isSafTree, isFalse);
      expect(
        const LocalMediaSource(
          type: LocalMediaSourceType.webdav,
          name: 'dav',
          url: 'content://x',
        ).isSafTree,
        isFalse,
      );
    });

    test('rootPath: 树根为空串, 收藏的子目录为文档 id', () {
      expect(saf.rootPath, '');
      expect(saf.copyWith(subPath: 'primary:Download/电影').rootPath,
          'primary:Download/电影');
      expect(direct.rootPath, '/storage/emulated/0');
    });

    test('subPath 参与序列化与相等性', () {
      final json = saf.copyWith(subPath: 'primary:Download/电影').toJson();
      expect(json['subPath'], 'primary:Download/电影');
      final restored = LocalMediaSource.fromJson(json);
      expect(restored, saf.copyWith(subPath: 'primary:Download/电影'));
      expect(restored == saf, isFalse);
      // 直读来源不带 subPath, 老数据仍然能读
      expect(LocalMediaSource.fromJson(direct.toJson()), direct);
    });

    test('withCredentials / copyWith 不丢 subPath', () {
      final withSub = saf.copyWith(subPath: 'primary:Download/电影');
      expect(withSub.withCredentials(username: null).subPath,
          'primary:Download/电影');
    });
  });

  group('LocalMediaService(SAF)', () {
    const saf = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: 'Download',
      url: treeUri,
    );
    const video = LocalMediaItem(
      name: 'a.mkv',
      uri: '$treeUri/document/primary%3ADownload%2F%E7%94%B5%E5%BD%B1%2Fa.mkv',
      source: saf,
      remotePath: 'primary:Download/电影/a.mkv',
      size: 1,
    );
    const directVideo = LocalMediaItem(
      name: 'b.mp4',
      uri: '/storage/emulated/0/Movies/b.mp4',
      source: LocalMediaSource(
        type: LocalMediaSourceType.device,
        name: '本机存储',
        url: '/storage/emulated/0',
      ),
    );

    test('isSafSource 走 SAF 分支', () {
      expect(LocalMediaService.isSafSource(saf), isTrue);
      expect(LocalMediaService.isSafSource(directVideo.source), isFalse);
    });

    test('childPath: SAF 用文档 id, 直读用绝对路径', () {
      const dir = LocalMediaItem(
        name: '电影',
        uri: '$treeUri/document/primary%3ADownload%2F%E7%94%B5%E5%BD%B1',
        source: saf,
        remotePath: 'primary:Download/电影',
        isDirectory: true,
      );
      expect(LocalMediaService.childPath(saf, dir), 'primary:Download/电影');
      expect(
        LocalMediaService.childPath(directVideo.source, directVideo),
        '/storage/emulated/0/Movies/b.mp4',
      );
    });

    test('parentDirOf: SAF 返回父文档 id(字幕同名匹配要用)', () {
      expect(
        LocalMediaService.parentDirOf(video),
        'primary:Download/电影',
      );
      expect(
        LocalMediaService.parentDirOf(directVideo),
        '/storage/emulated/0/Movies',
      );
    });

    test('displayPath: SAF 显示可读路径, 网络来源脱敏', () {
      expect(
        LocalMediaService.displayPath(video),
        '内部存储/Download/电影/a.mkv',
      );
      const smb = LocalMediaSource(
        type: LocalMediaSourceType.smb,
        name: 'NAS',
        url: 'smb://NAS/pub',
        username: 'user',
        password: 'secret',
      );
      const smbItem = LocalMediaItem(
        name: 'c.mkv',
        uri: 'smb://user:secret@NAS/pub/c.mkv',
        source: smb,
      );
      expect(
        LocalMediaService.displayPath(smbItem),
        'smb://user:***@NAS/pub/c.mkv',
      );
    });

    test('safLabel: 收藏子目录时显示到子目录', () {
      expect(LocalMediaService.safLabel(saf), '内部存储/Download');
      expect(
        LocalMediaService.safLabel(saf.copyWith(subPath: 'primary:Download/电影')),
        '内部存储/Download/电影',
      );
    });

    test('列表排序: 目录在前, SAF 条目一视同仁', () {
      const dir = LocalMediaItem(
        name: 'zzz目录',
        uri: '$treeUri/document/primary%3Azzz',
        source: saf,
        remotePath: 'primary:zzz目录',
        isDirectory: true,
      );
      final sorted = LocalMediaService.sortItems([video, dir], LocalMediaSort.name);
      expect(sorted.first.isDirectory, isTrue);
    });
  });

  group('LocalMediaController(SAF)', () {
    const saf = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: 'Download',
      url: treeUri,
    );

    test('收藏 SAF 子目录: 记住树 + 文档 id', () {
      final shortcut = LocalMediaController.shortcutFor(
        source: saf,
        path: 'primary:Download/电影',
        title: '电影',
      );
      expect(shortcut, isNotNull);
      expect(shortcut!.url, treeUri);
      expect(shortcut.subPath, 'primary:Download/电影');
      expect(shortcut.name, '电影');
      expect(shortcut.rootPath, 'primary:Download/电影');
    });

    test('就在树根上时不产生收藏(系统授权列表里已经有了)', () {
      expect(
        LocalMediaController.shortcutFor(source: saf, path: '', title: 'Download'),
        isNull,
      );
      expect(
        LocalMediaController.shortcutFor(
          source: saf.copyWith(subPath: 'primary:Download/电影'),
          path: 'primary:Download/电影',
          title: '电影',
        ),
        isNull,
      );
    });

    test('直读路径的收藏仍然是绝对路径', () {
      final shortcut = LocalMediaController.shortcutFor(
        source: const LocalMediaSource(
          type: LocalMediaSourceType.device,
          name: '本机存储',
          url: '/storage/emulated/0',
        ),
        path: '/storage/emulated/0/Movies',
        title: 'Movies',
      );
      expect(shortcut!.url, '/storage/emulated/0/Movies');
      expect(shortcut.subPath, isNull);
      expect(shortcut.isSafTree, isFalse);
    });

    test('存储卷路径 -> SAF 卷 id', () {
      expect(LocalMediaController.volumeIdOf('/storage/emulated/0'), 'primary');
      expect(LocalMediaController.volumeIdOf('/storage/9C33-1234'), '9C33-1234');
      expect(LocalMediaController.volumeIdOf('/data/data'), isNull);
      expect(LocalMediaController.volumeIdOf(''), isNull);
    });
  });
}
