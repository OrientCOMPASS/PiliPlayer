// 协议编解码代码按"每行一个字段"书写更直观, 因此不强制级联写法
// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/smb/smb2_client.dart' show SocketExceptionLike;

/// 主机名解析: 尽量用主机名而不是 IP(与 VLC 的行为一致)。
///
/// Android 的系统解析器不做 mDNS/NetBIOS, `smb://NAS/video` 这类名字直接
/// `Socket.connect` 会失败, 所以这里做三级解析:
///   1. IP 字面量 -> 原样返回
///   2. 系统 DNS(`InternetAddress.lookup`, 覆盖 FQDN 与部分路由器代答的短名)
///   3. NetBIOS 名字服务(NBNS, UDP 137 广播查询, 家用局域网里最通用的短名解析)
/// 解析结果缓存 60 秒, 反复浏览/播放不会反复发广播。
abstract final class SmbName {
  static final Map<String, (String, DateTime)> _cache = {};
  static final Random _random = Random();

  static bool isIpLiteral(String host) =>
      InternetAddress.tryParse(host) != null;

  /// 解析主机名为 IP。失败抛 [SocketExceptionLike]。
  /// [fallbackAddress] 是"发现阶段已经拿到过的 IP", 作为最后的兜底。
  static Future<String> resolve(
    String host, {
    String? fallbackAddress,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (isIpLiteral(host)) {
      return host;
    }
    final cached = _cache[host.toLowerCase()];
    if (cached != null &&
        DateTime.now().difference(cached.$2).inSeconds < 60) {
      return cached.$1;
    }
    // 1) 系统 DNS
    try {
      final addresses = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 2));
      if (addresses.isNotEmpty) {
        return _remember(host, addresses.first.address);
      }
    } on TimeoutException {
      // 继续走 NBNS
    } catch (_) {
      // 继续走 NBNS
    }
    // 2) NBNS 广播查询
    try {
      final address = await nbnsResolve(host, timeout: timeout);
      if (address != null) {
        return _remember(host, address);
      }
    } catch (_) {
      // 落到兜底
    }
    // 3) 兜底: 发现阶段记下的 IP
    if (fallbackAddress != null && isIpLiteral(fallbackAddress)) {
      return _remember(host, fallbackAddress);
    }
    throw SocketExceptionLike('无法解析主机名 $host');
  }

  static String _remember(String host, String address) {
    _cache[host.toLowerCase()] = (address, DateTime.now());
    if (_cache.length > 64) {
      _cache.remove(_cache.keys.first);
    }
    return address;
  }

  /// 清空解析缓存(网络切换后可调)
  static void clearCache() => _cache.clear();

  // ==================== NBNS (RFC 1002) ====================

  /// NBNS 名字查询(UDP 137, 广播), 查 `NAME`(0x20 文件服务器服务)。
  /// 成功返回 IPv4 字符串, 超时/无应答返回 null。
  static Future<String?> nbnsResolve(
    String name, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final txn = _random.nextInt(0xffff);
    final query = buildNbnsQuery(txn, name);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      socket.broadcastEnabled = true;
      final completer = Completer<String?>();
      late final StreamSubscription<RawSocketEvent> subscription;
      subscription = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) {
            return;
          }
          final datagram = socket!.receive();
          if (datagram == null) {
            return;
          }
          final answer = parseNbnsResponse(datagram.data, expectTxn: txn);
          if (answer != null && !completer.isCompleted) {
            completer.complete(answer);
            subscription.cancel();
          }
        },
        onError: (_) {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        },
        cancelOnError: true,
      );
      socket.send(
        query,
        InternetAddress('255.255.255.255'),
        137,
      );
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      socket?.close();
    }
  }

  /// 构造 NBNS 查询报文(公开以便单元测试)
  static Uint8List buildNbnsQuery(int txn, String name, {int suffix = 0x20}) {
    final label = encodeNbnsName(name, suffix: suffix);
    final packet = Uint8List(12 + label.length + 4);
    final bd = ByteData.sublistView(packet);
    bd.setUint16(0, txn, Endian.big);
    bd.setUint16(2, 0x0110, Endian.big); // 广播 + 期望递归
    bd.setUint16(4, 1, Endian.big); // QDCOUNT
    packet.setRange(12, 12 + label.length, label);
    bd.setUint16(12 + label.length, 0x0020, Endian.big); // QTYPE = NB
    bd.setUint16(14 + label.length, 0x0001, Endian.big); // QCLASS = IN
    return packet;
  }

  /// NetBIOS 名 -> first-level 编码(15 字节补空格 + 1 字节服务后缀, 每半字节 'A'+n)
  static Uint8List encodeNbnsName(String name, {int suffix = 0x20}) {
    final raw = Uint8List(16);
    final bytes = name.toUpperCase().codeUnits;
    for (var i = 0; i < 15; i++) {
      raw[i] = i < bytes.length ? bytes[i] : 0x20;
    }
    raw[15] = suffix;
    final out = Uint8List(34); // 长度字节 + 32 个编码字符 + 结束 0
    out[0] = 32;
    for (var i = 0; i < 16; i++) {
      out[1 + i * 2] = 0x41 + ((raw[i] >> 4) & 0x0f);
      out[2 + i * 2] = 0x41 + (raw[i] & 0x0f);
    }
    out[33] = 0;
    return out;
  }

  /// 解析 NBNS 应答, 返回第一条 A 记录的 IPv4(公开以便单元测试)。
  /// 事务号不匹配 / 非应答 / 无答案时返回 null。
  static String? parseNbnsResponse(Uint8List packet, {int? expectTxn}) {
    if (packet.length < 12) {
      return null;
    }
    final bd = ByteData.sublistView(packet);
    if (expectTxn != null && bd.getUint16(0, Endian.big) != expectTxn) {
      return null;
    }
    final flags = bd.getUint16(2, Endian.big);
    if (flags & 0x8000 == 0) {
      return null; // 不是应答
    }
    final anCount = bd.getUint16(6, Endian.big);
    if (anCount == 0) {
      return null;
    }
    // 跳过问题段: 名字(以 0 结尾, 或压缩指针 0xC0xx) + QTYPE + QCLASS
    var offset = 12;
    offset = _skipName(packet, offset);
    if (offset < 0 || offset + 4 > packet.length) {
      return null;
    }
    offset += 4;
    // 答案段
    for (var i = 0; i < anCount; i++) {
      offset = _skipName(packet, offset);
      if (offset < 0 || offset + 10 > packet.length) {
        return null;
      }
      final type = bd.getUint16(offset, Endian.big);
      final rdLength = bd.getUint16(offset + 8, Endian.big);
      offset += 10;
      if (offset + rdLength > packet.length) {
        return null;
      }
      if (type == 0x0020 && rdLength >= 6) {
        // RDATA: flags(2) + addr(4)
        final ip = packet.sublist(offset + 2, offset + 6);
        return ip.join('.');
      }
      offset += rdLength;
    }
    return null;
  }

  /// 跳过一个 DNS 名字段, 返回之后的偏移; 越界返回 -1
  static int _skipName(Uint8List packet, int offset) {
    while (offset < packet.length) {
      final len = packet[offset];
      if (len == 0) {
        return offset + 1;
      }
      if (len & 0xc0 == 0xc0) {
        return offset + 2; // 压缩指针
      }
      offset += 1 + len;
    }
    return -1;
  }
}
