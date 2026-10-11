import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 一次导出的进度(字节数)。[total] 为两路源流大小之和, 合流不转码,
/// 写入量≈源大小, 直接当百分比用足够准。
class ExportProgress {
  const ExportProgress(this.written, this.total);

  final int written;
  final int total;

  double get fraction => total > 0 ? (written / total).clamp(0.0, 1.0) : 0.0;

  String get label => total > 0
      ? '${CacheManager.formatSize(written)} / ${CacheManager.formatSize(total)}'
            '  ${(fraction * 100).toStringAsFixed(0)}%'
      : '准备中…';
}

/// 一条 B 站缓存里解析出来的媒体流文件。
class DownloadMediaFiles {
  const DownloadMediaFiles({
    required this.videoPath,
    this.audioPath,
    required this.isMuxed,
  });

  /// 视频流: Type1 缓存是已合流的 `0.mp4`, Type2(DASH)是 `video.m4s`
  final String videoPath;

  /// 音频流 `audio.m4s`; Type1 / 无音轨缓存为 null
  final String? audioPath;

  /// 视频文件是否已是合流单文件 mp4(导出时直接拷贝, 无需重新封装)
  final bool isMuxed;
}

/// 「导出到本地」: 把 B 站缓存的分离音视频流(video.m4s + audio.m4s)合并成
/// 一个 MP4, 写进系统「下载」目录; Type1 单文件缓存直接拷贝。
///
/// 合并/拷贝都在原生侧完成(见 `MediaMuxExport.kt`):
///   * Android 10+ 走 MediaStore.Downloads, 无需存储权限;
///   * Android 9- 直写 /sdcard/Download, 提前申请 WRITE_EXTERNAL_STORAGE。
abstract final class DownloadExport {
  static const MethodChannel _channel = MethodChannel('piliplus/media_mux');

  /// 导出文件名主体的长度上限(不含扩展名): 中文标题也留足重名后缀余量
  static const int maxBaseNameLength = 60;

  static ValueNotifier<ExportProgress>? _progress;
  static bool _handlerBound = false;

  /// 当前平台能否导出(合流依赖 Android 的 MediaMuxer, 其它端暂不支持)
  static bool get isSupported => Platform.isAndroid;

  // ==================== 入口 ====================

