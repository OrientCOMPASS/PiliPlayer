import 'dart:async' show Timer, unawaited;

import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/pages/local_media/widgets/smb_dialogs.dart';
import 'package:PiliPlus/services/floating_player.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/saf/saf_bridge.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 目录浏览页: 从一个来源(本机目录 / SMB 共享 / WebDAV)的某个路径开始逐层浏览。
///
/// 点一个视频就播放, 同目录的其他视频自动成为播放列表; 返回键逐层回退。
class LocalMediaBrowserPage extends StatefulWidget {
  const LocalMediaBrowserPage({
    super.key,
    required this.source,
    required this.path,
    this.title,
    this.initialItems,
  });

  final LocalMediaSource source;
  final String path;
  final String? title;

  /// 已经取到的条目(例如从媒体库点进文件夹时), 可以避免再列一次目录
  final List<LocalMediaItem>? initialItems;

  @override
  State<LocalMediaBrowserPage> createState() => _LocalMediaBrowserPageState();
}

class _LocalMediaBrowserPageState extends State<LocalMediaBrowserPage> {
  final List<_Level> _stack = [];
  LoadingState<List<LocalMediaItem>> _state = LoadingState.loading();
  LocalMediaSort _sort = Pref.localMediaSort;
  bool _showHidden = Pref.localMediaShowHidden;
  Map<String, Duration> _progress = const {};
  bool _busy = false;

  // ==================== 检索(本目录 + 子目录) ====================
  bool _searching = false;
  bool _searchRunning = false;
  String _query = '';
  List<LocalMediaItem> _results = const [];
  String _searchInfo = '';

  /// 检索代数: 改关键词/退出检索就自增, 在飞的那次结果直接丢弃
  int _searchGen = 0;
  Timer? _searchDebounce;
  final TextEditingController _searchCtr = TextEditingController();

  @override
  void dispose() {
    _dlCancelled = true; // 页面都关了, 别让下载继续占着网络
    _dlDialogContext = null;
    // 浏览页都关了, 这一页导出过的 SAF fd 没有再被使用的可能
    // (小窗还活着时它自己会在关闭时收尾)
    if (!FloatingPlayerService.instance.isActive) {
      unawaited(SafFdRegistry.releaseAll());
    }
    _searchDebounce?.cancel();
    _searchFlushTimer?.cancel();
    _searchGen++; // 让在飞的检索作废, 回调里会因 mounted/gen 不符而直接返回
    _searchCtr.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _stack.add(
      _Level(
        source: widget.source,
        path: widget.path,
        title: widget.title ?? widget.source.name,
      ),
    );
    final initial = widget.initialItems;
    if (initial != null && initial.isNotEmpty) {
      _state = Success(initial);
      _syncProgress(initial);
    } else {
      _refresh();
    }
  }

  List<LocalMediaItem> get _items => _state.dataOrNull ?? const [];

  /// 当前展示(也就是"同目录播放列表"取值)的条目: 检索时是结果集
  List<LocalMediaItem> get _effectiveItems => _searching ? _results : _items;

  _Level get _current => _stack.last;

