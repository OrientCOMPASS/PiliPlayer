import 'dart:async';

import 'package:PiliPlus/services/smb/smb2_client.dart';

/// 在一条已认证的 SMB 会话上要执行的活儿
typedef SmbTask<T> = Future<T> Function(Smb2Client client);

/// SMB **会话复用池**（对齐 VLC / libsmb2 的行为）。
///
/// ## 为什么要它
///
/// 以前每次浏览目录、每次播放、每次 seek 都新建一条连接：
/// NEGOTIATE + SESSION_SETUP(NTLM 三个往返) + TREE_CONNECT + CREATE，
/// 局域网里也要 100~300ms。而 mpv / MediaExtractor 是按 `Range` 请求来读的，
/// **每次拖动进度条都要重新握手一遍** —— 这就是局域网播放"拖一下就卡一下"
/// 的直接来源。VLC(libsmb2)、Windows 资源管理器都是复用会话的，这里跟上。
///
/// ## 怎么复用
///
/// 按 `(host, port, share, user, domain)` 分桶，每桶最多 [maxSessionsPerKey] 条：
///
/// * **一条会话同一时刻只跑一个请求**：[Smb2Client] 只有一个 `_waiter`、
///   一套 `_messageId`/信用记账，并发发请求会串包。所以用"连接池 + 借还"
///   而不是"一条连接多路复用"（SMB2 的多路复用要靠 MessageId 分发响应，
///   当前客户端没实现，也不值得为它重写）；
/// * 播放器通常会同时开 1~2 条 HTTP 连接（探测 + 拉流），所以每桶留了
///   几条余量：拿不到空闲会话就新建，到上限才排队等；
/// * **只有连接/会话层面的错误才作废会话**（socket 断了、超时、
///   `USER_SESSION_DELETED`/`NETWORK_SESSION_EXPIRED`）；文件层面的错误
///   （路径不存在、无权限）不该连累整条会话，否则每次点开一个坏文件
///   都要重新握手；
/// * 空闲超过 [idleTimeout] 自动关闭（Samba 默认也会踢掉长时间静默的会话，
///   自己先关比被服务端踢了再发现要好）；
/// * 借出去的会话用完必须归还（[run] 内部已用 try/finally 保证）。
/// 用 `interface` 而不是 `final`: Dart 3 里 `final class` 不允许被
/// implements/extends, 而实现类 `_SmbSessionPool` 需要 implements 它。
abstract interface class SmbSessionPool {
  static final SmbSessionPool instance = _SmbSessionPool();

  /// 每个 (主机, 共享, 账号) 最多同时保留几条会话
  static const int maxSessionsPerKey = 4;

  /// 空闲多久就关掉
  static const Duration idleTimeout = Duration(minutes: 2);

  /// 握手超时
  static const Duration connectTimeout = Duration(seconds: 10);

  /// 在一条（必要时新建的）会话上执行 [body]
  Future<T> run<T>({
    required String host,
    int port = 445,
    required String share,
    String? user,
    String? password,
    String domain = '',
    String? address,
    Duration timeout = connectTimeout,
    required SmbTask<T> body,
  });

  /// 关掉所有会话（切网络、退出板块、应用进后台时调用）
  Future<void> closeAll();

  /// 当前活着的会话数（诊断/测试用）
  int get liveSessions;

  /// 这个错误要不要把会话作废
  static bool isFatalError(Object error) {
    if (error is SmbException) {
      // 会话/连接层面的状态码才作废; 文件层面的错误(路径不存在、无权限、
      // 不是目录)与连接健康无关, 留着会话继续用
      // 只认"会话已经没了"这一类; ACCESS_DENIED 更常见的是某个文件没权限,
      // 为它作废整条会话等于每碰一个坏文件就重新握手, 得不偿失
      return switch (error.status) {
        NtStatus.userSessionDeleted || NtStatus.networkSessionExpired => true,
        _ => false,
      };
    }
    // socket 异常、超时、状态错误……连接已经不可信了
    return true;
  }
}

/// 一条已认证的会话（NEGOTIATE / SESSION_SETUP / TREE_CONNECT 都做完了）
class _Session {
  _Session(this.client);

  final Smb2Client client;
  DateTime lastUsed = DateTime.now();

  void touch() => lastUsed = DateTime.now();

  bool get alive => client.isConnected;

  Future<void> dispose() async {
    try {
      await client.close();
    } catch (_) {}
  }

  @override
  String toString() => 'SmbSession(alive=$alive)';
}