  /// 长按菜单/更多菜单的「导出到本地」。全程自带弹窗与 toast, 调用方一行接入。
  static Future<void> exportEntry(BiliDownloadEntryInfo entry) async {
    if (!isSupported) {
      SmartDialog.showToast('导出到本地暂仅支持安卓端');
      return;
    }
    if (!entry.isCompleted) {
      SmartDialog.showToast('缓存尚未完成, 不能导出');
      return;
    }
    final files = resolveMediaFiles(entry);
    if (files == null) {
      SmartDialog.showToast('未找到缓存文件, 可能已被清理');
      return;
    }
    // 仅 Android 9- 会真正弹权限框, Android 10+ 直接放行(见 ImageUtils)
    if (!await ImageUtils.checkPermissionDependOnSdkInt()) {
      return;
    }

    final displayName = '${sanitizeFileName(buildBaseName(entry))}.mp4';
    _bindProgressHandler();
    final progress = ValueNotifier<ExportProgress>(
      const ExportProgress(0, 0),
    );
    _progress = progress;
    SmartDialog.show(
      builder: (context) => _ExportProgressDialog(notifier: progress),
    );
    String message;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
        'exportToDownloads',
        <String, Object?>{
          'videoPath': files.videoPath,
          'audioPath': files.audioPath,
          'copy': files.isMuxed,
          'displayName': displayName,
        },
      );
      message = switch (raw) {
        {'ok': true, 'name': final String name} when name.isNotEmpty =>
          '已导出到「下载/$name」',
        {'ok': true} => '导出成功',
        {'cancelled': true} => '已取消导出',
        _ => '导出失败',
      };
    } on PlatformException catch (e) {
      message = switch (e.code) {
        'busy' => '已有导出任务在进行, 请稍候再试',
        'need_permission' => '未获得存储权限, 无法写入下载目录',
        'unsupported' => e.message ?? '当前音视频编码不支持导出',
        _ => '导出失败: ${e.message ?? e.code}',
      };
    } on Object catch (e) {
      message = '导出失败: $e';
    }
    // 先关进度弹窗再 dispose notifier: 弹窗里的 ValueListenableBuilder
    // 还监听着它, 先 dispose 后关窗会触发 debug 下的 use-after-dispose 断言
    _progress = null;
    await SmartDialog.dismiss();
    progress.dispose();
    SmartDialog.showToast(message);
  }

  /// 进度弹窗里的「取消」
  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<bool>('cancelExport');
    } on Object {
      // 取消指令没送达也不致命: 合流很快结束, 结果仍由 exportEntry 汇报
    }
  }

  static void _bindProgressHandler() {
    if (_handlerBound) return;
    _handlerBound = true;
    _channel.setMethodCallHandler((call) {
      if (call.method == 'onExportProgress') {
        if (call.arguments case final Map<dynamic, dynamic> args) {
          _progress?.value = ExportProgress(
            (args['written'] as num?)?.toInt() ?? 0,
            (args['total'] as num?)?.toInt() ?? 0,
          );
        }
      }
      return Future.value();
    });
  }

  // ==================== 纯逻辑(可单测) ====================

  /// 从缓存条目解析出待导出的媒体流文件; 找不到完整视频流时返回 null。
  ///
  /// 目录约定见 `DownloadService`: `<entryDir>/<typeTag>/{0.mp4 | video.m4s
  /// + audio.m4s}`。优先按 entry.json 记录的 typeTag 找; 找不到再扫其余
  /// 子目录兜底(typeTag 缺失、目录被搬动过时仍能命中)。
  static DownloadMediaFiles? resolveMediaFiles(BiliDownloadEntryInfo entry) {
    final entryDir = Directory(entry.entryDirPath);
    if (!entryDir.existsSync()) {
      return null;
    }
    final candidates = <String>[];
    if (entry.typeTag case final tag? when tag.isNotEmpty) {
      candidates.add(p.join(entry.entryDirPath, tag));
    }
    try {
      for (final e in entryDir.listSync()) {
        if (e is Directory && !candidates.contains(e.path)) {
          candidates.add(e.path);
        }
      }
    } on Object {
      // 列目录失败不致命: typeTag 目录(如果有)仍会被尝试
    }
    for (final dir in candidates) {
      final mp4 = File(p.join(dir, PathUtils.videoNameType1));
      if (_isUsableFile(mp4)) {
        return DownloadMediaFiles(videoPath: mp4.path, isMuxed: true);
      }
      final video = File(p.join(dir, PathUtils.videoNameType2));
      if (_isUsableFile(video)) {
        final audio = File(p.join(dir, PathUtils.audioNameType2));
        return DownloadMediaFiles(
          videoPath: video.path,
          audioPath: _isUsableFile(audio) ? audio.path : null,
          isMuxed: false,
        );
      }
    }
    return null;
  }

  static bool _isUsableFile(File file) {
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } on Object {
      return false;
    }
  }

  /// 导出文件名(不含扩展名):
  ///   * 单 P 视频: `标题`
  ///   * 多 P 视频: `标题 - 分P名`
  ///   * 番剧/课程: `剧集名 - 第N话 标题`
  /// showTitle 已含标题时不再重复拼接。
  static String buildBaseName(BiliDownloadEntryInfo entry) {
    final show = entry.showTitle;
    final title = entry.title;
    if (title.isEmpty) {
      return show.isEmpty ? 'video' : show;
    }
    if (show.isEmpty || show == title) {
      return title;
    }
    if (show.contains(title)) {
      return show;
    }
    return '$title - $show';
  }

  /// 清洗成安全的文件名: 非法字符换 `_`、折叠连续 `_`、去掉结尾的点/空格
  /// (Windows 对这两者敏感, 拷出去也别扭)、截断超长标题。
  static String sanitizeFileName(String raw) {
    var name = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_')
        .replaceAll(RegExp(r'_{2,}'), '_')
        .trim();
    name = _trimTail(name);
    if (name.runes.length > maxBaseNameLength) {
      // 按码点截断, 不会劈坏代理对(中文/emoji 标题安全)
      name = _trimTail(
        String.fromCharCodes(name.runes.take(maxBaseNameLength)),
      );
    }
    return name.isEmpty ? 'video' : name;
  }

  static String _trimTail(String name) {
    var s = name;
    while (s.endsWith('.') || s.endsWith(' ') || s.endsWith('_')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// 导出进度弹窗(遮罩不可关闭, 只能等完成或点取消)
class _ExportProgressDialog extends StatelessWidget {
  const _ExportProgressDialog({required this.notifier});

  final ValueNotifier<ExportProgress> notifier;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return AlertDialog(
      title: const Text('正在导出到「下载」', style: TextStyle(fontSize: 16)),
      content: ValueListenableBuilder<ExportProgress>(
        valueListenable: notifier,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            LinearProgressIndicator(minHeight: 4, value: value.fraction),
            Text(
              value.label,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const Text(
              '合并音视频流不重新编码; 完成后到系统文件管理器的「下载」目录查看',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: DownloadExport.cancel,
          child: Text(
            '取消',
            style: TextStyle(color: colorScheme.outline, fontSize: 14),
          ),
        ),
      ],
    );
  }
}
