import 'dart:async' show unawaited;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/browser.dart';
import 'package:PiliPlus/pages/local_media/widgets/smb_dialogs.dart';
import 'package:PiliPlus/pages/local_media/widgets/source_editor.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/smb/smb2_client.dart';
import 'package:PiliPlus/services/smb/smb_browse.dart';
import 'package:PiliPlus/services/smb/smb_discovery.dart';
import 'package:PiliPlus/services/smb/smb_name.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块控制器(第十八轮改版): 不再做全盘扫描的"媒体库",
/// 只负责 本机存储卷入口 + 用户收藏的快捷方式 + 局域网主机发现/来源管理。
class LocalMediaController extends GetxController {
  /// 本机存储卷(主存储 + SD 卡/U 盘)
  final RxList<LocalMediaSource> deviceSources = <LocalMediaSource>[].obs;

  /// 用户添加的网络共享(SMB / WebDAV / HTTP / FTP)
  final RxList<LocalMediaSource> savedSources = <LocalMediaSource>[].obs;

  /// 自动发现的 SMB 主机
  final RxList<SmbHost> discovered = <SmbHost>[].obs;

  /// 用户**主动收藏**的快捷方式(本机路径与网络来源混排)。
  /// 连接过的主机只存凭据(favorite=false), 不再出现在列表里刷屏。
  List<LocalMediaSource> get favoriteSources => [
    for (final s in savedSources)
      if (s.favorite) s,
  ];

  final RxBool scanningNetwork = false.obs;
  final RxInt scanDone = 0.obs;
  final RxInt scanTotal = 0.obs;
  final RxnString networkError = RxnString();

  /// 安卓 14+「选择照片和视频」部分访问的提示文案; null 表示权限正常。
  /// 部分访问下未勾选的文件对应用完全不可见, 用户会误以为"列表过滤了
  /// 我的文件"(第十三轮真机反馈), 必须明确提示。
  final RxnString accessNotice = RxnString();

  @override
  void onInit() {
    super.onInit();
    savedSources.value = LocalMediaService.loadSources();
    refreshDevices();
    refreshAccessNotice();
  }

  Future<void> refreshDevices() async {
    deviceSources.value = await LocalMediaService.deviceSources();
  }

  /// 刷新"部分访问"权限提示(只探测状态, 不弹授权框)
  Future<void> refreshAccessNotice() async {
    accessNotice.value = await LocalMediaService.deviceAccessLimited()
        ? '当前只有「部分访问」照片和视频的权限, 未勾选的文件不会出现在列表里。'
        : null;
  }

  /// 板块重新可见(应用回前台)时调用: 刷新存储卷与权限提示
  void onResumed() {
    refreshDevices();
    refreshAccessNotice();
  }

  /// 扫描局域网里开着 SMB(445) 端口的主机
  Future<void> discoverNetwork() async {
    if (scanningNetwork.value) {
      return;
    }
    scanningNetwork.value = true;
    networkError.value = null;
    scanDone.value = 0;
    scanTotal.value = 0;
    try {
      final hosts = await SmbDiscovery.scan(
        onProgress: (done, total) {
          scanDone.value = done;
          scanTotal.value = total;
        },
      );
      discovered.value = hosts;
      if (hosts.isEmpty) {
        networkError.value =
            '没有发现开启 SMB(445) 的主机。请确认与 NAS/电脑在同一局域网，'
            '或手动添加共享地址。';
      } else {
        // 尽力补主机名(第十八轮: 能展示主机名尽量展示): NBNS 被拦时
        // 发现阶段只有 IP, 这里逐台做一次匿名 SMB2 握手 —— NTLM
        // CHALLENGE 自带服务器 NetBIOS/DNS 名, 不需要凭据, 查到即回填。
        unawaited(_probeHostNames(hosts));
      }
    } catch (err) {
      networkError.value = err.toString();
    } finally {
      scanningNetwork.value = false;
    }
  }

  // ==================== 主机名探测 ====================

  int _probeGeneration = 0;

  Future<void> _probeHostNames(List<SmbHost> hosts) async {
    final generation = ++_probeGeneration;
    await Future.wait([
      for (final host in hosts)
        if (host.name == null || host.name!.isEmpty)
          _probeHostName(host, generation),
    ]);
  }

