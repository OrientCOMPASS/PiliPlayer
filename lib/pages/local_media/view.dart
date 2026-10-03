import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/smb/smb_discovery.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/permission_handler.dart' show openAppSettings;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块(底部导航之一)。
///
/// 第十八轮改版: 去掉「媒体库 / 网络」两个 tab, 也不再全盘扫描媒体库
/// (要看什么, 用户自己进目录找)。单页三段:
///   * 本机存储: 每个存储卷一个入口 -> 浏览页;
///   * 快捷方式: **仅**用户主动收藏的(浏览页里点收藏; 本机路径同样可收藏),
///     不再展示"连接过的主机"自动记录(那只是凭据备忘, 不进列表);
///   * 局域网: SMB 主机自动发现(尽力显示主机名) + 手动添加来源。
class LocalMediaPage extends StatefulWidget {
  const LocalMediaPage({super.key});

  @override
  State<LocalMediaPage> createState() => _LocalMediaPageState();
}

class _LocalMediaPageState extends State<LocalMediaPage>
    with AutomaticKeepAliveClientMixin {
  late final LocalMediaController _controller;
  late final _ResumeObserver _observer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = Get.putOrFind(LocalMediaController.new);
    // 从后台切回来时刷新权限提示与存储卷(可能刚插了 SD 卡/U 盘,
    // 也可能刚在系统设置里改了照片权限)。不再触发全盘扫描。
    _observer = _ResumeObserver(_controller);
    WidgetsBinding.instance.addObserver(_observer);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_observer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      primary: false,
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        primary: false,
        title: const Text('本地'),
        actions: [
          Obx(
            () => IconButton(
              tooltip: '扫描局域网 SMB 主机',
              onPressed: _controller.scanningNetwork.value
                  ? null
                  : _controller.discoverNetwork,
              icon: const Icon(Icons.wifi_find_outlined),
            ),
          ),
          IconButton(
            tooltip: '添加网络共享',
            onPressed: () => _controller.addSourceFromDialog(context),
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Obx(() {
        final children = <Widget>[];

        if (_controller.accessNotice.value case final notice?) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
                onPressed: openAppSettings,
                icon: const Icon(Icons.error_outline),
                label: Text(notice),
              ),
            ),
          );
        }

        // ---------- 本机存储 ----------
        // 第十九轮重写: 授权过的文件夹(SAF)排在最前, 它能看到目录里的**全部**
        // 文件; 存储卷直读放在后面并明确标注"只能看到媒体文件", 免得用户以为
        // 应用把他的文件吃了。
        children.add(_sectionHeader(context, '本机存储'));
        for (final source in _controller.safSources) {
          children.add(_buildSafTree(context, source));
        }
        for (final source in _controller.deviceSources) {
          children.add(_buildVolume(context, source));
        }
        children.add(
          Obx(
            () => ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('选择本机文件夹…'),
              subtitle: Text(
                _controller.safSources.isEmpty
                    ? '系统授权后可看到该文件夹里的全部文件(推荐)'
                    : '再授权一个文件夹(已授权 ${_controller.safSources.length} 个)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _controller.pickingFolder.value
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              onTap: _controller.pickingFolder.value
                  ? null
                  : () => _controller.pickSafFolder(),
            ),
          ),
        );
        if (!_controller.allFilesAccess.value) {
          children.add(
            ListTile(
              leading: const Icon(Icons.rule_folder_outlined),
              title: const Text('开启「所有文件访问权限」'),
              subtitle: const Text(
                '一次性放开整个存储, 之后直读也能看全(可选)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () async {
                await _controller.openAllFilesSettings();
                await _controller.refreshSafSources();
              },
            ),
          );
        }

        // ---------- 快捷方式(仅用户收藏) ----------
        final favorites = _controller.favoriteSources;
        if (favorites.isNotEmpty) {
          children
            ..add(const Divider(height: 24))
            ..add(_sectionHeader(context, '快捷方式'));
          for (final source in favorites) {
            children.add(_buildSource(context, source));
          }
        }

        // ---------- 局域网 ----------
        children
          ..add(const Divider(height: 24))
          ..add(_sectionHeader(context, '局域网'))
          ..add(
            Obx(() {
              final scanning = _controller.scanningNetwork.value;
              return ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('SMB 主机'),
                subtitle: Text(
                  scanning
                      ? '扫描中 ${_controller.scanDone.value}/${_controller.scanTotal.value}'
                      : _controller.discovered.isEmpty
                      ? '点右上角按钮自动发现同一局域网内开启 SMB 的主机'
                      : '发现 ${_controller.discovered.length} 台',
                ),
                trailing: scanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: '重新扫描',
                        onPressed: _controller.discoverNetwork,
                        icon: const Icon(Icons.refresh),
                      ),
                onTap: scanning ? null : _controller.discoverNetwork,
              );
            }),
          );

        if (_controller.networkError.value case final err?) {
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              child: Text(err, style: Theme.of(context).textTheme.bodySmall),
            ),
          );
        }

        for (final host in _controller.discovered) {
          children.add(_buildHost(context, host));
        }

        children.add(
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('添加网络共享'),
            subtitle: const Text('SMB / WebDAV 可浏览, HTTP / FTP 为直链'),
            onTap: () => _controller.addSourceFromDialog(context),
          ),
        );

        return ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: children,
        );
      }),
    );
  }

  /// 已授权的 SAF 目录树
  Widget _buildSafTree(BuildContext context, LocalMediaSource source) {
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        LocalMediaService.safLabel(source),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _controller.openDevice(context, source),
      onLongPress: () => _showSafTreeMenu(context, source),
    );
  }

  /// 存储卷(直读)。没有「所有文件访问权限」时把限制写在副标题里。
  Widget _buildVolume(BuildContext context, LocalMediaSource source) {
    final unrestricted = _controller.allFilesAccess.value;
    return ListTile(
      leading: const Icon(Icons.storage_outlined),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        unrestricted ? source.url : '${source.url} · 直读(只能看到媒体文件)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _controller.openDevice(context, source),
    );
  }

  void _showSafTreeMenu(BuildContext context, LocalMediaSource source) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(source.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('浏览'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _controller.openDevice(context, source);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link_off),
              title: const Text('移除授权'),
              subtitle: const Text(
                '撤销系统授予的文件夹读取权限(不删除任何文件)',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _controller.removeSafSource(source);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _buildHost(BuildContext context, SmbHost host) {
    return ListTile(
      leading: const Icon(Icons.computer_outlined),
      title: Text(host.displayName),
      subtitle: Text(
        '${host.address}:${host.port}'
        '${host.name == null ? '' : ' · 点击进入主机，共享为其中的子目录'}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _controller.openDiscoveredHost(context, host),
    );
  }

  Widget _buildSource(BuildContext context, LocalMediaSource source) {
    final subtitle = source.type == LocalMediaSourceType.device
        ? source.url
        : LocalMediaService.maskedUrl(source.url);
    return ListTile(
      leading: Icon(_sourceIcon(source.type)),
      title: Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        source.canBrowse ? Icons.chevron_right : Icons.play_arrow_outlined,
      ),
      onTap: () => _controller.openSource(source),
      onLongPress: () => _showSourceMenu(context, source),
    );
  }

  IconData _sourceIcon(LocalMediaSourceType type) => switch (type) {
    LocalMediaSourceType.device => Icons.smartphone_outlined,
    LocalMediaSourceType.smb => Icons.folder_shared_outlined,
    LocalMediaSourceType.webdav => Icons.cloud_outlined,
    LocalMediaSourceType.http => Icons.language_outlined,
    LocalMediaSourceType.ftp => Icons.swap_vert_outlined,
  };

  void _showSourceMenu(BuildContext context, LocalMediaSource source) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(source.name),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (source.canBrowse)
              ListTile(
                dense: true,
                leading: const Icon(Icons.wifi_tethering_outlined),
                title: const Text('测试连接'),
                onTap: () async {
                  Navigator.of(dialogContext).pop();
                  SmartDialog.showLoading(msg: '连接中');
                  final res = await LocalMediaService.testConnection(source);
                  SmartDialog.dismiss();
                  switch (res) {
                    case Success(:final response):
                      SmartDialog.showToast('连接成功，$response 个条目');
                    case Error(:final errMsg):
                      SmartDialog.showToast(errMsg ?? '连接失败');
                    case _:
                      break;
                  }
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () async {
                Navigator.of(dialogContext).pop();
                await _controller.editSource(context, source);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _controller.removeSource(source);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 应用回前台时刷新权限提示与存储卷
class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this.controller);

  final LocalMediaController controller;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.onResumed();
    }
  }
}
