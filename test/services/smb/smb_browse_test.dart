import 'package:PiliPlus/services/smb/local_media_proxy.dart';
import 'package:PiliPlus/services/smb/smb_browse.dart';
import 'package:flutter_test/flutter_test.dart';

/// SMB 路径/URI 纯函数回归测试。
///
/// 第四轮把"主机"变成了一级目录(`smb://NAS` 不带共享名), 路径的第一段就是
/// 共享名, 这些约定必须有测试兜住, 否则很容易再次出现
/// `\\host\pub\pub` 这类"多套一层共享名"的错。
void main() {
  group('SmbBrowse.normalizePath', () {
    test('正斜杠转正斜杠为反斜杠并去掉首尾分隔符', () {
      expect(SmbBrowse.normalizePath('/videos/2024/'), r'videos\2024');
      expect(SmbBrowse.normalizePath(r'videos\2024'), r'videos\2024');
      expect(SmbBrowse.normalizePath(r'\\videos\\2024\\'), r'videos\2024');
      expect(SmbBrowse.normalizePath(''), '');
      expect(SmbBrowse.normalizePath('/'), '');
    });
  });

  group('SmbBrowse.splitSharePath', () {
    test('空路径 = 主机根(列共享)', () {
      expect(SmbBrowse.splitSharePath(''), ('', ''));
      expect(SmbBrowse.splitSharePath('/'), ('', ''));
    });

    test('第一段是共享名', () {
      expect(SmbBrowse.splitSharePath('pub'), ('pub', ''));
      expect(SmbBrowse.splitSharePath('pub/'), ('pub', ''));
      expect(SmbBrowse.splitSharePath(r'pub\videos'), ('pub', r'videos'));
      expect(
        SmbBrowse.splitSharePath('pub/videos/2024'),
        ('pub', r'videos\2024'),
      );
    });
  });

  group('SmbBrowse.uri', () {
    test('默认端口不写出来, 非默认端口要写', () {
      expect(
        SmbBrowse.uri(host: 'NAS', share: 'pub', remotePath: r'a\b.mp4'),
        'smb://NAS/pub/a/b.mp4',
      );
      expect(
        SmbBrowse.uri(host: 'NAS', port: 1445, share: 'pub', remotePath: ''),
        'smb://NAS:1445/pub',
      );
    });

    test('中文与空格逐段编码, 反斜杠换成正斜杠', () {
      expect(
        SmbBrowse.uri(host: 'NAS', share: '影片', remotePath: r'第 1集.mkv'),
        'smb://NAS/%E5%BD%B1%E7%89%87/%E7%AC%AC%201%E9%9B%86.mkv',
      );
    });
  });

  group('SmbBrowse.hostUri', () {
    test('主机级地址不带共享名', () {
      expect(SmbBrowse.hostUri(host: 'NAS'), 'smb://NAS');
      expect(
        SmbBrowse.hostUri(host: '192.168.1.5', port: 1445),
        'smb://192.168.1.5:1445',
      );
    });
  });

  group('SmbBrowse.parseEndpoint', () {
    test('共享 + 子路径', () {
      final ep = SmbBrowse.parseEndpoint('smb://NAS/pub/videos/a.mkv');
      expect(ep, isNotNull);
      // Dart 的 Uri.host 会按 RFC 3986 规范化成小写; 连接不受影响
      // (DNS/NetBIOS 都大小写不敏感), 需要保留原样的地方走
      // LocalMediaSource.rawHostOf
      expect(ep!.host, 'nas');
      expect(ep.port, 445);
      expect(ep.share, 'pub');
      expect(ep.path, r'videos\a.mkv');
    });

    test('主机级地址(没有共享名)解析不出来, 由 isSmbHostRoot 判定', () {
      expect(SmbBrowse.parseEndpoint('smb://NAS'), isNull);
      expect(SmbBrowse.parseEndpoint('smb://NAS/'), isNull);
    });

    test('显式端口与百分号编码', () {
      final ep = SmbBrowse.parseEndpoint('smb://NAS:1445/%E5%BD%B1%E7%89%87/x');
      expect(ep!.port, 1445);
      expect(ep.share, '影片');
      expect(ep.path, 'x');
    });

    test('非法地址返回 null 而不是抛异常', () {
      expect(SmbBrowse.parseEndpoint(''), isNull);
      expect(SmbBrowse.parseEndpoint('smb://'), isNull);
      expect(SmbBrowse.parseEndpoint('smb:///only-share'), isNull);
    });

    test('uri 与 parseEndpoint 往返一致(主机名除大小写外不变)', () {
      const share = '影片 库';
      const remote = r'剧集\第 1集.mkv';
      final url = SmbBrowse.uri(host: 'NAS', share: share, remotePath: remote);
      expect(url, 'smb://NAS/%E5%BD%B1%E7%89%87%20%E5%BA%93/'
          '%E5%89%A7%E9%9B%86/%E7%AC%AC%201%E9%9B%86.mkv');
      final ep = SmbBrowse.parseEndpoint(url)!;
      expect(ep.host.toLowerCase(), 'nas');
      expect(ep.share, share);
      expect(ep.path, remote);
    });
  });

  group('LocalMediaProxy.parseRange', () {
    test('无 Range 头返回整个文件', () {
      expect(LocalMediaProxy.parseRange(null, 100), (0, 99));
      expect(LocalMediaProxy.parseRange('items=0-1', 100), (0, 99));
    });

    test('常规区间(闭区间)', () {
      expect(LocalMediaProxy.parseRange('bytes=0-99', 1000), (0, 99));
      expect(LocalMediaProxy.parseRange('bytes=500-', 1000), (500, 999));
      expect(LocalMediaProxy.parseRange('bytes=10-20', 1000), (10, 20));
    });

    test('后缀区间 bytes=-N', () {
      expect(LocalMediaProxy.parseRange('bytes=-100', 1000), (900, 999));
      expect(LocalMediaProxy.parseRange('bytes=-2000', 1000), (0, 999));
    });

    test('越界/非法输入退化成整个文件, 不抛异常', () {
      expect(LocalMediaProxy.parseRange('bytes=2000-3000', 1000), (0, 999));
      expect(LocalMediaProxy.parseRange('bytes=abc', 1000), (0, 999));
      expect(LocalMediaProxy.parseRange('bytes=20-10', 1000), (20, 20));
      expect(LocalMediaProxy.parseRange('bytes=0-10', 0), (0, -1));
    });
  });
}