  Future<void> _probeHostName(SmbHost host, int generation) async {
    Smb2Client? client;
    try {
      client = Smb2Client(
        host: host.address,
        port: host.port,
        fallbackAddress: host.address,
      );
      try {
        await client.connect(timeout: const Duration(seconds: 3));
      } catch (_) {
        // 匿名认证被拒也没关系: CHALLENGE 阶段已拿到服务器名
      }
      if (generation != _probeGeneration) {
        return; // 已发起新一轮发现, 丢弃过期结果
      }
      final name = client.serverInfo?.bestName;
      if (name != null && name.isNotEmpty && name != host.address) {
        final index = discovered.indexOf(host);
        if (index >= 0) {
          discovered[index] = SmbHost(
            address: host.address,
            port: host.port,
            name: name,
          );
        }
      }
    } catch (_) {
      // 探测失败不影响列表(继续显示 IP)
    } finally {
      try {
        await client?.close();
      } catch (_) {}
    }
  }

  // ==================== 打开 ====================

  /// 本机存储卷 -> 浏览页
  Future<void> openDevice(LocalMediaSource source) async {
    if (!await LocalMediaService.ensureDevicePermission()) {
      SmartDialog.showToast('未获得存储读取权限，无法浏览本机文件');
      return;
    }
    _browse(source, source.rootPath, source.name);
  }

  /// 已保存的网络来源
  Future<void> openSource(LocalMediaSource source) async {
    if (!source.canBrowse) {
      // 直链来源: 没有目录可浏览, 直接播放
      final item = LocalMediaItem(
        name: source.name,
        uri: source.playbackBase,
        source: source,
      );
      Get.to(
        () => LocalMediaBrowserPage(
          source: source,
          path: '',
          title: source.name,
          initialItems: [item],
        ),
      );
      return;
    }
    _browse(source, source.rootPath, source.name);
  }

  void _browse(LocalMediaSource source, String path, String title) {
    Get.to(
      () => LocalMediaBrowserPage(source: source, path: path, title: title),
    );
  }

  /// 连接一台发现的主机。
  ///
  /// **主机即目录**(第四轮改的交互, 与 VLC/资源管理器一致): 连接后直接进入
  /// 这台主机, 它共享出来的每个目录就是里面的一级子目录。
  /// 之前的做法是"枚举共享 -> 弹窗让用户挑一个 -> 存成一条快捷路径 -> 打开",
  /// 想换另一个共享就得退回来重选, 而且共享列表会越攒越长。
  /// 现在只有用户自己按浏览页右上角的「添加到快捷方式」时才会新增收藏。
  ///
  /// 这里仍然先做一次共享枚举, 但目的不是让用户挑, 而是:
  ///   1. 拿服务端自报的权威主机名(NTLM CHALLENGE 的 AV_PAIR), 存成
  ///      `smb://<主机名>` 而不是 `smb://<IP>`(IP 会变, 名字不会);
  ///   2. 提前知道要不要账号(匿名被拒就弹一次凭据框);
  ///   3. 把结果当作浏览页根目录的 initialItems, 省掉第二次往返。
  /// 枚举本身失败(服务端禁用 RPC 等)才退回"手动输入共享地址"。
  Future<void> openDiscoveredHost(
    BuildContext context,
    SmbHost host,
  ) async {
    final saved = _savedSourceForHost(host);
    // 已经收藏过这台主机: 直接进入, 不再重新枚举、不再弹窗
    if (saved != null && saved.isSmbHostRoot) {
      openSource(saved);
      return;
    }
    // 复用同主机已保存来源的凭据(可能是旧版本按共享保存的), 免得每次都输
    String? user = saved?.username;
    String? password = saved?.password;
    var domain = saved?.domain ?? '';
    var askedForCredentials = false;

    while (true) {
      SmartDialog.showLoading(msg: '正在连接「${host.displayName}」…');
      try {
        final result = await SmbBrowse.listShares(
          host: host.address,
          port: host.port,
          user: user,
          password: password,
          domain: domain,
        );
        SmartDialog.dismiss();
        if (!context.mounted) {
          return;
        }
        final serverName = result.serverInfo?.bestName ?? host.name;
        final urlHost = _urlSafeHostName(serverName) ?? host.address;
        final source = LocalMediaSource(
          type: LocalMediaSourceType.smb,
          name: serverName ?? host.address,
          // 主机级地址: 没有共享名, 浏览页把根目录解释为"列共享"
          url: SmbBrowse.hostUri(host: urlHost, port: host.port),
          username: user,
          password: (password == null || password.isEmpty) ? null : password,
          domain: domain.isEmpty ? null : domain,
          address: SmbName.isIpLiteral(host.address) ? host.address : null,
        );
        await addSource(source);
        // 共享列表已经拿到了, 直接当根目录内容用(过滤规则与服务层一致)
        final shares = <LocalMediaItem>[
          for (final share in result.browsable)
            LocalMediaItem(
              name: share.name,
              uri: SmbBrowse.uri(
                host: urlHost,
                port: host.port,
                share: share.name,
                remotePath: '',
              ),
              source: source,
              remotePath: share.name,
              isDirectory: true,
            ),
        ];
        Get.to(
          () => LocalMediaBrowserPage(
            source: source,
            path: '',
            title: source.name,
            initialItems: shares,
          ),
        );
        return;
      } on SmbException catch (e) {
        SmartDialog.dismiss();
        if (e.isAuthFailure && !askedForCredentials) {
          askedForCredentials = true;
          if (!context.mounted) {
            return;
          }
          final creds = await showSmbCredentialsDialog(
            context,
            hostLabel: host.displayName,
            initialUser: user,
          );
          if (creds == null) {
            return;
          }
          user = creds.user.isEmpty ? null : creds.user;
          password = creds.password;
          domain = creds.domain;
          continue;
        }
        if (!context.mounted) {
          return;
        }
        // 连得上但共享枚举不可用(服务端禁用 RPC / 权限不足): 退回手动输入
        SmartDialog.showToast('获取共享列表失败: ${e.statusText}');
        await _manualAddHost(context, host, null, user, password, domain);
        return;
      } catch (e) {
        SmartDialog.dismiss();
        if (!context.mounted) {
          return;
        }
        SmartDialog.showToast('连接失败: $e');
        await _manualAddHost(context, host, null, user, password, domain);
        return;
      }
    }
  }

