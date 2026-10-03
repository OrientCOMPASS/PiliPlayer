import 'dart:async';

import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  final _searcher = DLNAManager();
  final Map<String, DLNADevice> _deviceList = {};
  late final _url = Get.parameters['url']!;
  late final _title = Get.parameters['title'];

  Timer? _timer;
  StreamSubscription<Map<String, DLNADevice>>? _subscription;
  bool _isSearching = false;
  DLNADevice? _lastDevice;
  String? _lastDeviceKey;

  @override
  void initState() {
    super.initState();
    _onSearch(isInit: true);
  }

  /// 搜索局域网里的 DLNA 设备。
  ///
  /// 这里必须是"错误有归属"的写法: 原来用 `await for` 直接消费
  /// `deviceManager.devices.stream`, 而 `_onSearch` 是从 `initState` 里
  /// **不 await** 地调起来的 —— 插件在探测设备(SSDP 之后还要去
  /// `http://<设备IP>:<随机端口>/...` 拉设备描述)时抛出的
  /// `SocketException: Connection timed out` 会变成**未捕获的异步错误**,
  /// 被全局错误处理当成崩溃上报(真机上就出现过两条
  /// `address = 192.168.x.x, port = 5xxxx`、`STACK TRACE: null` 的报告)。
  /// 现在改成显式订阅 + `onError`, 并把整个流程包在 try 里。
  Future<void> _onSearch({bool isInit = false}) async {
    if (_isSearching) return;
    _isSearching = true;
    if (!isInit && mounted) {
      _lastDevice = null;
      _deviceList.clear();
      setState(() {});
    }
    try {
      final deviceManager = await _searcher.start();
      if (!mounted) {
        return;
      }
      _timer = Timer(const Duration(seconds: 20), _searcher.stop);
      _subscription = deviceManager.devices.stream.listen(
        (deviceList) {
          if (!mounted) return;
          _deviceList.addAll(deviceList);
          setState(() {});
        },
        // 个别设备不可达/描述地址失效是正常的局域网现象, 记一条日志就好,
        // 不能让它冒到 zone 外面去
        onError: (Object error) {
          if (kDebugMode) {
            debugPrint('dlna search error: $error');
          }
        },
        onDone: () {
          if (mounted) {
            setState(() => _isSearching = false);
          }
        },
        cancelOnError: false,
      );
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('dlna start failed: $error');
      }
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    // 页面关掉就要停止消费设备流, 否则插件还在后台探测局域网
    unawaited(_subscription?.cancel());
    _subscription = null;
    _searcher.stop();
    _lastDevice = null;
    _lastDeviceKey = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('投屏'),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _onSearch,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (_isSearching) linearLoading,
          ViewSliverSafeArea(sliver: _buildBody(colorScheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (!_isSearching && _deviceList.isEmpty) {
      return HttpError(
        errMsg: '没有设备',
        onReload: _onSearch,
      );
    }
    if (_deviceList.isNotEmpty) {
      final keys = _deviceList.keys.toList();
      return SliverList.builder(
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index];
          final device = _deviceList[key]!;
          final isCurr = key == _lastDeviceKey;
          return ListTile(
            title: Text(
              device.info.friendlyName,
              style: isCurr ? TextStyle(color: colorScheme.primary) : null,
            ),
            subtitle: Text(key),
            onTap: () async {
              if (isCurr) return;
              _lastDevice?.pause();
              _lastDevice = device;
              _lastDeviceKey = key;
              setState(() {});
              // 投屏失败(设备掉线/不支持该地址)要提示, 不能变成未捕获异常
              try {
                await device.setUrl(_url, title: _title ?? '');
                await device.play();
              } on Object catch (error) {
                if (mounted) {
                  SmartDialog.showToast('投屏失败: $error');
                }
              }
            },
          );
        },
      );
    }
    return const SliverToBoxAdapter();
  }
}
