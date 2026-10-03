import 'dart:io';

import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/smb/smb_browse.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「本地」板块服务层的纯函数测试: 地址拼接、脱敏、排序、扩展名白名单,
/// 以及第四轮新增的「添加到快捷方式」(VLC 式书签)的地址推导。
void main() {
  const device = LocalMediaSource(
    type: LocalMediaSourceType.device,
    name: '本机存储',
    url: '/storage/emulated/0',
  );
  const smbHost = LocalMediaSource(
    type: LocalMediaSourceType.smb,
    name: 'NAS',
    url: 'smb://NAS',
    username: 'u',
    password: 'p',
    address: '192.168.1.5',
  );
  const smbShare = LocalMediaSource(
    type: LocalMediaSourceType.smb,
    name: 'pub',
    url: 'smb://NAS/pub',
    username: 'u',
    password: 'p',
  );
  const dav = LocalMediaSource(
    type: LocalMediaSourceType.webdav,
    name: 'dav',
    url: 'https://nas.example.com/dav',
    username: 'u',
    password: 'p',
  );

  group('joinUrl', () {
    test('逐段编码, 中文/空格不会让服务端 404', () {
      expect(
        LocalMediaService.joinUrl('https://h/dav', 'videos/第 1集.mkv'),
        'https://h/dav/videos/%E7%AC%AC%201%E9%9B%86.mkv',
      );
    });

    test('已经编码过的段不会被二次编码成 %25', () {
      expect(
        LocalMediaService.joinUrl('https://h/dav', 'a%20b.mp4'),
        'https://h/dav/a%20b.mp4',
      );
    });

    test('基址末尾有斜杠也不会出现双斜杠', () {
      expect(
        LocalMediaService.joinUrl('https://h/dav/', 'x.mp4'),
        'https://h/dav/x.mp4',
      );
    });
  });

  group('playbackUrl', () {
    test('本机文件直接用绝对路径', () {
      const item = LocalMediaItem(
        name: 'a.mp4',
        uri: '/storage/emulated/0/a.mp4',
        source: device,
      );
      expect(LocalMediaService.playbackUrl(item), '/storage/emulated/0/a.mp4');
    });

    test('网络条目已经是完整 URL 时原样返回', () {
      const item = LocalMediaItem(
        name: 'a.mp4',
        uri: 'http://127.0.0.1:1234/s/token',
        source: smbHost,
      );
      expect(
        LocalMediaService.playbackUrl(item),
        'http://127.0.0.1:1234/s/token',
      );
    });
  });

  group('maskedUrl', () {
    test('密码不外泄', () {
      expect(
        LocalMediaService.maskedUrl('https://u:secret@h/dav/a.mp4'),
        'https://u:***@h/dav/a.mp4',
      );
      expect(LocalMediaService.maskedUrl('/sdcard/a.mp4'), '/sdcard/a.mp4');
      expect(
        LocalMediaService.maskedUrl('smb://NAS/pub/a.mp4'),
        'smb://NAS/pub/a.mp4',
      );
    });
  });

  group('扩展名白名单', () {
    test('只放打包的 FFmpeg 确实能解封装的容器', () {
      expect(LocalMediaExtensions.videos, containsAll(['mp4', 'mkv', 'ts']));
      // rmvb / ogv 没有对应 demuxer, 显示出来也播不了
      expect(LocalMediaExtensions.videos, isNot(contains('rmvb')));
      expect(LocalMediaExtensions.videos, isNot(contains('ogv')));
      // VR 素材常见容器: Insta360 的 .insv 是 mov 家族, 裸 HEVC 流有 demuxer
      expect(LocalMediaExtensions.videos, containsAll(['insv', 'hevc']));
    });

    test('条目类型判定', () {
      LocalMediaItem item(String name) =>
          LocalMediaItem(name: name, uri: name, source: device);
      expect(item('a.MP4').isVideo, isTrue);
      expect(item('a.flac').isAudio, isTrue);
      expect(item('a.srt').isSubtitle, isTrue);
      expect(item('a.srt').isPlayable, isFalse);
      expect(item('a.txt').isPlayable, isFalse);
      expect(item('noext').extension, '');
      expect(
        const LocalMediaItem(
          name: 'dir',
          uri: '/dir',
          source: device,
          isDirectory: true,
        ).isPlayable,
        isFalse,
      );
    });

    test('cid 只由 uri 决定(用于本机续播进度的 key, 不发接口)', () {
      const a = LocalMediaItem(
        name: 'x.mp4',
        uri: 'smb://NAS/pub/x.mp4',
        source: smbShare,
      );
      const b = LocalMediaItem(
        name: '别的名字',
        uri: 'smb://NAS/pub/x.mp4',
        source: smbShare,
      );
      expect(a.cid, b.cid);
      expect(a, b); // 相等性只看 uri
    });
  });

  group('sortItems', () {
    LocalMediaItem item(
      String name, {
      bool dir = false,
      int? size,
      DateTime? modified,
    }) => LocalMediaItem(
      name: name,
      uri: '${dir ? 'd' : 'f'}://$name',
      source: device,
      size: size,
      modified: modified,
      isDirectory: dir,
    );

    test('目录永远在前', () {
      final sorted = LocalMediaService.sortItems(
        [item('b.mp4'), item('aaa', dir: true)],
        LocalMediaSort.name,
      );
      expect(sorted.first.isDirectory, isTrue);
    });

    test('自然排序: 第2集 在 第10集 前面', () {
      final sorted = LocalMediaService.sortItems(
        [item('第10集.mp4'), item('第2集.mp4'), item('第1集.mp4')],
        LocalMediaSort.name,
      );
      expect(
        sorted.map((e) => e.name).toList(),
        ['第1集.mp4', '第2集.mp4', '第10集.mp4'],
      );
    });

    test('按大小/修改时间排序', () {
      final bySize = LocalMediaService.sortItems(
        [item('a', size: 1), item('b', size: 3), item('c', size: 2)],
        LocalMediaSort.size,
      );
      expect(bySize.map((e) => e.name).toList(), ['b', 'c', 'a']);

      final byTime = LocalMediaService.sortItems(
        [
          item('a', modified: DateTime(2020)),
          item('b', modified: DateTime(2024)),
          item('c', modified: DateTime(2022)),
        ],
        LocalMediaSort.modified,
      );
      expect(byTime.map((e) => e.name).toList(), ['b', 'c', 'a']);
    });

    test('不改动传入的列表', () {
      final input = [item('b'), item('a')];
      LocalMediaService.sortItems(input, LocalMediaSort.name);
      expect(input.map((e) => e.name).toList(), ['b', 'a']);
    });
  });

  group('childPath(下钻路径约定)', () {
    test('本机用绝对路径, 网络用服务器相对路径', () {
      const deviceItem = LocalMediaItem(
        name: 'Movies',
        uri: '/storage/emulated/0/Movies',
        source: device,
        isDirectory: true,
      );
      expect(
        LocalMediaService.childPath(device, deviceItem),
        '/storage/emulated/0/Movies',
      );

      // SMB 主机级来源: remotePath 的第一段是共享名
      const shareItem = LocalMediaItem(
        name: 'pub',
        uri: 'smb://NAS/pub',
        source: smbHost,
        remotePath: 'pub',
        isDirectory: true,
      );
      expect(LocalMediaService.childPath(smbHost, shareItem), 'pub');

      const innerItem = LocalMediaItem(
        name: '2024',
        uri: 'smb://NAS/pub/2024',
        source: smbHost,
        remotePath: r'pub\2024',
        isDirectory: true,
      );
      expect(LocalMediaService.childPath(smbHost, innerItem), r'pub\2024');

      // 共享级来源: remotePath 就是共享内路径
      const shareLevelItem = LocalMediaItem(
        name: '2024',
        uri: 'smb://NAS/pub/2024',
        source: smbShare,
        remotePath: '2024',
        isDirectory: true,
      );
      expect(LocalMediaService.childPath(smbShare, shareLevelItem), '2024');
    });
  });

  group('shortcutFor(添加到快捷方式)', () {
    test('本机目录: url 就是绝对路径', () {
      final s = LocalMediaController.shortcutFor(
        source: device,
        path: '/storage/emulated/0/Movies',
        title: 'Movies',
      );
      expect(s, isNotNull);
      expect(s!.type, LocalMediaSourceType.device);
      expect(s.name, 'Movies');
      expect(s.url, '/storage/emulated/0/Movies');
    });

    test('主机级 SMB: 路径第一段是共享名, 凭据与兜底 IP 一起带上', () {
      final s = LocalMediaController.shortcutFor(
        source: smbHost,
        path: r'pub\videos',
        title: 'videos',
      );
      expect(s!.url, 'smb://NAS/pub/videos');
      expect(s.username, 'u');
      expect(s.password, 'p');
      expect(s.address, '192.168.1.5');
    });

    test('主机级 SMB 在主机根上没有可收藏的目录', () {
      expect(
        LocalMediaController.shortcutFor(
          source: smbHost,
          path: '',
          title: 'NAS',
        ),
        isNull,
      );
    });

    test('共享级 SMB: 共享名来自来源, 路径是共享内相对路径', () {
      final s = LocalMediaController.shortcutFor(
        source: smbShare,
        path: r'videos\2024',
        title: '2024',
      );
      expect(s!.url, 'smb://NAS/pub/videos/2024');
    });

    test('WebDAV: 基址 + 路径', () {
      final s = LocalMediaController.shortcutFor(
        source: dav,
        path: '/videos',
        title: 'videos',
      );
      expect(s!.url, 'https://nas.example.com/dav/videos');
      expect(s.username, 'u');
    });

    test('直链来源与来源根目录不可收藏', () {
      const http = LocalMediaSource(
        type: LocalMediaSourceType.http,
        name: 'h',
        url: 'http://a/b.mp4',
      );
      expect(
        LocalMediaController.shortcutFor(source: http, path: '', title: 'h'),
        isNull,
      );
      expect(
        LocalMediaController.shortcutFor(source: dav, path: '/', title: 'dav'),
        isNull,
      );
    });

    test('标题为空时退回来源名', () {
      final s = LocalMediaController.shortcutFor(
        source: device,
        path: '/storage/emulated/0/Movies',
        title: '',
      );
      expect(s!.name, device.name);
    });
  });

  group('外置字幕同名匹配', () {
    test('baseNameOf 去扩展名', () {
      expect(LocalMediaService.baseNameOf('movie.mkv'), 'movie');
      expect(LocalMediaService.baseNameOf('movie.zh-CN.srt'), 'movie.zh-CN');
      expect(LocalMediaService.baseNameOf('noext'), 'noext');
      expect(LocalMediaService.baseNameOf('.hidden'), '.hidden');
    });

    test('parentDirOf: 三种来源的路径约定', () {
      LocalMediaItem item(LocalMediaSource src, String uri, String? remote) =>
          LocalMediaItem(
            name: 'a.mkv',
            uri: uri,
            source: src,
            remotePath: remote,
          );
      expect(
        LocalMediaService.parentDirOf(
          item(device, '/storage/emulated/0/Movies/a.mkv', null),
        ),
        '/storage/emulated/0/Movies',
      );
      // SMB 主机级: remotePath 以共享名打头
      expect(
        LocalMediaService.parentDirOf(
          item(smbHost, 'smb://NAS/pub/2024/a.mkv', r'pub\2024\a.mkv'),
        ),
        r'pub\2024',
      );
      // SMB 共享级: remotePath 是共享内路径, 根上就是空串
      expect(
        LocalMediaService.parentDirOf(
          item(smbShare, 'smb://NAS/pub/a.mkv', 'a.mkv'),
        ),
        '',
      );
      expect(
        LocalMediaService.parentDirOf(
          item(dav, 'https://h/dav/v/a.mkv', '/v/a.mkv'),
        ),
        '/v',
      );
      // 直链来源没有目录可列
      const http = LocalMediaSource(
        type: LocalMediaSourceType.http,
        name: 'h',
        url: 'http://a/b.mp4',
      );
      expect(
        LocalMediaService.parentDirOf(item(http, 'http://a/b.mp4', null)),
        isNull,
      );
    });

    test('真实目录: 同名与 同名.语言 都能匹配, 别的视频的字幕不会串', () async {
      final dir = Directory.systemTemp.createTempSync('pili_sub_test');
      try {
        for (final name in [
          'movie.mkv',
          'movie.srt',
          'movie.zh-CN.ass',
          'movie.chs.srt',
          'other.srt',
          'movie.txt',
          'MOVIE2.SRT',
        ]) {
          File('${dir.path}/$name').writeAsStringSync('x');
        }
        final source = LocalMediaSource(
          type: LocalMediaSourceType.device,
          name: 'tmp',
          url: dir.path,
        );
        final video = LocalMediaItem(
          name: 'movie.mkv',
          uri: '${dir.path}/movie.mkv',
          source: source,
        );
        final found = await LocalMediaService.findMatchingSubtitles(video);
        // 主名完全相同的排最前, 其后是 movie.<后缀>.xxx
        expect(found.map((e) => e.name).toList(), [
          'movie.srt',
          'movie.chs.srt',
          'movie.zh-CN.ass',
        ]);
        // other.srt / movie.txt / MOVIE2.SRT 都不该被选中
        expect(found.any((e) => e.name == 'other.srt'), isFalse);
        expect(found.any((e) => e.name == 'movie.txt'), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('目录读不到时返回空, 不抛异常(不能因为找字幕影响播放)', () async {
      const source = LocalMediaSource(
        type: LocalMediaSourceType.device,
        name: 'missing',
        url: '/nonexistent-dir-xyz',
      );
      const video = LocalMediaItem(
        name: 'a.mkv',
        uri: '/nonexistent-dir-xyz/a.mkv',
        source: source,
      );
      expect(await LocalMediaService.findMatchingSubtitles(video), isEmpty);
    });
  });

  group('SmbBrowse.directUrl(smb:// 直连, 定制 libmpv 的 ffmpeg libsmb2 协议)', () {
    test('匿名 + 默认端口: 无凭据段无端口, 反斜杠路径转 URL 段', () {
      expect(
        SmbBrowse.directUrl(
          host: 'NAS',
          share: 'video',
          remotePath: r'VR\360.mp4',
        ),
        'smb://NAS/video/VR/360.mp4',
      );
    });

    test('账号/密码/域名百分号编码, 特殊字符不破坏 URL 结构', () {
      expect(
        SmbBrowse.directUrl(
          host: 'NAS',
          share: 'video',
          remotePath: '第 1集/a+b.mp4',
          user: 'us;er@x',
          password: 'p@ss:word/1',
          domain: 'WORK;GROUP',
        ),
        'smb://WORK%3BGROUP;us%3Ber%40x:p%40ss%3Aword%2F1@NAS/video/'
        '%E7%AC%AC%201%E9%9B%86/a%2Bb.mp4',
      );
    });

    test('非默认端口保留; 发现记录的 IP 优先于主机名', () {
      expect(
        SmbBrowse.directUrl(
          host: 'NAS',
          port: 1445,
          share: 'pub',
          remotePath: 'x.mkv',
          address: '192.168.1.5',
        ),
        'smb://192.168.1.5:1445/pub/x.mkv',
      );
    });

    test('IPv6 字面量加方括号(libsmb2 支持 [v6]:port)', () {
      expect(
        SmbBrowse.directUrl(host: 'fe80::1', share: 'pub', remotePath: 'x.mkv'),
        'smb://[fe80::1]/pub/x.mkv',
      );
    });
  });

  group('uniqueFilePath(下载重名不覆盖)', () {
    test('已存在就加 (1)/(2) 后缀', () {
      final dir = Directory.systemTemp.createTempSync('pili_dl_test');
      try {
        expect(
          LocalMediaService.uniqueFilePath(dir.path, 'a.mp4'),
          '${dir.path}/a.mp4',
        );
        File('${dir.path}/a.mp4').writeAsStringSync('x');
        expect(
          LocalMediaService.uniqueFilePath(dir.path, 'a.mp4'),
          '${dir.path}/a (1).mp4',
        );
        File('${dir.path}/a (1).mp4').writeAsStringSync('x');
        expect(
          LocalMediaService.uniqueFilePath(dir.path, 'a.mp4'),
          '${dir.path}/a (2).mp4',
        );
        // 没有扩展名也要能处理
        File('${dir.path}/noext').writeAsStringSync('x');
        expect(
          LocalMediaService.uniqueFilePath(dir.path, 'noext'),
          '${dir.path}/noext (1)',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
