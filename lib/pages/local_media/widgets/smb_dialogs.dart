import 'package:material_ui/material_ui.dart';

/// SMB 凭据
typedef SmbCredentials = ({String user, String password, String domain});

/// 「需要账号」对话框: 服务端拒绝匿名枚举共享时弹出
Future<SmbCredentials?> showSmbCredentialsDialog(
  BuildContext context, {
  required String hostLabel,
  String? initialUser,
}) {
  return showDialog<SmbCredentials>(
    context: context,
    builder: (context) => _SmbCredentialsDialog(
      hostLabel: hostLabel,
      initialUser: initialUser,
    ),
  );
}

class _SmbCredentialsDialog extends StatefulWidget {
  const _SmbCredentialsDialog({required this.hostLabel, this.initialUser});

  final String hostLabel;
  final String? initialUser;

  @override
  State<_SmbCredentialsDialog> createState() => _SmbCredentialsDialogState();
}

class _SmbCredentialsDialogState extends State<_SmbCredentialsDialog> {
  late final _userCtr = TextEditingController(text: widget.initialUser ?? '');
  late final _passCtr = TextEditingController();
  late final _domainCtr = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _userCtr.dispose();
    _passCtr.dispose();
    _domainCtr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('连接 ${widget.hostLabel}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '这台主机不允许匿名获取共享列表，请输入账号密码。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userCtr,
              autofocus: true,
              decoration: const InputDecoration(labelText: '用户名'),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: _passCtr,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            TextField(
              controller: _domainCtr,
              decoration: const InputDecoration(
                labelText: '域/工作组(可留空)',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('连接')),
      ],
    );
  }

  void _submit() {
    Navigator.of(
      context,
    ).pop((
      user: _userCtr.text.trim(),
      password: _passCtr.text,
      domain: _domainCtr.text.trim(),
    ));
  }
}
