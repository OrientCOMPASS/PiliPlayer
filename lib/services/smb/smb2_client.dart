// 协议编解码代码按"每行一个字段"书写更直观, 因此不强制级联写法
// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io' show Socket, SocketOption;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;

import 'package:PiliPlus/services/smb/ntlm.dart';
import 'package:PiliPlus/services/smb/smb_name.dart';

/// SMB2 状态码(只列出会用到的)
abstract final class NtStatus {
  static const int success = 0x00000000;
  static const int pending = 0x00000103;

  /// 注意: MORE_PROCESSING_REQUIRED 是 0xC0000016(NTLM 握手的正常中间态),
  /// 而 INVALID_PARAMETER 是 0xC000000D —— 两者极易记混。
  static const int moreProcessingRequired = 0xc0000016;
  static const int invalidParameter = 0xc000000d;
  static const int unsuccessful = 0xc0000001;
  static const int bufferOverflow = 0x80000005;
  static const int noMoreFiles = 0x80000006;
  static const int endOfFile = 0xc0000011;
  static const int objectNameNotFound = 0xc0000034;
  static const int objectNameCollision = 0xc0000035;
  static const int objectPathNotFound = 0xc000003a;
  static const int accessDenied = 0xc0000022;
  static const int logonFailure = 0xc000006d;
  static const int badNetworkName = 0xc00000cc;
  static const int notADirectory = 0xc0000103;
  static const int userSessionDeleted = 0xc0000203;
  static const int networkSessionExpired = 0xc000035c;

  static const Map<int, String> _names = {
    success: 'SUCCESS',
    moreProcessingRequired: 'MORE_PROCESSING_REQUIRED',
    invalidParameter: 'INVALID_PARAMETER',
    unsuccessful: 'UNSUCCESSFUL',
    bufferOverflow: 'BUFFER_OVERFLOW',
    pending: 'PENDING',
    noMoreFiles: 'NO_MORE_FILES',
    endOfFile: 'END_OF_FILE',
    objectNameNotFound: 'OBJECT_NAME_NOT_FOUND',
    objectNameCollision: 'OBJECT_NAME_COLLISION',
    objectPathNotFound: 'OBJECT_PATH_NOT_FOUND',
    accessDenied: 'ACCESS_DENIED',
    logonFailure: 'LOGON_FAILURE',
    badNetworkName: 'BAD_NETWORK_NAME',
    notADirectory: 'NOT_A_DIRECTORY',
    userSessionDeleted: 'USER_SESSION_DELETED',
    networkSessionExpired: 'NETWORK_SESSION_EXPIRED',
  };

  static String describe(int status) {
    final name = _names[status];
    final hex = '0x${status.toRadixString(16).padLeft(8, '0')}';
    return name == null ? hex : '$name ($hex)';
  }
}

class SmbException implements Exception {
  const SmbException(this.status, [this.context = '']);

  final int status;
  final String context;

  String get statusText => NtStatus.describe(status);

  bool get isNotFound =>
      status == NtStatus.objectNameNotFound ||
      status == NtStatus.objectPathNotFound;
  bool get isAuthFailure =>
      status == NtStatus.logonFailure || status == NtStatus.accessDenied;

  @override
  String toString() =>
      'SmbException: $statusText${context.isEmpty ? '' : ' [$context]'}';
}

/// 服务端自报的身份(NTLMSSP CHALLENGE 的 TargetName 与 AV_PAIR)。
/// 权威主机名来自这里: 优先 DNS 名, 其次 NetBIOS 名, 最后 TargetName。
class SmbServerInfo {
  const SmbServerInfo({
    this.targetName = '',
    this.netbiosName = '',
    this.dnsName = '',
    this.netbiosDomain = '',
    this.dnsDomain = '',
  });

  final String targetName;
  final String netbiosName;
  final String dnsName;
  final String netbiosDomain;
  final String dnsDomain;

  /// 最适合展示/写进 smb:// 地址的名字(不含域前缀)。
  /// 优先真正的 FQDN(带点), 其次 NetBIOS 名; Samba 在没配 DNS 时会发
  /// `c-xxxx` 这类合成名, 排在 NetBIOS 名之后。
  String? get bestName {
    final candidates = [
      if (dnsName.contains('.')) dnsName,
      netbiosName,
      dnsName,
      targetName,
    ];
    for (final candidate in candidates) {
      final name = candidate.split('.').first.trim();
      if (name.isNotEmpty) {
        return name;
      }
    }
    return null;
  }

  @override
  String toString() =>
      'SmbServerInfo(target=$targetName, nb=$netbiosName, dns=$dnsName)';
}

/// 目录项
class SmbEntry {
  const SmbEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    this.modified,
    this.created,
    this.attributes = 0,
  });

  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
  final DateTime? created;
  final int attributes;

  @override
  String toString() =>
      'SmbEntry(${isDirectory ? 'D' : 'F'} $name, $size'
      '${modified == null ? '' : ', $modified'})';
}

/// 文件基本信息
class SmbFileInfo {
  const SmbFileInfo({
    required this.size,
    required this.isDirectory,
    this.modified,
  });

  final int size;
  final bool isDirectory;
  final DateTime? modified;
}