  /// 浏览页里把当前目录收藏成快捷方式(VLC 的 bookmark 行为)。
  ///
  /// 返回 null 表示当前层级不适合收藏(直链来源、或就在来源根目录上)。
  /// 做成静态纯函数是为了能单测(不依赖 GetX/Hive)。
  static LocalMediaSource? shortcutFor({
    required LocalMediaSource source,
    required String path,
    required String title,
  }) {
    final name = title.isEmpty ? source.name : title;
    return switch (source.type) {
      LocalMediaSourceType.device => path.isEmpty
          ? null
          : LocalMediaSource(
              type: LocalMediaSourceType.device,
              name: name,
              url: path,
            ),
      LocalMediaSourceType.smb => _smbShortcut(source, path, name),
      LocalMediaSourceType.webdav => path.isEmpty || path == '/'
          ? null
          : LocalMediaSource(
              type: LocalMediaSourceType.webdav,
              name: name,
              url: LocalMediaService.joinUrl(source.url, path),
              username: source.username,
              password: source.password,
            ),
      // 直链来源没有目录可收藏
      LocalMediaSourceType.http || LocalMediaSourceType.ftp => null,
    };
  }

  static LocalMediaSource? _smbShortcut(
    LocalMediaSource source,
    String path,
    String name,
  ) {
    final h = source.smbHost;
    if (h == null) {
      return null;
    }
    // 主机级来源: path 的第一段是共享名; 共享级来源: 共享名在 endpoint 里
    final String? host;
    final int port;
    final String share;
    final String inner;
    if (source.isSmbHostRoot) {
      final (s, i) = SmbBrowse.splitSharePath(path);
      if (s.isEmpty) {
        // 就在主机根上, 收藏它等于收藏主机本身
        return null;
      }
      host = h.host;
      port = h.port;
      share = s;
      inner = i;
    } else {
      final ep = source.smbEndpoint;
      if (ep == null) {
        return null;
      }
      host = ep.host;
      port = ep.port;
      share = ep.share;
      inner = path;
    }
    return LocalMediaSource(
      type: LocalMediaSourceType.smb,
      name: name,
      url: SmbBrowse.uri(host: host, port: port, share: share, remotePath: inner),
      username: source.username,
      password: source.password,
      domain: source.domain,
      address: source.address,
    );
  }