  /// [askCredentials] 为 false 时不再弹凭据框(避免账号错误时无限循环)
  Future<void> _refresh({bool askCredentials = true}) async {
    setState(() => _state = LoadingState.loading());
    final level = _current;
    try {
      final items = await LocalMediaService.listOrThrow(
        source: level.source,
        path: level.path,
        showHidden: _showHidden,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _state = Success(LocalMediaService.sortItems(items, _sort));
        _syncProgress(items);
      });
    } on Object catch (err) {
      if (!mounted) {
        return;
      }
      // SMB 服务端不接受匿名: 弹一次凭据框, 存进来源后重试。
      // 凭据挂在"来源"上, 所以整台主机的所有共享/子目录共用一份, 不会反复问。
      if (askCredentials &&
          LocalMediaService.isAuthFailure(err) &&
          await _askCredentials(level.source)) {
        await _refresh(askCredentials: false);
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _state = Error(LocalMediaService.humanize(err, level.source));
      });
    }
  }

  /// 弹凭据框; 成功后把账号写回来源(持久化)并更新本页面栈里的所有层级
  Future<bool> _askCredentials(LocalMediaSource source) async {
    final creds = await showSmbCredentialsDialog(
      context,
      hostLabel: source.name,
      initialUser: source.username,
    );
    if (creds == null || !mounted) {
      return false;
    }
    final user = creds.user.isEmpty ? null : creds.user;
    final password = creds.password.isEmpty ? null : creds.password;
    final domain = creds.domain.isEmpty ? null : creds.domain;
    final updated = source.withCredentials(
      username: user,
      password: password,
      domain: domain,
    );
    await _mediaController?.updateCredentials(
      source,
      user: user,
      password: password,
      domain: creds.domain,
    );
    if (!mounted) {
      return false;
    }
    // 页面栈里的同一来源都要换成带凭据的副本, 否则回退一层又要重输
    for (final level in _stack) {
      if (level.source.url == source.url &&
          level.source.type == source.type) {
        level.source = updated;
      }
    }
    return true;
  }

  /// 「本地」板块控制器(用于保存快捷方式与凭据); 独立打开本页时可能没有
  LocalMediaController? get _mediaController =>
      Get.isRegistered<LocalMediaController>()
      ? Get.find<LocalMediaController>()
      : null;

  void _syncProgress(List<LocalMediaItem> items) {
    final next = <String, Duration>{};
    for (final item in items) {
      if (LocalMediaProgress.get(item.uri) case final p?) {
        next[item.uri] = p;
      }
    }
    _progress = next;
  }

  Future<void> _open(LocalMediaItem item) async {
    if (!item.isDirectory) {
      await _play(item);
      return;
    }
    final childPath = LocalMediaService.childPath(_current.source, item);
    setState(() {
      _stack.add(
        _Level(source: _current.source, path: childPath, title: item.name),
      );
    });
    await _refresh();
  }

  bool _back() {
    if (_searching) {
      _exitSearch();
      return true;
    }
    if (_stack.length <= 1) {
      return false;
    }
    setState(_popLevel);
    _refresh();
    return true;
  }

  void _popLevel() => _stack.removeLast();

  Future<void> _play(LocalMediaItem item) async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      // SMB 需要先在本机代理上注册一个回环地址(打包的 FFmpeg 没有 smb 协议)
      final url = await LocalMediaService.resolvePlayUrl(item);
      final siblings = _effectiveItems.where((e) => e.isVideo).toList();
      final index = siblings.indexWhere((e) => e.uri == item.uri);
      final list = index >= 0 ? siblings : <LocalMediaItem>[item];
      if (!mounted) {
        return;
      }
      await PageUtils.toVideoPage(
        aid: 0,
        bvid: '',
        cid: item.cid,
        title: item.name,
        extraArguments: {
          'sourceType': SourceType.localMedia,
          'localMedia': item,
          'localPlaylist': list,
          'localIndex': index >= 0 ? index : 0,
          'localPlayUrl': url,
        },
      );
      // 播放页返回后刷新续播进度
      if (mounted) {
        setState(() => _syncProgress(_effectiveItems));
      }
      // SAF 条目播放时导出的 fd(视频本体 + 外挂字幕)一次性回收;
      // Kotlin 侧另有 LRU 兜底, 但主动关掉才不会把句柄攒满。
      //
      // **小窗播放时绝对不能关**: 应用内画中画是"播放页出栈、播放器保活",
      // 于是这里的 await 会返回, 但 mpv 还拿着这些 fd 在读(关掉就是 EBADF,
      // 表现为小窗画面卡死/报错)。回播放页走的也是同一个 fd, 所以整段
      // 小窗生命周期内都要留着, 交给 FloatingPlayerService.close() 收尾。
      if (!FloatingPlayerService.instance.isActive) {
        await SafFdRegistry.releaseAll();
      }
    } on Object catch (err) {
      SmartDialog.showToast('无法播放: $err');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return popScope(
      canPop: _stack.length <= 1 && !_searching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _back();
        }
      },
      child: SimpleScaffold(
        appBar: AppBar(
          // 第十九轮: 列表里不再有 ".." 这一行(它既占位置又容易被误点成
          // 文件), 回上一级统一走 返回键 / 系统返回 / 面包屑。
          leading: IconButton(
            tooltip: _stack.length > 1 ? '上一级目录' : '返回',
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (!_back()) {
                Navigator.of(context).maybePop();
              }
            },
          ),
          bottom: _searching ? null : _buildBreadcrumb(),
          title: _searching
              ? TextField(
                  controller: _searchCtr,
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '检索本目录及子目录',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                )
              : Text(
                  _current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          actions: [
            IconButton(
              tooltip: _searching ? '退出检索' : '检索(含子目录)',
              onPressed: _searching ? _exitSearch : _enterSearch,
              icon: Icon(_searching ? Icons.close : Icons.search),
            ),
            // 检索态下这些都只对浏览态有意义, 一并收起来
            if (!_searching) ...[
              // VLC 式书签: 浏览到常用目录时手动收藏, 而不是连接主机时被动弹窗。
              // 刻意不用 Obx: 收藏状态只在点按后变化, setState 足够, 也避免
              // 控制器没注册时 Obx 因为"没订阅到任何可观察对象"而报错。
              IconButton(
                tooltip: _isBookmarked ? '已在快捷方式中' : '添加到快捷方式',
                onPressed: _shortcut == null ? null : _addShortcut,
                icon: Icon(
                  _isBookmarked
                      ? Icons.bookmark_added_outlined
                      : Icons.bookmark_add_outlined,
                ),
              ),
              PopupMenuButton<LocalMediaSort>(
                tooltip: '排序',
                initialValue: _sort,
                icon: const Icon(Icons.sort),
                onSelected: (value) {
                  setState(() => _sort = value);
                  final current = _state.dataOrNull;
                  if (current != null) {
                    setState(
                      () => _state = Success(
                        LocalMediaService.sortItems(current, value),
                      ),
                    );
                  }
                },
                itemBuilder: (context) => LocalMediaSort.values
                    .map((e) => PopupMenuItem(value: e, child: Text(e.label)))
                    .toList(),
              ),
              IconButton(
                tooltip: _showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
                onPressed: () {
                  setState(() => _showHidden = !_showHidden);
                  _refresh();
                },
                icon: Icon(
                  _showHidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
            const SizedBox(width: 6),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            ViewSliverSafeArea(
              sliver: _searching
                  ? _buildSearchSliver()
                  : switch (_state) {
                      Loading() => linearLoading,
                      Error(:final errMsg) => HttpError(
                        errMsg: errMsg,
                        onReload: _refresh,
                      ),
                      Success() => _buildList(),
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final items = _items;
    if (items.isEmpty) {
      return HttpError(
        errMsg: _emptyHint,
        onReload: _refresh,
      );
    }
    // 不再有 ".." 这一行: 回上一级用 返回键 / 系统返回 / 顶部面包屑
    return SliverList.builder(
      itemCount: items.length,
      itemBuilder: (context, index) => _buildItem(items[index]),
    );
  }

  /// 空目录的提示: 直读模式在安卓 11+ 只能看到媒体文件, 必须把出路说清楚,
  /// 否则用户只会觉得"我的文件被吃了"。
  String get _emptyHint {
    final source = _current.source;
    if (LocalMediaService.isSafSource(source)) {
      return '这个文件夹是空的';
    }
    if (source.type == LocalMediaSourceType.device) {
      return '这里没有读到任何文件。\n'
          '安卓 11+ 的直读模式只能看到媒体文件, 请在「本地」页用'
          '「选择本机文件夹」授权后再浏览(可看到全部文件)。';
    }
    return '这里没有可播放的媒体文件';
  }

  /// 顶部面包屑: 当前位置 + 逐级可点回跳。
  ///
  /// 去掉 ".." 行之后, 这是"我在哪 / 怎么回去"的主要线索; 横向列表用
  /// `reverse` 让**最右边**始终是当前层(路径很长时前面的层级自然被裁掉)。
  PreferredSizeWidget _buildBreadcrumb() {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    return PreferredSize(
      preferredSize: const Size.fromHeight(32),
      child: SizedBox(
        height: 32,
        child: ListView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (var i = _stack.length - 1; i >= 0; i--) ...[
              if (i != _stack.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Icon(
                    Icons.chevron_right,
                    size: 14,
                    color: dim.withValues(alpha: 0.6),
                  ),
                ),
              _buildCrumb(i, i == _stack.length - 1, theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCrumb(int level, bool isCurrent, ThemeData theme) {
    final title = _stack[level].title;
    final color = isCurrent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        // 点当前层没意义; 点上层直接跳回去(截断页面栈)
        onTap: isCurrent
            ? null
            : () {
                setState(() {
                  while (_stack.length > level + 1) {
                    _stack.removeLast();
                  }
                });
                _refresh();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: isCurrent ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
  }

  /// 检索态的内容: 提示 / 进度 / 结果列表
  Widget _buildSearchSliver() {
    final keyword = _query.trim();
    if (keyword.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            spacing: 10,
            children: [
              Icon(Icons.manage_search_outlined, size: 52),
              Text(
                '输入关键词，检索当前目录及其所有子目录里的视频/音频\n'
                '(按文件名匹配，就近的排在前面)',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      // 还在扫的时候只显示进度, 不要提前下"没有匹配"的结论
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            spacing: 12,
            children: [
              if (_searchRunning)
                const SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.search_off_outlined, size: 48),
              Text(_searchInfo, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    _searchInfo,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_searchRunning)
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: _results.length,
          itemBuilder: (context, index) => _buildItem(_results[index]),
        ),
      ],
    );
  }

  Widget _buildItem(LocalMediaItem item) {
    final progress = _progress[item.uri];
    final subtitle = <String>[
      if (item.size case final size?) CacheManager.formatSize(size),
      if (item.modified case final modified?) _formatDate(modified),
      if (progress case final p?)
        '看到 ${DurationUtils.formatDuration(p.inSeconds)}',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        item.isDirectory
            ? Icons.folder_outlined
            : item.isAudio
            ? Icons.audiotrack_outlined
            : item.isVideo
            ? Icons.movie_outlined
            // 列表不再按类型过滤: 未知类型的文件给通用图标, 点开能不能
            // 播交给 mpv 判断(最差报"无法播放", 不静默吞文件)
            : Icons.insert_drive_file_outlined,
      ),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: item.isDirectory
          ? const Icon(Icons.chevron_right)
          : progress == null
          ? null
          : const Icon(Icons.history_outlined, size: 18),
      onTap: () => _open(item),
      onLongPress: () => _showItemMenu(item),
    );
  }

  // ==================== 检索 ====================

  void _enterSearch() {
    setState(() {
      _searching = true;
      _searchInfo = '';
    });
  }

  void _exitSearch() {
    _searchDebounce?.cancel();
    _searchFlushTimer?.cancel();
    _searchFlushTimer = null;
    _pendingResults.clear();
    _searchGen++;
    setState(() {
      _searching = false;
      _searchRunning = false;
      _query = '';
      _results = const [];
      _searchInfo = '';
      _searchCtr.clear();
    });
    // 回到浏览态: 顺带把续播进度刷新一下(可能刚在检索结果里播过)
    _refresh();
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    _searchFlushTimer?.cancel();
    _searchFlushTimer = null;
    _pendingResults.clear();
    final gen = ++_searchGen;
    final keyword = value.trim();
    setState(() {
      _query = value;
      if (keyword.isEmpty) {
        _searchRunning = false;
        _results = const [];
        _searchInfo = '';
      } else {
        _searchRunning = true;
        _searchInfo = '正在检索本目录及子目录…';
      }
    });
    if (keyword.isEmpty) {
      return;
    }
    // 输入过程中的抖动不触发全盘递归: 停手 400ms 再查
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        _runSearch(keyword, gen);
      }
    });
  }

  /// 命中结果的增量缓冲 + 节流刷新。
  ///
  /// 每条命中都 setState 会把整张列表重建一遍(大目录里可能一秒几十条),
  /// 所以攒着按 ~120ms 批量刷一次: 既是"边扫边出", 又不会把 UI 拖垮。
  final List<LocalMediaItem> _pendingResults = [];
  Timer? _searchFlushTimer;

  void _scheduleSearchFlush(int gen) {
    if (_searchFlushTimer?.isActive ?? false) {
      return;
    }
    _searchFlushTimer = Timer(const Duration(milliseconds: 120), () {
      _searchFlushTimer = null;
      if (gen != _searchGen || !mounted || _pendingResults.isEmpty) {
        return;
      }
      setState(() {
        _results = [..._results, ..._pendingResults];
        _pendingResults.clear();
        _syncProgress(_results);
      });
    });
  }

  Future<void> _runSearch(String keyword, int gen) async {
    final level = _current;
    _pendingResults.clear();
    final found = await LocalMediaService.search(
      source: level.source,
      rootPath: level.path,
      query: keyword,
      showHidden: _showHidden,
      cancelled: () => gen != _searchGen || !mounted,
      // 命中就先进缓冲并排一次刷新, 不等整棵树扫完
      onFound: (item) {
        if (gen != _searchGen) {
          return;
        }
        _pendingResults.add(item);
        _scheduleSearchFlush(gen);
      },
      onProgress: (dirs, matches) {
        if (gen != _searchGen || !mounted) {
          return;
        }
        setState(
          () => _searchInfo = '已扫描 $dirs 个目录，找到 $matches 个（仍在检索…）',
        );
      },
    );
    _searchFlushTimer?.cancel();
    _searchFlushTimer = null;
    if (gen != _searchGen || !mounted) {
      return;
    }
    setState(() {
      // 以 search 的返回值为准(缓冲里可能还剩没刷出去的)
      _results = found;
      _pendingResults.clear();
      _searchRunning = false;
      _searchInfo = found.isEmpty
          ? '「$keyword」没有匹配的可播放文件'
          : '找到 ${found.length} 个（含子目录，就近的排在前面）';
      _syncProgress(found);
    });
  }

  // ==================== 下载到本机 ====================

  StateSetter? _dlSetState;
  BuildContext? _dlDialogContext;
  int _dlReceived = 0;
  int _dlTotal = 0;
  bool _dlCancelled = false;

  /// 下载一个网络来源的文件到 app 的下载目录。
  ///
  /// 进度用对话框展示（可取消）：大文件动辄几个 GB，没有取消按钮的话
  /// 用户只能干等或者杀进程。
  Future<void> _download(LocalMediaItem item) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _dlCancelled = false;
    _dlReceived = 0;
    _dlTotal = item.size ?? 0;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          _dlDialogContext = dialogContext;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              _dlSetState = setDialogState;
              final known = _dlTotal > 0;
              // 显式 toDouble: num.clamp 的静态类型在某些组合下会退化成 num,
              // 直接喂给 LinearProgressIndicator(value: double?) 会编译不过
              final double? value = known
                  ? (_dlReceived / _dlTotal).clamp(0.0, 1.0).toDouble()
                  : null;
              return AlertDialog(
                title: Text(
                  '下载 ${item.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 10,
                  children: [
                    LinearProgressIndicator(value: value),
                    Text(
                      known
                          ? '${CacheManager.formatSize(_dlReceived)} / '
                              '${CacheManager.formatSize(_dlTotal)}'
                              '  (${(value! * 100).toStringAsFixed(0)}%)'
                          : '已下载 ${CacheManager.formatSize(_dlReceived)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      _dlCancelled = true;
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('取消'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
    try {
      final saved = await LocalMediaService.downloadTo(
        item,
        cancelled: () => _dlCancelled,
        onProgress: (received, total) {
          _dlReceived = received;
          if (total > 0) {
            _dlTotal = total;
          }
          _dlSetState?.call(() {});
        },
      );
      _closeDownloadDialog();
      if (!mounted) {
        return;
      }
      if (saved == null) {
        SmartDialog.showToast(_dlCancelled ? '已取消下载' : '下载失败');
      } else {
        SmartDialog.showToast(
          '已保存到 ${saved.path}',
          displayTime: const Duration(seconds: 4),
        );
      }
    } on Object catch (err) {
      _closeDownloadDialog();
      SmartDialog.showToast('下载失败: $err');
    } finally {
      _dlSetState = null;
      _busy = false;
    }
  }

  void _closeDownloadDialog() {
    final dialogContext = _dlDialogContext;
    _dlDialogContext = null;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
  }

  // ==================== 快捷方式(书签) ====================

  /// 当前层级对应的快捷方式(不可收藏时为 null)
  LocalMediaSource? get _shortcut => LocalMediaController.shortcutFor(
    source: _current.source,
    path: _current.path,
    title: _current.title,
  );

  bool get _isBookmarked {
    final saved = _mediaController?.savedSources;
    final target = _shortcut;
    if (saved == null || target == null) {
      return false;
    }
    return saved.any(
      (e) =>
          e.type == target.type &&
          e.url == target.url &&
          e.subPath == target.subPath,
    );
  }

  Future<void> _addShortcut() async {
    final controller = _mediaController;
    final target = _shortcut;
    if (controller == null || target == null) {
      SmartDialog.showToast('当前目录无法添加为快捷方式');
      return;
    }
    await controller.addSource(target, favorite: true);
    if (mounted) {
      setState(() {}); // 让书签图标立刻变成"已收藏"
    }
    SmartDialog.showToast('已添加「${target.name}」到快捷方式');
  }

  void _showItemMenu(LocalMediaItem item) {
    // SAF 条目显示可读路径(内部存储/Download/…), 网络来源显示脱敏地址
    final masked = LocalMediaService.displayPath(item);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              subtitle: Text(
                [
                  '来源: ${item.source.name}',
                  if (item.size case final size?)
                    '大小: ${CacheManager.formatSize(size)}',
                  if (item.modified case final modified?)
                    '修改: ${_formatDate(modified)}',
                  '路径: $masked',
                ].join('\n'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link),
              title: const Text('复制路径/地址(不含密码)'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                Clipboard.setData(ClipboardData(text: masked));
                SmartDialog.showToast('已复制');
              },
            ),
            // 局域网文件: 下载一份到本机下载目录(离线也能看/避免每次走网络)
            if (item.source.type.isNetwork)
              ListTile(
                dense: true,
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载到本机'),
                subtitle: Text(
                  '保存到下载目录${item.size == null ? '' : '（${CacheManager.formatSize(item.size!)}）'}',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _download(item);
                },
              ),
            if (_progress.containsKey(item.uri))
              ListTile(
                dense: true,
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('清除播放进度'),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  LocalMediaProgress.clear(item.uri);
                  setState(() => _syncProgress(_items));
                  SmartDialog.showToast('已清除');
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _Level {
  _Level({required this.source, required this.path, required this.title});

  /// 中途拿到凭据时要就地换成带账号的副本, 所以不是 final
  LocalMediaSource source;
  final String path;
  final String title;
}
