import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/export_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 「导出到本地」纯逻辑回归测试 —— 第二十七轮。
///
/// 合流本身(MediaExtractor/MediaMuxer)在原生侧, 沙盒与 CI 的 flutter test
/// 都碰不到; 这里钉死 Dart 侧三块可单测的逻辑:
///   * buildBaseName  —— 导出文件名的拼接规则(单P/多P/番剧);
///   * sanitizeFileName —— 非法字符/超长标题/空标题的清洗;
///   * resolveMediaFiles —— 从缓存目录认出 0.mp4 / video.m4s+audio.m4s,
///     以及 typeTag 缺失、文件损坏(0 字节)时的兜底行为。
BiliDownloadEntryInfo buildEntry({
  String title = '测试标题',
  PageInfo? pageData,
  EpInfo? ep,
  String? typeTag = '80',
  bool isCompleted = true,
  String entryDirPath = '/nonexistent-dir',
}) =>
    BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: true,
      isCompleted: isCompleted,
      totalBytes: 1,
      downloadedBytes: 1,
      title: title,
      typeTag: typeTag,
      cover: '',
      preferedVideoQuality: 80,
      guessedTotalBytes: 0,
      totalTimeMilli: 0,
      danmakuCount: 0,
      avid: 1,
      bvid: 'BV1xx411c7mD',
      pageData: pageData,
      ep: ep,
    )..entryDirPath = entryDirPath;

PageInfo buildPage({int cid = 1, int page = 1, String? part}) => PageInfo(
  cid: cid,
  page: page,
  part: part,
  hasAlias: false,
  tid: 0,
);

EpInfo buildEp({String index = '1', String indexTitle = '启程', String? showTitle}) =>
    EpInfo(
      avId: 1,
      page: 1,
      danmaku: 1,
      cover: '',
      episodeId: 100,
      index: index,
      indexTitle: indexTitle,
      showTitle: showTitle,
      from: 'bangumi',
      seasonType: 1,
      width: 1920,
      height: 1080,
      rotate: 0,
    );