Uint8List _utf16(String s) {
  final out = ByteData(s.length * 2);
  for (var i = 0; i < s.length; i++) {
    out.setUint16(i * 2, s.codeUnitAt(i), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Windows FILETIME -> DateTime(公开以便单元测试)
DateTime? fileTimeToDateTime(int ticks) {
  if (ticks <= 0) {
    return null;
  }
  // 1601-01-01 到 1970-01-01 的 100ns 计数
  const epochDelta = 11644473600 * 10000000;
  final micros = (ticks - epochDelta) ~/ 10;
  // 早于 1970 或明显超出合理范围的时间戳视为无效(服务端常填 0)
  if (micros < 0 || micros > 32503680000 * 1000000) {
    return null;
  }
  return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true).toLocal();
}

/// 纯 Dart 的最小 SMB2 客户端(只读浏览 + 读取)。
///
/// 为什么自己实现: 安卓端打包的 FFmpeg 只启用了
/// file/http/https/ftp/hls/tcp/tls 等协议, **没有 smb**, 所以 mpv 无法直接
/// 播放 smb:// 地址。这里的做法是: 用本客户端浏览/读取 SMB 共享,
/// 再通过本机回环 HTTP 代理喂给 mpv(见 `local_media_proxy.dart`)。
///
/// 实现范围(够用且可验证):
///   * 方言 0x0202 / 0x0210(不协商 3.x: 3.x 的签名要 AES-CMAC, 加密要 AES-CTR)
///   * NTLMv2 认证 + 匿名/guest
///   * 需要时按 SMB2 规范做 HMAC-SHA256 签名
///   * TREE_CONNECT / CREATE / QUERY_DIRECTORY / READ / CLOSE
/// 不实现: 写入、oplock、lease、多通道、加密、DFS。
class Smb2Client {
  Smb2Client({
    required this.host,
    this.port = 445,
    this.workstation = 'PILIPLAYER',
    this.maxReadSize = 1 << 20,
    this.fallbackAddress,
  });

  /// 主机名或 IP。主机名在 [connect] 时经 DNS/NBNS 解析(见 `smb_name.dart`)
  final String host;
  final int port;
  final String workstation;

  /// 单次 READ 请求的最大字节数(会被服务端 MaxReadSize 再夹一次)
  final int maxReadSize;

  /// 解析失败时的兜底 IP(发现阶段拿到的地址)
  final String? fallbackAddress;

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final List<Uint8List> _chunks = [];
  int _buffered = 0;
  Completer<void>? _waiter;
  Object? _streamError;

  int _messageId = 0;
  int _sessionId = 0;
  int _treeId = 0;
  int _dialect = 0;
  bool _signingEnabled = false;
  bool _signingRequired = false;
  int _serverMaxReadSize = 1 << 20;
  Uint8List? _sessionKey;
  bool _closed = false;

  /// SMB2 信用(credit)记账。
  ///
  /// 服务端按信用授权: 一条 READ 的 CreditCharge = ceil(length / 65536),
  /// 用掉超过已授予的信用会被服务端直接断开
  /// (Samba 日志: "client used more credits than granted")。
  int _creditsGranted = 0;
  int _creditsUsed = 0;
  int get _creditsAvailable => _creditsGranted - _creditsUsed;

  /// 每次请求顺带申请一个较大窗口, 大块 READ 才有信用可用
  static const int _creditWindow = 64;

  int get dialect => _dialect;
  int get sessionId => _sessionId;
  bool get isSigningActive => _signingEnabled && _sessionKey != null;
  bool get isConnected => _socket != null && !_closed;

  /// 服务端身份(CHALLENGE 解析成功后可用)
  SmbServerInfo? serverInfo;

  /// 实际解析并连接到的 IP 地址
  String? resolvedAddress;

  // ==================== 连接与协商 ====================

  Future<void> connect({
    String? user,
    String? password,
    String domain = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // 尽量按主机名连接: IP 字面量直通, 名字走 DNS -> NBNS -> 兜底 IP
    final address = await SmbName.resolve(host, fallbackAddress: fallbackAddress);
    resolvedAddress = address;
    final socket = await Socket.connect(address, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _attach(socket);
    await negotiate();
    await sessionSetup(user: user, password: password, domain: domain);
  }

  void _attach(Socket socket) {
    _subscription = socket.listen(
      (data) {
        _chunks.add(data);
        _buffered += data.length;
        _wake();
      },
      onError: (Object error) {
        // 一定要有人接住 socket 的异步错误, 否则会变成未捕获异常直接崩掉 isolate
        _streamError ??= error;
        _wake();
      },
      onDone: () {
        _streamError ??= const SocketExceptionLike('smb: 连接被对端关闭');
        _wake();
      },
      cancelOnError: false,
    );
  }

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete();
    }
  }

  Future<Uint8List> _readExact(int length) async {
    if (_socket == null) {
      throw StateError('smb: not connected');
    }
    while (_buffered < length) {
      final error = _streamError;
      if (error != null) {
        throw error;
      }
      final waiter = Completer<void>();
      _waiter = waiter;
      await waiter.future;
    }
    final out = Uint8List(length);
    var written = 0;
    while (written < length) {
      final chunk = _chunks.first;
      final take = chunk.length < length - written
          ? chunk.length
          : length - written;
      out.setRange(written, written + take, chunk);
      written += take;
      if (take == chunk.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = chunk.sublist(take);
      }
    }
    _buffered -= length;
    return out;
  }

  /// 读一个完整的 SMB2 消息(带 NetBIOS 会话服务 4 字节头)
  Future<Uint8List> _readMessage() async {
    final header = await _readExact(4);
    if (header[0] != 0) {
      throw SocketExceptionLike(
        'smb: 非法的 NetBIOS 消息类型 0x${header[0].toRadixString(16)}',
      );
    }
    final length =
        (header[1] << 16) | (header[2] << 8) | header[3];
    if (length <= 0 || length > (1 << 26)) {
      throw SocketExceptionLike('smb: 非法的消息长度 $length');
    }
    final body = await _readExact(length);
    if (body.length < 64 ||
        body[0] != 0xfe ||
        body[1] != 0x53 ||
        body[2] != 0x4d ||
        body[3] != 0x42) {
      throw const SocketExceptionLike('smb: 不是 SMB2 响应');
    }
    return body;
  }

  void _sendMessage(Uint8List message) {
    final socket = _socket;
    if (socket == null || _closed) {
      throw const SocketExceptionLike('smb: 连接已关闭');
    }
    final header = Uint8List(4);
    header[0] = 0;
    header[1] = (message.length >> 16) & 0xff;
    header[2] = (message.length >> 8) & 0xff;
    header[3] = message.length & 0xff;
    socket
      ..add(header)
      ..add(message);
  }

  /// 组装 SMB2 消息: 64 字节头 + body, 必要时签名
  Uint8List _build(
    int command,
    Uint8List body, {
    int creditCharge = 1,
    int? treeId,
  }) {
    final charge = creditCharge < 1 ? 1 : creditCharge;
    final message = Uint8List(64 + body.length);
    final bd = ByteData.sublistView(message);
    message[0] = 0xfe;
    message[1] = 0x53; // S
    message[2] = 0x4d; // M
    message[3] = 0x42; // B
    bd.setUint16(4, 64, Endian.little); // StructureSize
    bd.setUint16(6, charge, Endian.little); // CreditCharge
    bd.setUint32(8, 0, Endian.little); // Status
    bd.setUint16(12, command, Endian.little);
    // CreditRequest: 覆盖本次消耗, 同时把窗口申请到 _creditWindow
    bd.setUint16(
      14,
      charge > _creditWindow ? charge : _creditWindow,
      Endian.little,
    );
    bd.setUint32(16, 0, Endian.little); // Flags
    bd.setUint32(20, 0, Endian.little); // NextCommand
    bd.setUint64(24, _messageId, Endian.little);
    bd.setUint32(32, 0, Endian.little); // ProcessId
    bd.setUint32(36, treeId ?? _treeId, Endian.little);
    bd.setUint64(40, _sessionId, Endian.little);
    message.setRange(64, message.length, body);

    final key = _sessionKey;
    if (_signingEnabled && key != null && _sessionId != 0) {
      bd.setUint32(16, 0x00000008, Endian.little); // SMB2_FLAGS_SIGNED
      message.setRange(48, 64, Uint8List(16)); // 签名区先置零
      final sig = Hmac(sha256, key).convert(message).bytes.sublist(0, 16);
      message.setRange(48, 64, sig);
    }
    // MessageId 按 CreditCharge 递增(MS-SMB2 3.2.4.1.3):
    // 一条 charge=8 的请求会消耗 8 个序号, 否则服务端会报
    // "bad message_id N (granted = X, low = N+charge)"
    _messageId += charge;
    _creditsUsed += charge;
    return message;
  }

  /// 发送请求并读取响应(自动处理 STATUS_PENDING 与复合消息)
  Future<Uint8List> _request(
    int command,
    Uint8List body, {
    int creditCharge = 1,
    bool allowMoreProcessing = false,
  }) async {
    _sendMessage(_build(command, body, creditCharge: creditCharge));
    while (true) {
      final response = await _readMessage();
      final bd = ByteData.sublistView(response);
      // 响应头 offset 14 = CreditRequestResponse: 本次授予的信用
      _creditsGranted += bd.getUint16(14, Endian.little);
      final status = bd.getUint32(8, Endian.little);
      if (status == NtStatus.pending) {
        continue;
      }
      if (allowMoreProcessing && status == NtStatus.moreProcessingRequired) {
        _sessionId = bd.getUint64(40, Endian.little);
        return response;
      }
      if (status != NtStatus.success) {
        return response; // 交给调用方判断(有些状态码是正常流程)
      }
      return response;
    }
  }

  Future<void> negotiate() async {
    const dialects = [0x0202, 0x0210];
    final body = Uint8List(36 + 2 * dialects.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 36, Endian.little); // StructureSize
    bd.setUint16(2, dialects.length, Endian.little);
    bd.setUint16(4, 1, Endian.little); // SecurityMode: signing enabled
    bd.setUint16(6, 0, Endian.little); // Reserved
    bd.setUint32(8, 0, Endian.little); // Capabilities (2.x 必须为 0)
    // ClientGuid: 固定值即可(会话缓存用)
    body.setRange(12, 28, List<int>.generate(16, (i) => 0x50 + i));
    // ClientStartTime(28..35) = 0
    for (var i = 0; i < dialects.length; i++) {
      bd.setUint16(36 + i * 2, dialects[i], Endian.little);
    }

    final res = await _request(0x0000, body);
    final bd2 = ByteData.sublistView(res);
    final status = bd2.getUint32(8, Endian.little);
    if (status != NtStatus.success) {
      throw SmbException(status, 'negotiate');
    }
    // NEGOTIATE 响应(相对 body): SecurityMode@2, DialectRevision@4,
    // MaxReadSize@32, SecurityBufferOffset@56, SecurityBufferLength@58
    final securityMode = bd2.getUint16(64 + 2, Endian.little);
    _dialect = bd2.getUint16(64 + 4, Endian.little);
    _signingEnabled = securityMode & 0x01 != 0;
    _signingRequired = securityMode & 0x02 != 0;
    _serverMaxReadSize = bd2.getUint32(64 + 32, Endian.little);
    if (_serverMaxReadSize <= 0 || _serverMaxReadSize > (1 << 26)) {
      _serverMaxReadSize = 1 << 20;
    }
  }

  /// NTLMSSP 认证。user 为空时走匿名(由服务端映射为 guest)。
  Future<void> sessionSetup({
    String? user,
    String? password,
    String domain = '',
  }) async {
    final anonymous = user == null || user.isEmpty;

    Uint8List buildRequest(Uint8List securityBuffer) {
      final body = Uint8List(24 + securityBuffer.length);
      final bd = ByteData.sublistView(body);
      bd.setUint16(0, 25, Endian.little); // StructureSize
      body[2] = 0; // Flags
      // SecurityMode: 1 = signing enabled, 3 = enabled + required
      body[3] = _signingRequired ? 3 : 1;
      bd.setUint64(4, 0, Endian.little); // PreviousSessionId
      bd.setUint16(12, 64 + 24, Endian.little); // SecurityBufferOffset
      bd.setUint16(14, securityBuffer.length, Endian.little);
      body.setRange(24, body.length, securityBuffer);
      return body;
    }

    // ---- Type 1 (SPNEGO negTokenInit 包装) ----
    final type1 = spnegoNegTokenInit(buildType1(workstation: workstation));
    var res = await _request(
      0x0001,
      buildRequest(type1),
      allowMoreProcessing: true,
    );
    var bd = ByteData.sublistView(res);
    var status = bd.getUint32(8, Endian.little);
    if (status != NtStatus.moreProcessingRequired &&
        status != NtStatus.success) {
      throw SmbException(status, 'session setup (negotiate)');
    }
    _sessionId = bd.getUint64(40, Endian.little);

    final securityBuffer = _extractSecurityBuffer(res);
    final challenge = unwrapNtlm(securityBuffer) ?? securityBuffer;
    final parsed = NtlmChallenge.parse(challenge);
    if (parsed == null) {
      throw const SocketExceptionLike('smb: 无法解析 NTLMSSP Type2');
    }
    // 服务端身份: 展示与"尽量用主机名"都靠它(AV_PAIR 优先于 TargetName)
    final av = parsed.avPairs();
    serverInfo = SmbServerInfo(
      targetName: parsed.targetName,
      netbiosName: av[NtlmChallenge.avNbComputerName] ?? '',
      dnsName: av[NtlmChallenge.avDnsComputerName] ?? '',
      netbiosDomain: av[NtlmChallenge.avNbDomainName] ?? '',
      dnsDomain: av[NtlmChallenge.avDnsDomainName] ?? '',
    );

    // ---- Type 3 ----
    Uint8List sessionKey;
    Uint8List type3;
    if (anonymous) {
      type3 = spnegoNegTokenResp(buildAnonymousType3(parsed));
      sessionKey = Uint8List(16);
    } else {
      final auth = authenticate(
        challenge: parsed,
        user: user,
        password: password ?? '',
        domain: domain,
        workstation: workstation,
      );
      type3 = spnegoNegTokenResp(auth.type3);
      sessionKey = auth.sessionKey;
    }
    // 注意: Type3 这条 SESSION_SETUP **不能签名** —— 服务端要处理完 Type3
    // 才有会话密钥, 提前签名会被回 NT_STATUS_INVALID_HANDLE 并断开连接
    // (Samba 日志: "smb2_signing_sign_pdu: No signing key for SMB2 signing")。
    res = await _request(0x0001, buildRequest(type3));
    bd = ByteData.sublistView(res);
    status = bd.getUint32(8, Endian.little);
    if (status != NtStatus.success) {
      throw SmbException(status, 'session setup (authenticate)');
    }
    _sessionId = bd.getUint64(40, Endian.little);
    // 会话建立后, 后续请求按协商结果签名
    _sessionKey = sessionKey;
  }

  /// 从响应里取出 SecurityBuffer(偏移按 SMB2 惯例是相对消息头起始)
  Uint8List _extractSecurityBuffer(Uint8List response) {
    final bd = ByteData.sublistView(response);
    // NEGOTIATE(32/34) 与 SESSION_SETUP(4/6) 的偏移不同, 这里按命令区分
    final command = bd.getUint16(12, Endian.little);
    final int relOffset;
    final int length;
    if (command == 0x0001) {
      // SESSION_SETUP 响应: SecurityBufferOffset@4, Length@6
      relOffset = bd.getUint16(64 + 4, Endian.little);
      length = bd.getUint16(64 + 6, Endian.little);
    } else {
      // NEGOTIATE 响应: SecurityBufferOffset@56, Length@58
      relOffset = bd.getUint16(64 + 56, Endian.little);
      length = bd.getUint16(64 + 58, Endian.little);
    }
    // 有些实现给的是相对 body 的偏移, 两种都试
    for (final base in [0, 64]) {
      final start = relOffset - base;
      if (start >= 0 && length > 0 && start + length <= response.length) {
        final buf = response.sublist(start, start + length);
        if (buf.length >= 8 &&
            buf[0] == 0x4e &&
            buf[1] == 0x54 &&
            buf[2] == 0x4c &&
            buf[3] == 0x4d) {
          return buf;
        }
      }
    }
    // 兜底: 直接搜索 NTLMSSP 签名
    for (var i = 64; i + 8 <= response.length; i++) {
      if (response[i] == 0x4e &&
          response[i + 1] == 0x54 &&
          response[i + 2] == 0x4c &&
          response[i + 3] == 0x4d &&
          response[i + 4] == 0x53 &&
          response[i + 5] == 0x53 &&
          response[i + 6] == 0x50 &&
          response[i + 7] == 0x00) {
        return response.sublist(i);
      }
    }
    throw const SocketExceptionLike('smb: 响应中找不到 NTLMSSP 缓冲区');
  }

  // ==================== 共享与目录 ====================

  Future<void> treeConnect(String share) async {
    final path = _utf16('\\\\$host\\$share');
    final body = Uint8List(8 + path.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 9, Endian.little); // StructureSize
    bd.setUint16(2, 0, Endian.little); // Flags/Reserved
    bd.setUint16(4, 64 + 8, Endian.little); // PathOffset
    bd.setUint16(6, path.length, Endian.little);
    body.setRange(8, body.length, path);

    final res = await _request(0x0003, body);
    final bd2 = ByteData.sublistView(res);
    final status = bd2.getUint32(8, Endian.little);
    if (status != NtStatus.success) {
      throw SmbException(status, 'tree connect \\\\$host\\$share');
    }
    _treeId = bd2.getUint32(36, Endian.little);
  }

  /// 打开一个对象, 返回 (persistentFileId, volatileFileId, endOfFile, attributes)
  ///
  /// [pipe] 为 true 时按命名管道打开(读写权限, 不带目录/非目录约束),
  /// 供 SRVSVC 共享枚举使用。
  Future<({int persistent, int volatile, int size, int attributes})> _create(
    String relativePath, {
    required bool directory,
    bool pipe = false,
  }) async {
    final name = _utf16(relativePath);
    // StructureSize=57 意味着 body 至少要 57 字节: 打开共享根目录时文件名为空,
    // 也必须补 1 字节 buffer, 否则 Samba 回 STATUS_INVALID_PARAMETER
    final body = Uint8List(56 + (name.isEmpty ? 1 : name.length));
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 57, Endian.little); // StructureSize
    body[2] = 0; // SecurityFlags
    body[3] = 0; // RequestedOplockLevel
    bd.setUint32(4, 2, Endian.little); // ImpersonationLevel = Impersonation
    bd.setUint64(8, 0, Endian.little); // SmbCreateFlags
    bd.setUint64(16, 0, Endian.little); // Reserved
    const fileReadData = 0x00000001;
    const fileWriteData = 0x00000002;
    const fileAppendData = 0x00000004;
    const fileReadEa = 0x00000008;
    const fileWriteEa = 0x00000010;
    const fileListDirectory = 0x00000001;
    const fileReadAttributes = 0x00000080;
    const readControl = 0x00020000;
    const synchronize = 0x00100000;
    // 管道的期望访问与 smbclient 打开 \srvsvc 时一致(0x0012019f)
    bd.setUint32(
      24,
      pipe
          ? fileReadData |
                fileWriteData |
                fileAppendData |
                fileReadEa |
                fileWriteEa |
                fileReadAttributes |
                readControl |
                synchronize
          : (directory ? fileListDirectory : fileReadData) |
                fileReadAttributes |
                readControl |
                synchronize,
      Endian.little,
    );
    // 与 smbclient 抓包一致: 目录用 FILE_DIRECTORY_FILE, 文件用
    // FILE_NON_DIRECTORY_FILE(0x40)
    bd.setUint32(28, pipe ? 0 : (directory ? 0x10 : 0), Endian.little);
    bd.setUint32(32, 0x00000007, Endian.little); // ShareAccess R|W|D
    bd.setUint32(36, 1, Endian.little); // CreateDisposition = FILE_OPEN
    bd.setUint32(
      40,
      pipe ? 0 : (directory ? 0x00000001 : 0x00000040),
      Endian.little,
    ); // CreateOptions
    bd.setUint16(44, 64 + 56, Endian.little); // NameOffset
    bd.setUint16(46, name.length, Endian.little);
    bd.setUint32(48, 0, Endian.little); // CreateContextsOffset
    bd.setUint32(52, 0, Endian.little); // CreateContextsLength
    if (name.isNotEmpty) {
      body.setRange(56, 56 + name.length, name);
    }

    final res = await _request(0x0005, body);
    final bd2 = ByteData.sublistView(res);
    final status = bd2.getUint32(8, Endian.little);
    if (status != NtStatus.success) {
      throw SmbException(status, 'create $relativePath');
    }
    final size = bd2.getUint64(64 + 48, Endian.little);
    final attributes = bd2.getUint32(64 + 56, Endian.little);
    final persistent = bd2.getUint64(64 + 64, Endian.little);
    final volatile = bd2.getUint64(64 + 72, Endian.little);
    return (
      persistent: persistent,
      volatile: volatile,
      size: size,
      attributes: attributes,
    );
  }

  /// 在当前树(需先连接 IPC 管理共享)上打开一个命名管道
  Future<({int persistent, int volatile, int size, int attributes})>
  createPipe(String pipeName) {
    return _create(_normalizePath(pipeName), directory: false, pipe: true);
  }

  Future<void> closeFile(int persistent, int volatile) =>
      _close(persistent, volatile);

  /// 断开当前树连接(树 ID 清零; 失败忽略)
  Future<void> treeDisconnect() async {
    if (_treeId == 0) {
      return;
    }
    final tree = _treeId;
    _treeId = 0;
    try {
      final body = Uint8List(4);
      ByteData.sublistView(body).setUint16(0, 4, Endian.little);
      _sendMessage(_build(0x0004, body, treeId: tree));
      await _readMessage();
    } catch (_) {
      // 断开失败无所谓
    }
  }

  Future<void> _close(int persistent, int volatile) async {
    final body = Uint8List(24);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 24, Endian.little);
    bd.setUint16(2, 0, Endian.little); // Flags
    bd.setUint16(4, 0, Endian.little); // Reserved
    bd.setUint64(8, persistent, Endian.little);
    bd.setUint64(16, volatile, Endian.little);
    await _request(0x0006, body);
  }

  /// 查询对象信息(大小 / 是否目录)。目录用 FILE_DIRECTORY_FILE 打开会失败,
  /// 因此先按文件打开, 失败再按目录打开。
  Future<SmbFileInfo> stat(String relativePath) async {
    final path = _normalizePath(relativePath);
    try {
      final f = await _create(path, directory: false);
      await _close(f.persistent, f.volatile);
      return SmbFileInfo(
        size: f.size,
        isDirectory: f.attributes & 0x10 != 0,
      );
    } on SmbException {
      final d = await _create(path, directory: true);
      await _close(d.persistent, d.volatile);
      return const SmbFileInfo(size: 0, isDirectory: true);
    }
  }

  /// 列目录。[path] 为共享内的相对路径, 根目录传 '' 或 '\'。
  Future<List<SmbEntry>> listDirectory(String path) async {
    final normalized = _normalizePath(path);
    final handle = await _create(normalized, directory: true);
    try {
      final entries = <SmbEntry>[];
      var first = true;
      while (true) {
        final res = await _queryDirectory(
          handle.persistent,
          handle.volatile,
          restart: first,
        );
        first = false;
        final bd = ByteData.sublistView(res);
        final status = bd.getUint32(8, Endian.little);
        if (status == NtStatus.noMoreFiles) {
          break;
        }
        if (status != NtStatus.success) {
          throw SmbException(status, 'query directory $normalized');
        }
        final offset = bd.getUint16(64 + 2, Endian.little);
        final length = bd.getUint32(64 + 4, Endian.little);
        final start = offset >= 64 ? offset - 64 : offset;
        if (length == 0 || start < 0 || start + length > res.length - 64) {
          break;
        }
        entries.addAll(
          parseFileIdBothDirectory(
            res.sublist(64 + start, 64 + start + length),
          ),
        );
      }
      entries.removeWhere((e) => e.name == '.' || e.name == '..');
      return entries;
    } finally {
      await _close(handle.persistent, handle.volatile);
    }
  }

  Future<Uint8List> _queryDirectory(
    int persistent,
    int volatile, {
    required bool restart,
  }) {
    const pattern = '*';
    final name = _utf16(pattern);
    final body = Uint8List(32 + name.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 33, Endian.little); // StructureSize
    body[2] = 37; // FileIdBothDirectoryInformation
    body[3] = restart ? 0x01 : 0x00; // SMB2_RESTART_SCANS
    bd.setUint32(4, 0, Endian.little); // FileIndex
    bd.setUint64(8, persistent, Endian.little);
    bd.setUint64(16, volatile, Endian.little);
    bd.setUint16(24, 64 + 32, Endian.little); // FileNameOffset
    bd.setUint16(26, name.length, Endian.little);
    bd.setUint32(28, 65536, Endian.little); // OutputBufferLength
    body.setRange(32, body.length, name);
    return _request(0x000e, body);
  }

  /// 解析 FileIdBothDirectoryInformation (class 37) 链表。
  /// 公开出来是为了能在没有 SMB 服务端的环境下做单元测试。
  static List<SmbEntry> parseFileIdBothDirectory(Uint8List buffer) {
    final out = <SmbEntry>[];
    var offset = 0;
    final bd = ByteData.sublistView(buffer);
    while (offset + 104 <= buffer.length) {
      final next = bd.getUint32(offset, Endian.little);
      final lastWrite = bd.getUint64(offset + 24, Endian.little);
      final creation = bd.getUint64(offset + 8, Endian.little);
      final size = bd.getUint64(offset + 40, Endian.little);
      final attributes = bd.getUint32(offset + 56, Endian.little);
      final nameLength = bd.getUint32(offset + 60, Endian.little);
      final nameStart = offset + 104;
      if (nameLength > 0 && nameStart + nameLength <= buffer.length) {
        final nameBytes = buffer.sublist(nameStart, nameStart + nameLength);
        final units = <int>[];
        for (var i = 0; i + 1 < nameBytes.length; i += 2) {
          units.add(nameBytes[i] | (nameBytes[i + 1] << 8));
        }
        out.add(
          SmbEntry(
            name: String.fromCharCodes(units),
            isDirectory: attributes & 0x10 != 0,
            size: size,
            modified: fileTimeToDateTime(lastWrite),
            created: fileTimeToDateTime(creation),
            attributes: attributes,
          ),
        );
      }
      if (next == 0) {
        break;
      }
      offset += next;
    }
    return out;
  }

  // ==================== 读取 ====================

  int get _effectiveReadChunk {
    final server = _serverMaxReadSize;
    return (maxReadSize < server ? maxReadSize : server).clamp(4096, 1 << 22);
  }

  /// 打开文件并返回大小与句柄(调用方负责 close)
  Future<({int persistent, int volatile, int size})> openFile(
    String path,
  ) async {
    final handle = await _create(_normalizePath(path), directory: false);
    return (
      persistent: handle.persistent,
      volatile: handle.volatile,
      size: handle.size,
    );
  }

  /// 读取一段数据
  Future<Uint8List> read(
    int persistent,
    int volatile,
    int offset,
    int length,
  ) async {
    // 按已授予的信用裁剪本次读取长度(1 信用 = 64KB)
    var want = length;
    if (_creditsAvailable < 1) {
      await echo(); // 信用见底, 先用 ECHO 把窗口补回来
    }
    final budget = _creditsAvailable * 65536;
    if (budget > 0 && want > budget) {
      want = budget;
    }
    // StructureSize=49: 48 字节固定字段 + 1 字节空 buffer; Padding 必须为 0
    // (抓包对比 smbclient 得到的结论, 写成 0x50 会被回 INVALID_PARAMETER)
    final body = Uint8List(49);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 49, Endian.little); // StructureSize
    body[2] = 0; // Padding
    body[3] = 0; // Flags
    bd.setUint32(4, want, Endian.little);
    bd.setUint64(8, offset, Endian.little);
    bd.setUint64(16, persistent, Endian.little);
    bd.setUint64(24, volatile, Endian.little);
    bd.setUint32(32, 0, Endian.little); // MinimumCount
    bd.setUint32(36, 0, Endian.little); // Channel
    bd.setUint32(40, 0, Endian.little); // RemainingBytes
    bd.setUint16(44, 0, Endian.little); // ReadChannelInfoOffset
    bd.setUint16(46, 0, Endian.little); // ReadChannelInfoLength

    final creditCharge = (want + 65535) ~/ 65536;
    final res = await _request(
      0x0008,
      body,
      creditCharge: creditCharge < 1 ? 1 : creditCharge,
    );
    final bd2 = ByteData.sublistView(res);
    final status = bd2.getUint32(8, Endian.little);
    if (status == NtStatus.endOfFile) {
      return Uint8List(0);
    }
    if (status != NtStatus.success) {
      throw SmbException(status, 'read @$offset+$want');
    }
    final dataOffset = bd2.getUint8(64 + 2);
    final dataLength = bd2.getUint32(64 + 4, Endian.little);
    if (dataLength == 0) {
      return Uint8List(0);
    }
    final start = dataOffset >= 64 ? dataOffset - 64 : dataOffset;
    if (start < 0 || start + dataLength > res.length - 64) {
      throw const SocketExceptionLike('smb: READ 响应的数据区越界');
    }
    return res.sublist(64 + start, 64 + start + dataLength);
  }

  /// 以流的方式读取文件(支持 Range, 供本机 HTTP 代理转发给 mpv)
  Stream<Uint8List> openRead(
    String path, {
    int start = 0,
    int? end,
    int? chunkSize,
  }) async* {
    final handle = await openFile(path);
    final total = handle.size;
    var offset = start.clamp(0, total);
    final last = end == null ? total : (end < total ? end : total);
    final chunk = chunkSize ?? _effectiveReadChunk;
    try {
      while (offset < last) {
        final want = (last - offset) < chunk ? (last - offset) : chunk;
        final data = await read(handle.persistent, handle.volatile, offset, want);
        if (data.isEmpty) {
          break;
        }
        offset += data.length;
        yield data;
      }
    } finally {
      await _close(handle.persistent, handle.volatile);
    }
  }

  // ==================== 其它 ====================

  /// 向命名管道写入完整数据(SMB2 WRITE, 支持分段与部分写入重试)
  Future<void> pipeWrite(int persistent, int volatile, Uint8List data) async {
    var offset = 0;
    while (offset < data.length) {
      final chunkLen = data.length - offset;
      // WRITE body 固定部分 48 字节, DataOffset = 64 + 48
      final body = Uint8List(48 + chunkLen);
      final bd = ByteData.sublistView(body);
      bd.setUint16(0, 49, Endian.little); // StructureSize
      bd.setUint16(2, 64 + 48, Endian.little); // DataOffset
      bd.setUint32(4, chunkLen, Endian.little); // Length
      bd.setUint64(8, 0, Endian.little); // Offset(管道忽略)
      bd.setUint64(16, persistent, Endian.little);
      bd.setUint64(24, volatile, Endian.little);
      bd.setUint32(32, 0, Endian.little); // Channel
      bd.setUint32(36, 0, Endian.little); // RemainingBytes
      bd.setUint16(40, 0, Endian.little); // WriteChannelInfoOffset
      bd.setUint16(42, 0, Endian.little); // WriteChannelInfoLength
      bd.setUint32(44, 0, Endian.little); // Flags
      body.setRange(48, body.length, data, offset);

      final charge = (chunkLen + 65535) ~/ 65536;
      final res = await _request(
        0x0009,
        body,
        creditCharge: charge < 1 ? 1 : charge,
      );
      final bd2 = ByteData.sublistView(res);
      final status = bd2.getUint32(8, Endian.little);
      if (status != NtStatus.success) {
        throw SmbException(status, 'pipe write @$offset+$chunkLen');
      }
      final count = bd2.getUint32(64 + 4, Endian.little);
      if (count <= 0) {
        throw const SocketExceptionLike('smb: 管道写入返回 0 字节');
      }
      offset += count;
    }
  }

  /// 从命名管道读一次数据。
  /// STATUS_BUFFER_OVERFLOW 表示"还有更多", 与 SUCCESS 一样返回已读数据;
  /// 其余状态抛 [SmbException]。
  Future<Uint8List> pipeRead(int persistent, int volatile, int length) async {
    if (_creditsAvailable < 1) {
      await echo();
    }
    var want = length < 1 ? 1 : length;
    final budget = _creditsAvailable * 65536;
    if (budget > 0 && want > budget) {
      want = budget;
    }
    final body = Uint8List(49);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 49, Endian.little); // StructureSize
    body[2] = 0; // Padding
    body[3] = 0; // Flags
    bd.setUint32(4, want, Endian.little);
    bd.setUint64(8, 0, Endian.little); // Offset(管道忽略)
    bd.setUint64(16, persistent, Endian.little);
    bd.setUint64(24, volatile, Endian.little);
    bd.setUint32(32, 1, Endian.little); // MinimumCount = 1
    bd.setUint32(36, 0, Endian.little); // Channel
    bd.setUint32(40, 0, Endian.little); // RemainingBytes
    bd.setUint16(44, 0, Endian.little); // ReadChannelInfoOffset
    bd.setUint16(46, 0, Endian.little); // ReadChannelInfoLength

    final charge = (want + 65535) ~/ 65536;
    final res = await _request(
      0x0008,
      body,
      creditCharge: charge < 1 ? 1 : charge,
    );
    final bd2 = ByteData.sublistView(res);
    final status = bd2.getUint32(8, Endian.little);
    if (status != NtStatus.success && status != NtStatus.bufferOverflow) {
      if (status == NtStatus.endOfFile) {
        return Uint8List(0);
      }
      throw SmbException(status, 'pipe read');
    }
    final dataOffset = bd2.getUint8(64 + 2);
    final dataLength = bd2.getUint32(64 + 4, Endian.little);
    if (dataLength == 0) {
      return Uint8List(0);
    }
    final start = dataOffset >= 64 ? dataOffset - 64 : dataOffset;
    if (start < 0 || start + dataLength > res.length - 64) {
      throw const SocketExceptionLike('smb: 管道 READ 响应的数据区越界');
    }
    return res.sublist(64 + start, 64 + start + dataLength);
  }

  Future<void> echo() async {
    final body = Uint8List(4);
    ByteData.sublistView(body).setUint16(0, 4, Endian.little);
    await _request(0x000d, body);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      final body = Uint8List(4);
      ByteData.sublistView(body).setUint16(0, 4, Endian.little);
      // 礼貌性地断开共享与会话; 服务端可能已经先关了, 失败直接忽略
      if (_treeId != 0) {
        await _request(0x0004, body).timeout(const Duration(seconds: 3));
      }
      if (_sessionId != 0) {
        await _request(0x0002, body).timeout(const Duration(seconds: 3));
      }
    } catch (_) {
      // 关闭失败无所谓
    } finally {
      _treeId = 0;
      _sessionId = 0;
      _sessionKey = null;
      _creditsGranted = 0;
      _creditsUsed = 0;
      _chunks.clear();
      _buffered = 0;
      _streamError = null;
      _wake();
      try {
        await _subscription?.cancel();
      } catch (_) {}
      _subscription = null;
      try {
        _socket?.destroy();
      } catch (_) {}
      _socket = null;
    }
  }

  static String _normalizePath(String path) {
    var p = path.replaceAll('/', '\\');
    while (p.startsWith('\\')) {
      p = p.substring(1);
    }
    return p;
  }
}

/// 传输层错误(与 dart:io 的 SocketException 区分开, 便于上层统一处理)
class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);
  final String message;
  @override
  String toString() => message;
}
