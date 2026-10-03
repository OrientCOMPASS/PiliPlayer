import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// [LocalMediaSource] 的地址解析回归测试。
///
/// 这里出过两次真机事故, 都必须有测试兜住:
///   * 第三轮: SMB 的 `rootPath` 返回 `/共享名`, 浏览器又在共享里找一层同名
///     目录, 打开手填的共享必然 OBJECT_NAME_NOT_FOUND;
///   * 第四轮: 新增**主机级**来源 `smb://NAS`(不带共享名), 主机本身是一级
///     目录, 共享是它的子目录 —— `smbEndpoint` 必须返回 null,
///     `isSmbHostRoot` 必须为 true, 否则服务层会走错分支。
void main() {
  group('本机来源', () {
    const source = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: '本机存储',
      url: '/storage/emulated/0',
    );

    test('rootPath 就是绝对路径', () {
      expect(source.rootPath, '/storage/emulated/0');
      expect(source.canBrowse, isTrue);
      expect(source.type.isNetwork, isFalse);
      expect(source.type.needsProxy, isFalse);
    });

    test('playbackBase 原样返回', () {
      expect(source.playbackBase, '/storage/emulated/0');
    });
  });

  group('SMB 主机级来源', () {
    const source = LocalMediaSource(
      type: LocalMediaSourceType.smb,
      name: 'NAS',
      url: 'smb://NAS',
      address: '192.168.1.5',
    );

    test('没有共享名 => smbEndpoint 为 null, isSmbHostRoot 为 true', () {
      expect(source.smbEndpoint, isNull);
      expect(source.isSmbHostRoot, isTrue);
      expect(source.smbHost, (host: 'NAS', port: 445));
    });

    test('rootPath 为空串(服务层解释为"列共享")', () {
      expect(source.rootPath, '');
      expect(source.canBrowse, isTrue);
      expect(source.type.needsProxy, isTrue);
    });

    test('带斜杠/带端口也算主机级', () {
      const a = LocalMediaSource(
        type: LocalMediaSourceType.smb,
        name: 'NAS',
        url: 'smb://NAS/',
      );
      expect(a.isSmbHostRoot, isTrue);
      const b = LocalMediaSource(
        type: LocalMediaSourceType.smb,
        name: 'NAS',
        url: 'smb://NAS:1445',
      );
      expect(b.isSmbHostRoot, isTrue);
      expect(b.smbHost, (host: 'NAS', port: 1445));
    });
  });

  group('SMB 共享级来源', () {
    const source = LocalMediaSource(
      type: LocalMediaSourceType.smb,
      name: 'pub',
      url: 'smb://NAS/pub/videos',
      username: 'user',
      password: 'pass',
      domain: 'WORKGROUP',
    );

    test('endpoint 拆出共享名与共享内路径', () {
      final ep = source.smbEndpoint;
      expect(ep, isNotNull);
      expect(ep!.host, 'NAS');
      expect(ep.port, 445);
      expect(ep.share, 'pub');
      expect(ep.path, r'videos');
      expect(source.isSmbHostRoot, isFalse);
    });

    test('rootPath 只能是共享内的相对路径(第三轮 bug 的回归)', () {
      expect(source.rootPath, 'videos');
      expect(source.rootPath, isNot('/pub'));
      expect(source.rootPath, isNot('pub'));
    });

    test('只写到共享名时 rootPath 为空', () {
      const only = LocalMediaSource(
        type: LocalMediaSourceType.smb,
        name: 'pub',
        url: 'smb://NAS/pub',
      );
      expect(only.rootPath, '');
      expect(only.isSmbHostRoot, isFalse);
      expect(only.smbEndpoint!.share, 'pub');
    });
  });

  group('凭据与展示', () {
    test('WebDAV 把账号写进 userinfo', () {
      const source = LocalMediaSource(
        type: LocalMediaSourceType.webdav,
        name: 'dav',
        url: 'https://nas.example.com:5006/dav',
        username: 'u s',
        password: 'p@ss',
      );
      expect(source.hasCredential, isTrue);
      expect(
        source.playbackBase,
        'https://u%20s:p%40ss@nas.example.com:5006/dav',
      );
    });

    test('默认端口不会被写进 playbackBase', () {
      const source = LocalMediaSource(
        type: LocalMediaSourceType.webdav,
        name: 'dav',
        url: 'https://nas.example.com/dav',
        username: 'u',
        password: 'p',
      );
      expect(source.playbackBase, 'https://u:p@nas.example.com/dav');
    });

    test('没有凭据时原样返回', () {
      const source = LocalMediaSource(
        type: LocalMediaSourceType.http,
        name: 'h',
        url: 'http://a/b.mp4',
      );
      expect(source.hasCredential, isFalse);
      expect(source.playbackBase, 'http://a/b.mp4');
      expect(source.canBrowse, isFalse);
      expect(source.type.needsProxy, isFalse);
    });
  });

  group('序列化', () {
    test('toJson / fromJson 往返保留全部字段', () {
      const source = LocalMediaSource(
        type: LocalMediaSourceType.smb,
        name: 'NAS',
        url: 'smb://NAS',
        username: 'u',
        password: 'p',
        domain: 'WG',
        address: '192.168.1.5',
      );
      final back = LocalMediaSource.fromJson(source.toJson());
      expect(back, source);
      expect(back!.address, '192.168.1.5');
      expect(back.domain, 'WG');
    });

    test('非法 json 返回 null 而不是抛异常', () {
      expect(LocalMediaSource.fromJson(null), isNull);
      expect(LocalMediaSource.fromJson('x'), isNull);
      expect(LocalMediaSource.fromJson({'type': 99, 'url': 'a'}), isNull);
      expect(LocalMediaSource.fromJson({'type': 0}), isNull);
    });

    test('copyWith 只改指定字段; 相等性不看 address', () {
      const source = LocalMediaSource(
        type: LocalMediaSourceType.smb,
        name: 'NAS',
        url: 'smb://NAS',
      );
      final withCreds = source.copyWith(username: 'u', password: 'p');
      expect(withCreds.url, source.url);
      expect(withCreds.name, source.name);
      expect(withCreds.username, 'u');
      // address 只是解析兜底, 不参与相等性(否则换网后同一条来源会重复保存)
      expect(source.copyWith(address: '10.0.0.1'), source);
    });
  });

  group('rawHostOf(保留主机名原始大小写)', () {
    test('Uri.host 会把主机名小写, 这里必须保留原样', () {
      // 回归: Dart 的 Uri.parse('smb://NAS/pub').host == 'nas',
      // 于是收藏/展示的地址会变成 smb://nas, 与发现阶段拿到的
      // 大写 NetBIOS 名对不上(同一台主机被认成两台)
      expect(Uri.parse('smb://NAS/pub').host, 'nas');
      expect(LocalMediaSource.rawHostOf('smb://NAS/pub'), 'NAS');
    });

    test('带端口/userinfo/路径/查询/片段', () {
      expect(LocalMediaSource.rawHostOf('smb://MyNAS:1445/pub'), 'MyNAS');
      expect(LocalMediaSource.rawHostOf('smb://u:p@MyNAS/pub'), 'MyNAS');
      expect(LocalMediaSource.rawHostOf('https://U:P@MyNAS/x?a=1#f'), 'MyNAS');
      expect(LocalMediaSource.rawHostOf('smb://MyNAS'), 'MyNAS');
    });

    test('IPv6 字面量里的冒号不是端口分隔符', () {
      expect(LocalMediaSource.rawHostOf('smb://[fe80::1]:445/x'), '[fe80::1]');
    });

    test('非法输入返回 null', () {
      expect(LocalMediaSource.rawHostOf('smb://'), null);
      expect(LocalMediaSource.rawHostOf('/storage/emulated/0'), null);
      expect(LocalMediaSource.rawHostOf('smb:///share'), null);
    });
  });

  group('defaultPortFor', () {
    test('常见协议', () {
      expect(LocalMediaSource.defaultPortFor('http'), 80);
      expect(LocalMediaSource.defaultPortFor('HTTPS'), 443);
      expect(LocalMediaSource.defaultPortFor('ftp'), 21);
      expect(LocalMediaSource.defaultPortFor('rtsp'), 554);
      expect(LocalMediaSource.defaultPortFor('smb'), 0);
    });
  });
}
