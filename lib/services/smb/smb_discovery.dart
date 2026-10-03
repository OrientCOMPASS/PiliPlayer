// 协议编解码代码按"每行一个字段"书写更直观, 因此不强制级联写法
// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 局域网里发现的一台 SMB 主机
class SmbHost {
  const SmbHost({required this.address, this.port = 445, this.name});

  final String address;
  final int port;

  /// NetBIOS 名(能查到才有, 否则为 null)
  final String? name;

  String get displayName => name == null || name!.isEmpty ? address : name!;

  @override
  String toString() => 'SmbHost($displayName@$address:$port)';

  @override
  bool operator ==(Object other) =>
      other is SmbHost && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);
}

/// 局域网 SMB 主机发现。
///
/// 做法与 VLC/文件管理器一致: 对本机所在子网做一次 **TCP 445 端口扫描**
/// (并发 + 短超时), 再用 NetBIOS 名字服务(UDP 137 NBSTAT)尽力查出主机名。
/// 不依赖 mDNS/SSDP: 家用 NAS、Windows 共享、Samba 都一定开着 445,
/// 而 mDNS 广播在不少路由器上是被拦掉的。
abstract final class SmbDiscovery {
  static const int defaultPort = 445;

  /// 扫描本机所有 IPv4 网段(/24), 返回开着 SMB 端口的主机
  ///
  /// [onProgress] 回调 (已完成, 总数), 便于界面显示进度。
  static Future<List<SmbHost>> scan({
    int port = defaultPort,
    Duration timeout = const Duration(milliseconds: 600),
    int concurrency = 64,
    bool resolveNames = true,
    void Function(int done, int total)? onProgress,
    List<String>? networks,
  }) async {
    final targets = networks ?? await localNetworkHosts();
    if (targets.isEmpty) {
      return const [];
    }
    final found = <String>[];
    var done = 0;
    final queue = List<String>.from(targets);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final ip = queue.removeLast();
        if (await _isOpen(ip, port, timeout)) {
          found.add(ip);
        }
        done++;
        onProgress?.call(done, targets.length);
      }
    }

    final workers = concurrency < queue.length ? concurrency : queue.length;
    await Future.wait(
      List.generate(workers < 1 ? 1 : workers, (_) => worker()),
    );

    found.sort(_compareIp);
    final hosts = <SmbHost>[];
    for (final ip in found) {
      String? name;
      if (resolveNames) {
        name = await netbiosName(ip).timeout(
          const Duration(milliseconds: 900),
          onTimeout: () => null,
        );
      }
      hosts.add(SmbHost(address: ip, port: port, name: name));
    }
    return hosts;
  }

  /// 本机所有 IPv4 /24 网段里的可扫描地址(跳过网络地址、广播地址与本机)
  static Future<List<String>> localNetworkHosts() async {
    final result = <String>[];
    final self = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final nic in interfaces) {
        for (final addr in nic.addresses) {
          self.add(addr.address);
          final parts = addr.address.split('.');
          if (parts.length != 4) {
            continue;
          }
          final prefix = parts.sublist(0, 3).join('.');
          for (var i = 1; i <= 254; i++) {
            final ip = '$prefix.$i';
            if (!self.contains(ip)) {
              result.add(ip);
            }
          }
        }
      }
    } catch (_) {
      // 拿不到网卡信息就没法扫, 交给上层提示
    }
    // 网卡自身的地址要排掉(上面是按加入顺序排的, 这里再兜一次)
    result.removeWhere(self.contains);
    return result;
  }

  static Future<bool> _isOpen(String ip, int port, Duration timeout) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// NetBIOS 名字服务(NBSTAT)查询主机名, 失败返回 null
  static Future<String?> netbiosName(
    String ip, {
    int port = 137,
    Duration timeout = const Duration(milliseconds: 700),
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      socket.broadcastEnabled = false;
      final request = _buildNbstatRequest(1);
      socket.send(request, InternetAddress(ip), port);

      final completer = Completer<String?>();
      late StreamSubscription<RawSocketEvent> sub;
      sub = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) {
            return;
          }
          final datagram = socket?.receive();
          if (datagram == null) {
            return;
          }
          final name = parseNbstatResponse(datagram.data);
          if (!completer.isCompleted) {
            completer.complete(name);
            sub.cancel();
          }
        },
        onError: (_) {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        },
      );
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  /// 构造 NBSTAT(Node Status Request) 报文: 查询 "*<00>" 的节点状态
  static Uint8List _buildNbstatRequest(int transactionId) {
    // 第一层编码: 每个字节拆成两个 'A'+高低半字节, 名字补空格到 16 字节
    final raw = Uint8List(16)..fillRange(0, 16, 0x20);
    raw[0] = 0x2a; // '*'
    final encoded = Uint8List(32);
    for (var i = 0; i < 16; i++) {
      encoded[i * 2] = 0x41 + ((raw[i] >> 4) & 0x0f);
      encoded[i * 2 + 1] = 0x41 + (raw[i] & 0x0f);
    }
    final out = BytesBuilder();
    final header = ByteData(12)
      ..setUint16(0, transactionId & 0xffff)
      ..setUint16(2, 0x0000) // 标准查询, 不广播
      ..setUint16(4, 1) // QDCOUNT
      ..setUint16(6, 0)
      ..setUint16(8, 0)
      ..setUint16(10, 0);
    out.add(header.buffer.asUint8List());
    out.add([0x20]); // 名字长度 32
    out.add(encoded);
    final tail = ByteData(4)
      ..setUint16(0, 0x0021) // QTYPE = NBSTAT
      ..setUint16(2, 0x0001); // QCLASS = IN
    out.add(tail.buffer.asUint8List());
    return out.toBytes();
  }

  /// 解析 NBSTAT 响应, 取出唯一的计算机名(type 0x00 且 UNIQUE)
  static String? parseNbstatResponse(Uint8List data) {
    // 12 字节头 + 问题段(1 + 32 + 4) + 名字数
    if (data.length < 12 + 37 + 1) {
      return null;
    }
    final bd = ByteData.sublistView(data);
    final anCount = bd.getUint16(6, Endian.big);
    if (anCount == 0) {
      return null;
    }
    // 跳过问题段
    var i = 12 + 1 + 32 + 4;
    // 应答: 名字(压缩指针 2 字节) + TYPE(2) + CLASS(2) + TTL(4) + RDLENGTH(2)
    if (i + 12 > data.length) {
      return null;
    }
    final rdLength = bd.getUint16(i + 10, Endian.big);
    i += 12;
    if (rdLength < 1 || i + 1 > data.length) {
      return null;
    }
    final count = data[i];
    i += 1;
    String? unique;
    String? group;
    for (var n = 0; n < count; n++) {
      if (i + 18 > data.length) {
        break;
      }
      final nameBytes = data.sublist(i, i + 15);
      final type = data[i + 15];
      final flags = bd.getUint16(i + 16, Endian.big);
      final isGroup = flags & 0x8000 != 0;
      final name = String.fromCharCodes(nameBytes).trim();
      i += 18;
      if (name.isEmpty) {
        continue;
      }
      if (type == 0x00 && !isGroup && unique == null) {
        unique = name;
      } else if (type == 0x00 && isGroup && group == null) {
        group = name;
      }
    }
    return unique ?? group;
  }

  static int _compareIp(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    for (var i = 0; i < 4; i++) {
      final x = int.tryParse(pa[i]) ?? 0;
      final y = int.tryParse(pb[i]) ?? 0;
      if (x != y) {
        return x.compareTo(y);
      }
    }
    return 0;
  }
}
