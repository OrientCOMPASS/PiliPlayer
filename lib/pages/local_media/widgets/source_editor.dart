import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 打开「添加/编辑网络共享」对话框, 取消时返回 null
Future<LocalMediaSource?> showSourceEditor(
  BuildContext context, {
  LocalMediaSource? initial,
}) {
  return showDialog<LocalMediaSource>(
    context: context,
    builder: (context) => SourceEditorDialog(initial: initial),
  );
}

class SourceEditorDialog extends StatefulWidget {
  const SourceEditorDialog({super.key, this.initial});

  final LocalMediaSource? initial;

  @override
  State<SourceEditorDialog> createState() => _SourceEditorDialogState();
}

class _SourceEditorDialogState extends State<SourceEditorDialog> {
  late LocalMediaSourceType _type = widget.initial?.type.isNetwork == true
      ? widget.initial!.type
      : LocalMediaSourceType.webdav;
  late final _nameCtr = TextEditingController(text: widget.initial?.name);
  late final _urlCtr = TextEditingController(text: widget.initial?.url);
  late final _userCtr = TextEditingController(text: widget.initial?.username);
  late final _passCtr = TextEditingController(text: widget.initial?.password);
  late final _domainCtr = TextEditingController(text: widget.initial?.domain);

  bool _obscure = true;
  bool _testing = false;

  /// 可添加的网络来源类型(本机存储由系统自动发现, 不需要手动添加)
  static const _types = [
    LocalMediaSourceType.smb,
    LocalMediaSourceType.webdav,
    LocalMediaSourceType.http,
    LocalMediaSourceType.ftp,
  ];

  @override
  void dispose() {
    _nameCtr.dispose();
    _urlCtr.dispose();
    _userCtr.dispose();
    _passCtr.dispose();
    _domainCtr.dispose();
    super.dispose();
  }

  String get _hint => switch (_type) {
    LocalMediaSourceType.smb => 'smb://NAS/video 或 smb://192.168.1.10/video',
    LocalMediaSourceType.webdav => 'http://192.168.1.10:5005/dav',
    LocalMediaSourceType.http => 'http://192.168.1.10:8080/video.mp4',
    LocalMediaSourceType.ftp => 'ftp://192.168.1.10/media/video.mkv',
    LocalMediaSourceType.device => '/storage/emulated/0',
  };

  LocalMediaSource? _build() {
    final url = _urlCtr.text.trim();
    if (url.isEmpty) {
      SmartDialog.showToast('请填写地址');
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      SmartDialog.showToast('地址格式不正确, 需要形如 $_hint');
      return null;
    }
    final name = _nameCtr.text.trim();
    return LocalMediaSource(
      type: _type,
      name: name.isEmpty ? uri.host : name,
      url: url,
      username: _userCtr.text.isEmpty ? null : _userCtr.text,
      password: _passCtr.text.isEmpty ? null : _passCtr.text,
      domain: _domainCtr.text.isEmpty ? null : _domainCtr.text,
    );
  }

  Future<void> _test() async {
    final source = _build();
    if (source == null) {
      return;
    }
    setState(() => _testing = true);
    final res = await LocalMediaService.testConnection(source);
    if (!mounted) {
      return;
    }
    setState(() => _testing = false);
    switch (res) {
      case Success(:final response):
        SmartDialog.showToast('连接成功，$response 个条目');
      case Error(:final errMsg):
        SmartDialog.showToast(errMsg ?? '连接失败');
      case _:
        SmartDialog.showToast('测试中…');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '添加网络共享' : '编辑网络共享'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('类型'),
              trailing: Text(_type.label),
              onTap: () async {
                final res = await showDialog<LocalMediaSourceType>(
                  context: context,
                  builder: (context) => SelectDialog<LocalMediaSourceType>(
                    title: '来源类型',
                    value: _type,
                    values: _types.map((e) => (e, e.label)).toList(),
                  ),
                );
                if (res != null && mounted) {
                  setState(() => _type = res);
                }
              },
            ),
            TextField(
              controller: _nameCtr,
              decoration: const InputDecoration(
                labelText: '名称(可选)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtr,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '地址',
                hintText: _hint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userCtr,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '用户名(可选)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_type == LocalMediaSourceType.smb) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _domainCtr,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '域 / 工作组(可选, 常见为 WORKGROUP)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            TextField(
              controller: _passCtr,
              autofillHints: const [AutofillHints.password],
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码(可选)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '账号密码只保存在本机。SMB 由内置客户端浏览，播放时经本机回环'
              '代理转发给播放器(安卓端的 FFmpeg 没有编译 smb 协议)；'
              'WebDAV 可浏览目录，HTTP/FTP 为直链播放。\n'
              'SMB 地址格式: smb://主机/共享名，例如 $_hint',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : _test,
          child: const Text('测试连接'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final source = _build();
            if (source != null) {
              Navigator.of(context).pop(source);
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