/// 一个 key 对应的小连接池
class _KeyPool {
  _KeyPool({
    required this.host,
    required this.port,
    required this.share,
    required this.user,
    required this.password,
    required this.domain,
    required this.address,
    required this.timeout,
  });

  final String host;
  final int port;
  final String share;
  final String? user;
  final String? password;
  final String domain;
  final String? address;
  final Duration timeout;

  final List<_Session> _idle = [];
  final Set<_Session> _live = {};
  final List<Completer<void>> _waiters = [];
  int _creating = 0;
  Timer? _sweepTimer;

  int get liveCount => _live.length;

  Future<_Session> acquire() async {
    while (true) {
      _sweep();
      while (_idle.isNotEmpty) {
        final session = _idle.removeLast();
        if (session.alive) {
          session.touch();
          return session;
        }
        _live.remove(session);
      }
      if (_live.length + _creating < SmbSessionPool.maxSessionsPerKey) {
        _creating++;
        final client = Smb2Client(
          host: host,
          port: port,
          fallbackAddress: address,
        );
        try {
          await client.connect(
            user: user,
            password: password,
            domain: domain,
            timeout: timeout,
          );
          await client.treeConnect(share);
        } catch (_) {
          // 握手/tree connect 失败要把半开的连接关掉, 否则每次失败漏一个 socket
          try {
            await client.close();
          } catch (_) {}
          rethrow;
        } finally {
          _creating--;
          _wakeWaiter();
        }
        final session = _Session(client);
        _live.add(session);
        return session;
      }
      // 到上限了: 等别人还回来
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  void release(_Session session) {
    if (!_live.contains(session)) {
      return;
    }
    session.touch();
    if (!session.alive) {
      _discard(session);
      return;
    }
    _idle.add(session);
    _scheduleSweep();
    _wakeWaiter();
  }

  void discard(_Session session) => _discard(session);

  void _discard(_Session session) {
    _live.remove(session);
    _idle.remove(session);
    // 关闭是异步的, 但作废路径不能等它(调用方可能在事件回调里),
    // 显式 unawaited 表明"知道这是即发即忘"
    unawaited(session.dispose());
    _wakeWaiter();
  }

  void _wakeWaiter() {
    if (_waiters.isEmpty) {
      return;
    }
    _waiters.removeAt(0).complete();
  }

  void _scheduleSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = Timer(SmbSessionPool.idleTimeout, () {
      _sweep();
      if (_idle.isNotEmpty) {
        _scheduleSweep();
      }
    });
  }

  void _sweep() {
    final deadline = DateTime.now().subtract(SmbSessionPool.idleTimeout);
    for (final session in _idle.toList(growable: false)) {
      if (session.lastUsed.isBefore(deadline) || !session.alive) {
        _discard(session);
      }
    }
    if (_idle.isEmpty) {
      _sweepTimer?.cancel();
      _sweepTimer = null;
    }
  }

  Future<void> closeAll() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final sessions = _live.toList(growable: false);
    _live.clear();
    _idle.clear();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _waiters.clear();
    for (final session in sessions) {
      await session.dispose();
    }
  }
}

class _SmbSessionPool implements SmbSessionPool {
  final Map<String, _KeyPool> _pools = {};

  @override
  int get liveSessions =>
      _pools.values.fold(0, (sum, pool) => sum + pool.liveCount);

  static String _key({
    required String host,
    required int port,
    required String share,
    String? user,
    String domain = '',
  }) => '${host.toLowerCase()}:$port/${share.toLowerCase()}|${user ?? ''}|$domain';

  @override
  Future<T> run<T>({
    required String host,
    int port = 445,
    required String share,
    String? user,
    String? password,
    String domain = '',
    String? address,
    Duration timeout = SmbSessionPool.connectTimeout,
    required SmbTask<T> body,
  }) async {
    final key = _key(
      host: host,
      port: port,
      share: share,
      user: user,
      domain: domain,
    );
    final pool = _pools.putIfAbsent(
      key,
      () => _KeyPool(
        host: host,
        port: port,
        share: share,
        user: user,
        password: password,
        domain: domain,
        address: address,
        timeout: timeout,
      ),
    );
    final session = await pool.acquire();
    try {
      final result = await body(session.client);
      pool.release(session);
      return result;
    } catch (error) {
      if (SmbSessionPool.isFatalError(error)) {
        pool.discard(session);
      } else {
        pool.release(session);
      }
      rethrow;
    }
  }

  @override
  Future<void> closeAll() async {
    final pools = _pools.values.toList(growable: false);
    _pools.clear();
    for (final pool in pools) {
      await pool.closeAll();
    }
  }
}