void main() {
  group('buildBaseName 导出文件名拼接', () {
    test('单 P 视频: part 与标题相同, 只用标题', () {
      final entry = buildEntry(
        title: '某视频',
        pageData: buildPage(part: '某视频'),
      );
      expect(DownloadExport.buildBaseName(entry), '某视频');
    });

    test('单 P 视频: part 缺失/为空时回退标题', () {
      expect(
        DownloadExport.buildBaseName(buildEntry(pageData: buildPage())),
        '测试标题',
      );
      expect(
        DownloadExport.buildBaseName(
          buildEntry(pageData: buildPage(part: '')),
        ),
        '测试标题',
      );
    });

    test('多 P 视频: 标题 - 分P名', () {
      final entry = buildEntry(
        title: '某视频',
        pageData: buildPage(page: 2, part: 'P2 精彩片段'),
      );
      expect(DownloadExport.buildBaseName(entry), '某视频 - P2 精彩片段');
    });

    test('showTitle 已含标题时不重复拼接', () {
      final entry = buildEntry(
        title: 'ABC',
        pageData: buildPage(part: 'ABC 重制版'),
      );
      expect(DownloadExport.buildBaseName(entry), 'ABC 重制版');
    });

    test('番剧: 剧集名 - 话号 标题', () {
      final entry = buildEntry(title: '某番剧', ep: buildEp());
      expect(DownloadExport.buildBaseName(entry), '某番剧 - 1 启程');
    });

    test('番剧: API 给了 showTitle 就优先用', () {
      final entry = buildEntry(
        title: '某番剧',
        ep: buildEp(showTitle: '第1话 启程'),
      );
      expect(DownloadExport.buildBaseName(entry), '某番剧 - 第1话 启程');
    });

    test('标题为空: 回退 showTitle, 再空回退 video', () {
      expect(
        DownloadExport.buildBaseName(
          buildEntry(title: '', pageData: buildPage(part: '分P名')),
        ),
        '分P名',
      );
      expect(DownloadExport.buildBaseName(buildEntry(title: '')), 'video');
    });
  });

  group('sanitizeFileName 文件名清洗', () {
    test('文件系统非法字符换成下划线', () {
      expect(
        DownloadExport.sanitizeFileName(r'a\b/c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
    });

    test('控制字符也换掉, 连续下划线折叠', () {
      expect(DownloadExport.sanitizeFileName('a\u0001b//c'), 'a_b_c');
    });

    test('结尾的点/空格/下划线去掉(Windows 敏感)', () {
      expect(DownloadExport.sanitizeFileName('title...'), 'title');
      expect(DownloadExport.sanitizeFileName('title  '), 'title');
      expect(DownloadExport.sanitizeFileName('title___'), 'title');
    });

    test('空串与全非法字符回退 video', () {
      expect(DownloadExport.sanitizeFileName(''), 'video');
      expect(DownloadExport.sanitizeFileName('***'), 'video');
    });

    test('超长标题按码点截到 ${DownloadExport.maxBaseNameLength} 个字符', () {
      expect(
        DownloadExport.sanitizeFileName('a' * 100).length,
        DownloadExport.maxBaseNameLength,
      );
      final cjk = '很长' * 40; // 80 个汉字
      expect(
        DownloadExport.sanitizeFileName(cjk).runes.length,
        DownloadExport.maxBaseNameLength,
      );
    });

    test('正常中文标题原样保留', () {
      expect(
        DownloadExport.sanitizeFileName('【4K】某视频 正片'),
        '【4K】某视频 正片',
      );
    });
  });

  group('ExportProgress', () {
    test('fraction 按比例且截断到 [0,1]', () {
      expect(const ExportProgress(50, 100).fraction, 0.5);
      expect(const ExportProgress(150, 100).fraction, 1.0);
      expect(const ExportProgress(0, 0).fraction, 0.0);
    });

    test('label: 未知总量显示准备中, 有总量显示百分比', () {
      expect(const ExportProgress(0, 0).label, '准备中…');
      expect(const ExportProgress(50, 100).label, contains('50%'));
    });
  });

  group('resolveMediaFiles 缓存目录解析', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('pili_export_test');
    });

    tearDown(() async {
      if (root.existsSync()) {
        await root.delete(recursive: true);
      }
    });

    File touch(String dirName, String fileName, {String content = 'x'}) {
      final dir = Directory(p.join(root.path, dirName))..createSync(recursive: true);
      return File(p.join(dir.path, fileName))..writeAsStringSync(content);
    }

    test('Type2(DASH): 认出 video.m4s + audio.m4s', () {
      touch('80', PathUtils.videoNameType2);
      touch('80', PathUtils.audioNameType2);
      final files = DownloadExport.resolveMediaFiles(
        buildEntry(entryDirPath: root.path, typeTag: '80'),
      );
      expect(files, isNotNull);
      expect(files!.isMuxed, isFalse);
      expect(files.videoPath, endsWith(p.join('80', PathUtils.videoNameType2)));
      expect(files.audioPath, endsWith(p.join('80', PathUtils.audioNameType2)));
    });

    test('Type2: 音频流缺失/0 字节时 audioPath 为 null', () {
      touch('80', PathUtils.videoNameType2);
      touch('80', PathUtils.audioNameType2, content: '');
      final files = DownloadExport.resolveMediaFiles(
        buildEntry(entryDirPath: root.path, typeTag: '80'),
      );
      expect(files, isNotNull);
      expect(files!.audioPath, isNull);
      expect(files.isMuxed, isFalse);
    });

    test('Type1: 认出 0.mp4, 且优先于同目录的 m4s', () {
      touch('64', PathUtils.videoNameType1);
      touch('64', PathUtils.videoNameType2);
      final files = DownloadExport.resolveMediaFiles(
        buildEntry(entryDirPath: root.path, typeTag: '64'),
      );
      expect(files, isNotNull);
      expect(files!.isMuxed, isTrue);
      expect(files.audioPath, isNull);
      expect(files.videoPath, endsWith(p.join('64', PathUtils.videoNameType1)));
    });

    test('typeTag 缺失时扫描子目录兜底', () {
      touch('127', PathUtils.videoNameType2);
      touch('127', PathUtils.audioNameType2);
      final files = DownloadExport.resolveMediaFiles(
        buildEntry(entryDirPath: root.path, typeTag: null),
      );
      expect(files, isNotNull);
      expect(files!.videoPath, endsWith(p.join('127', PathUtils.videoNameType2)));
    });

    test('typeTag 指向不存在的目录时, 仍能扫到实际目录', () {
      touch('80', PathUtils.videoNameType2);
      final files = DownloadExport.resolveMediaFiles(
        buildEntry(entryDirPath: root.path, typeTag: '16'),
      );
      expect(files, isNotNull);
      expect(files!.videoPath, endsWith(p.join('80', PathUtils.videoNameType2)));
    });

    test('目录不存在 / 没有可用视频流 → null', () {
      expect(
        DownloadExport.resolveMediaFiles(buildEntry()),
        isNull,
        reason: 'entryDirPath 不存在',
      );
      touch('80', PathUtils.videoNameType2, content: '');
      expect(
        DownloadExport.resolveMediaFiles(
          buildEntry(entryDirPath: root.path, typeTag: '80'),
        ),
        isNull,
        reason: '0 字节的 video.m4s 不算可用',
      );
    });

    test('entry.json / cover 等杂项文件不会被误认成媒体流', () {
      touch('', 'entry.json');
      touch('', PathUtils.coverName);
      expect(
        DownloadExport.resolveMediaFiles(
          buildEntry(entryDirPath: root.path, typeTag: null),
        ),
        isNull,
      );
    });
  });
}