  /// 浏览中弹出凭据框后, 把账号写回来源(否则每进一层都要重输)
  Future<void> updateCredentials(
    LocalMediaSource source, {
    String? user,
    String? password,
    String domain = '',
  }) async {
    // withCredentials 而不是 copyWith: 传 null 要能真的把旧凭据清掉,
    // 否则"改用匿名访问"会一直带着上一次的错密码重试
    final updated = source.withCredentials(
      username: user,
      password: password,
      domain: domain,
    );
    final index = savedSources.indexOf(source);
    if (index >= 0) {
      savedSources[index] = updated;
      await _persist();
    } else {
      await addSource(updated);
    }
  }

  /// 手动输入共享地址(自动枚举失败时的兜底, 预填已知信息)
  Future<void> _manualAddHost(
    BuildContext context,
    SmbHost host,
    String? serverName,
    String? user,
    String? password,
    String domain,
  ) async {
    final preset = LocalMediaSource(
      type: LocalMediaSourceType.smb,
      name: host.displayName,
      url: 'smb://${_urlSafeHostName(serverName) ?? host.address}/',
      username: user,
      password: (password == null || password.isEmpty) ? null : password,
      domain: domain.isEmpty ? null : domain,
      address: SmbName.isIpLiteral(host.address) ? host.address : null,
    );
    final source = await showSourceEditor(context, initial: preset);
    if (source == null) {
      return;
    }
    // 编辑器里改过 URL 也不丢 IP 兜底
    await _testAndOpen(
      source.address == null && preset.address != null
          ? source.copyWith(address: preset.address)
          : source,
    );
  }

  Future<void> _testAndOpen(LocalMediaSource source) async {
    SmartDialog.showLoading(msg: '连接中');
    final res = await LocalMediaService.testConnection(source);
    SmartDialog.dismiss();
    switch (res) {
      case Success():
        // 手动添加 = 用户主动意愿, 直接进快捷方式
        await addSource(source, favorite: true);
        openSource(source);
      case Error(:final errMsg):
        SmartDialog.showToast(errMsg ?? '连接失败');
      case _:
        break;
    }
  }

  /// 找到同一台主机上已保存的 SMB 来源(按 IP 或主机名匹配)。
  /// 主机级来源(`smb://NAS`)优先: 它才是"这台主机"本身。
  LocalMediaSource? _savedSourceForHost(SmbHost host) {
    LocalMediaSource? fallback;
    for (final source in savedSources) {
      if (source.type != LocalMediaSourceType.smb) {
        continue;
      }
      // 主机级来源用 smbHost, 共享级来源用 smbEndpoint
      final h = source.smbHost;
      if (h == null) {
        continue;
      }
      final match =
          h.host == host.address ||
          source.address == host.address ||
          (host.name != null && h.host == host.name);
      if (!match) {
        continue;
      }
      if (source.isSmbHostRoot) {
        return source;
      }
      fallback ??= source;
    }
    return fallback;
  }

  /// 主机名能不能安全地写进 URL(否则退回 IP)
  static String? _urlSafeHostName(String? name) {
    if (name == null || name.isEmpty) {
      return null;
    }
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) ? name : null;
  }

  Future<void> addSourceFromDialog(BuildContext context) async {
    final source = await showSourceEditor(context);
    if (source != null) {
      await addSource(source);
    }
  }

  // ==================== 来源管理 ====================

  /// 添加/更新来源。[favorite]=true 表示用户**主动收藏**(进快捷方式列表);
  /// 连接主机时的自动记录默认 false(只留凭据, 不刷屏)。同一来源(== 不
  /// 含 favorite)已存在时做合并更新, 收藏态只升不降。
  Future<void> addSource(LocalMediaSource source, {bool favorite = false}) async {
    final incoming = favorite ? source.copyWith(favorite: true) : source;
    final index = savedSources.indexOf(incoming);
    if (index >= 0) {
      savedSources[index] = incoming.copyWith(
        favorite: favorite || savedSources[index].favorite,
      );
    } else {
      savedSources.add(incoming);
    }
    await _persist();
  }

  Future<void> replaceSource(
    LocalMediaSource old,
    LocalMediaSource updated,
  ) async {
    final index = savedSources.indexOf(old);
    if (index < 0) {
      return;
    }
    savedSources[index] = updated;
    await _persist();
  }

  Future<void> removeSource(LocalMediaSource source) async {
    savedSources.remove(source);
    await _persist();
  }

  Future<void> _persist() => LocalMediaService.saveSources(savedSources);

  Future<void> editSource(BuildContext context, LocalMediaSource source) async {
    final updated = await showSourceEditor(context, initial: source);
    if (updated != null) {
      await replaceSource(source, updated);
    }
  }

}
