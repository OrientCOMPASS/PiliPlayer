// 协议编解码代码按"每行一个字段"书写更直观, 因此不强制级联写法
// ignore_for_file: cascade_invocations
import 'dart:typed_data';

import 'package:PiliPlus/services/smb/dcerpc.dart';
import 'package:PiliPlus/services/smb/smb2_client.dart';

/// 一条 SMB 共享(MS-SRVS 2.2.4.3 NetShareEnum level 1)
class SmbShare {
  const SmbShare({required this.name, required this.type, this.remark = ''});

  final String name;

  /// shi1_type: 低 8 位为类型(0=磁盘 1=打印 2=设备 3=IPC), 0x80000000=隐藏/特殊
  final int type;
  final String remark;

  int get baseType => type & 0xff;

  /// 磁盘共享(能浏览出视频文件的只有这种)
  bool get isDisk => baseType == 0;
  bool get isIpc => baseType == 3;
  bool get isPrinter => baseType == 1;

  /// 管理/隐藏共享(C$、ADMIN$、IPC$、print$ 或以 $ 结尾)
  bool get isHiddenOrSpecial =>
      name.endsWith(r'$') || (type & 0x80000000) != 0;

  /// 用户视角"可浏览"的共享: 磁盘共享且非隐藏。
  /// 与 VLC/libdsm 的共享列表行为一致: 默认只展示这些,
  /// 其余(打印队列、IPC$、管理共享)过滤掉。
  bool get isBrowsable => isDisk && !isHiddenOrSpecial;

  @override
  String toString() => 'SmbShare($name, type=0x${type.toRadixString(16)})';

  @override
  bool operator ==(Object other) => other is SmbShare && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// SRVSVC 远程接口: 共享枚举(opnum 15)。
///
/// 这就是 VLC(libsmb2)、Windows 资源管理器"网络邻居"点开一台主机后自动
/// 列出共享所用的 RPC。流程:
///   TREE_CONNECT IPC 管理共享 -> CREATE \srvsvc 管道 -> DCERPC bind ->
///   NetShareEnum(level 1) -> 解析 -> 关闭。
///
/// opnum 说明: Windows(MS-SRVS)与 Samba 的 srvsvc 方法编号表不同, 但
/// **opnum 15 在两边签名完全同构**(Windows 的 NetrShareEnum / Samba 的
/// NetShareEnumAll, 参数布局一致), libsmb2 与实测的 rpcclient 报文都
/// 验证了这一点, 因此统一用 15 以同时兼容 Windows/Samba/NAS。
/// 匿名会话在多数 NAS/Samba 默认配置下即可枚举; 被拒绝(ACCESS_DENIED /
/// LOGON_FAILURE)时上层应提示输入凭据后重试。
abstract final class Srvsvc {
  /// srvsvc 接口 UUID: 4b324fc8-1670-01d3-1278-5a47bf6ee188 v3.0
  static final Uint8List _iface = Dcerpc.uuidToBytes(
    0x4b324fc8,
    0x1670,
    0x01d3,
    [0x12, 0x78, 0x5a, 0x47, 0xbf, 0x6e, 0xe1, 0x88],
  );

  /// opnum 15: Windows NetrShareEnum ≡ Samba NetShareEnumAll(同构)
  static const int _opnumNetShareEnum = 15;

  /// Win32 ERROR_MORE_DATA: 服务端一次装不下, 带 resume handle 继续取
  static const int _errorMoreData = 234;

  /// 枚举共享。[client] 需已完成 connect(协商 + 会话), 本方法负责
  /// IPC$ 树连接与管道读写, 结束后断开 IPC$(会话保留)。
  static Future<List<SmbShare>> listShares(
    Smb2Client client, {
    String? serverName,
  }) async {
    await client.treeConnect('IPC\$');
    final pipe = await client.createPipe(r'srvsvc');
    try {
      // ---- bind ----
      final bind = Dcerpc.buildBind(
        callId: 1,
        iface: _iface,
        ifaceVersion: 3,
        ifaceVersionMinor: 0,
      );
      await client.pipeWrite(pipe.persistent, pipe.volatile, bind);
      final bindAck = await _readPdu(client, pipe);
      final parsedAck = Dcerpc.parseBindAck(bindAck.pdu);
      if (!parsedAck.accepted) {
        throw SmbException(
          NtStatus.unsuccessful,
          'srvsvc bind 被拒绝 (reason=${parsedAck.reason})',
        );
      }

      // ---- NetShareEnum(可能多轮: ERROR_MORE_DATA + resume handle) ----
      final shares = <SmbShare>[];
      int? resume;
      var callId = 2;
      while (true) {
        final request = Dcerpc.buildRequest(
          callId: callId++,
          opnum: _opnumNetShareEnum,
          stub: buildNetShareEnumStub(
            serverName: serverName,
            resumeHandle: resume,
          ),
        );
        await client.pipeWrite(pipe.persistent, pipe.volatile, request);
        final response = await _readPdu(client, pipe);
        final result = parseNetShareEnumStub(response.stub);
        shares.addAll(result.shares);
        if (result.error == _errorMoreData && result.resume != null) {
          resume = result.resume;
          continue;
        }
        if (result.error != 0 && shares.isEmpty) {
          throw SmbException(
            NtStatus.unsuccessful,
            'NetShareEnum 返回 Win32 错误 ${result.error}',
          );
        }
        return shares;
      }
    } finally {
      await client.closeFile(pipe.persistent, pipe.volatile);
      await client.treeDisconnect();
    }
  }

  /// 组装 NetrShareEnum 的请求 stub。公开是为了做离线单元测试。
  ///
  /// NDR 布局(Samba librpc/idl/srvsvc.idl + MS-RPCE 2.2.6):
  ///   ServerName: unique 字符串指针(referent + 可变形字符串, 可 NULL)
  ///   InfoCtr([ref] 结构体, 内联):
  ///     level u32 = 1
  ///     union 判别式 u32 = 1(switch_is(level), 判别式仍会再次上线)
  ///     ctr1(unique 指针): referent, 然后 count=0, array=NULL
  ///   MaxBuffer: 0xFFFFFFFF(尽量一次给全)
  ///   TotalEntries: [out,ref] -> 请求里占位 4 字节
  ///   ResumeHandle: [in,out,unique] -> NULL 或 referent+值
  ///
  /// 每一层都与 rpcclient 的实测抓包逐字节比对过。
  static Uint8List buildNetShareEnumStub({
    String? serverName,
    int? resumeHandle,
  }) {
    final w = NdrWriter();
    if (serverName == null || serverName.isEmpty) {
      w.u32(0); // NULL 指针: 让服务端用自己的名字
    } else {
      w.u32(0x00020000); // referent
      w.conformantString(serverName);
    }
    w.u32(1); // level = 1 (SHARE_INFO_1)
    w.u32(1); // union 判别式 = 1
    w.u32(0x00020004); // ctr1 referent
    w.u32(0); // count = 0
    w.u32(0); // array = NULL
    w.u32(0xffffffff); // MaxBuffer = -1
    w.u32(0); // TotalEntries([out,ref] 指针, 请求里为占位)
    if (resumeHandle == null) {
      w.u32(0); // ResumeHandle = NULL
    } else {
      w.u32(0x00020008); // referent
      w.u32(resumeHandle);
    }
    return w.toBytes();
  }

  /// 解析 NetShareEnum 响应 stub。公开是为了做离线单元测试。
  static ({List<SmbShare> shares, int error, int? resume, int? totalEntries})
  parseNetShareEnumStub(Uint8List stub) {
    final r = NdrReader(stub);
    final shares = <SmbShare>[];
    var error = 0;
    int? resume;
    int? totalEntries;

    r.u32(); // level(应答回显)
    r.u32(); // union 判别式
    final containerRef = r.u32();
    if (containerRef == 0) {
      // 没有容器: 直接读收尾字段
      if (r.hasMore) {
        totalEntries = r.u32(); // [out,ref] 内联
        resume = _readPointerValue(r);
        error = r.hasMore ? r.u32() : 0;
      }
      return (
        shares: shares,
        error: error,
        resume: resume,
        totalEntries: totalEntries,
      );
    }
    final entriesRead = r.u32();
    final bufferRef = r.u32();
    if (entriesRead > 1 << 16) {
      throw const FormatException('srvsvc: EntriesRead 异常');
    }
    if (bufferRef != 0) {
      final maxCount = r.u32(); // 可变形数组 max_count
      final count = maxCount < entriesRead ? maxCount : entriesRead;
      // 结构体数组: 每项 = netname referent + type + remark referent
      final refs = <({int nameRef, int type, int remarkRef})>[];
      for (var i = 0; i < count; i++) {
        refs.add((
          nameRef: r.u32(),
          type: r.u32(),
          remarkRef: r.u32(),
        ));
      }
      // 延迟指针数据: 按结构体顺序, 每项先 netname 后 remark
      for (final ref in refs) {
        final name = ref.nameRef != 0 ? r.conformantString() : '';
        final remark = ref.remarkRef != 0 ? r.conformantString() : '';
        if (name.isNotEmpty) {
          shares.add(SmbShare(name: name, type: ref.type, remark: remark));
        }
      }
    }
    if (r.hasMore) {
      totalEntries = r.u32(); // TotalEntries [out,ref]: 内联 u32
    }
    if (r.hasMore) {
      resume = _readPointerValue(r); // ResumeHandle [in,out,unique]
    }
    if (r.hasMore) {
      error = r.u32(); // Win32 错误码(应答最后一个 DWORD)
    }
    return (
      shares: shares,
      error: error,
      resume: resume,
      totalEntries: totalEntries,
    );
  }

  /// 读一个 unique 指针: referent 为 0 返回 null, 否则再读 DWORD 值
  static int? _readPointerValue(NdrReader r) {
    final ref = r.u32();
    return ref == 0 ? null : r.u32();
  }

  /// 从管道里读一个完整的 DCERPC PDU:
  ///   * 单次 SMB READ 可能只带回部分数据(STATUS_BUFFER_OVERFLOW), 循环补齐;
  ///   * 按公共头里的 frag_length 判断 PDU 是否读全;
  ///   * 多分片(FIRST/LAST flag)时拼接各分片的 stub。
  /// 返回 [pdu](第一个分片原文, 含公共头, 供 ptype/bind_ack 解析)与
  /// [stub](所有分片的 stub 数据拼接)。
  static Future<({Uint8List pdu, Uint8List stub})> _readPdu(
    Smb2Client client,
    ({int persistent, int volatile, int size, int attributes}) pipe,
  ) async {
    Future<Uint8List> readMore() =>
        client.pipeRead(pipe.persistent, pipe.volatile, Dcerpc.maxFrag + 1024);

    final buffer = BytesBuilder(copy: true);
    Uint8List? complete; // 已凑齐 frag_length 的当前 PDU

    // 先在缓冲区里找完整 PDU, 找不到才去读管道 —— 顺序不能反:
    // 多分片/多条 PDU 可能一次 READ 就全到了, 先读会永久阻塞在管道上
    bool tryCompleteFromBuffer() {
      final data = buffer.toBytes();
      if (data.length < 16) {
        return false;
      }
      final fragLength =
          ByteData.sublistView(data).getUint16(8, Endian.little);
      if (fragLength < 16 || data.length < fragLength) {
        return false;
      }
      complete = Uint8List.fromList(data.sublist(0, fragLength));
      buffer.clear();
      if (data.length > fragLength) {
        // 多余字节留给下一次(多分片响应或管道里还有下一条 PDU)
        buffer.add(data.sublist(fragLength));
      }
      return true;
    }

    Future<void> pump() async {
      while (complete == null) {
        if (tryCompleteFromBuffer()) {
          return;
        }
        final chunk = await readMore();
        if (chunk.isEmpty) {
          if (buffer.isEmpty) {
            throw const SocketExceptionLike('srvsvc: 管道无数据返回');
          }
          break; // 数据已读尽, 用现有内容解析(容错)
        }
        buffer.add(chunk);
      }
    }

    await pump();
    final first = complete;
    if (first == null) {
      throw const SocketExceptionLike('srvsvc: 无法读出完整的 DCERPC PDU');
    }
    var parsed = Dcerpc.parsePdu(first);
    if (parsed.ptype == Dcerpc.ptypeFault) {
      // fault PDU 的 stub 前 4 字节是 RPC 状态码(nca_s_* / RPC_S_*)
      var faultStatus = 0;
      if (parsed.stub.length >= 4) {
        faultStatus = ByteData.sublistView(parsed.stub).getUint32(
          0,
          Endian.little,
        );
      }
      throw SmbException(
        NtStatus.unsuccessful,
        'srvsvc: RPC fault 0x${faultStatus.toRadixString(16)}',
      );
    }
    // 多分片响应: 拼接所有分片的 stub
    final stubs = <Uint8List>[parsed.stub];
    while (parsed.flags & Dcerpc.flagLastFrag == 0) {
      complete = null;
      // 缓冲区里若已含下一分片, pump 会直接用; 否则继续读管道
      await pump();
      final next = complete;
      if (next == null) {
        break;
      }
      parsed = Dcerpc.parsePdu(next);
      stubs.add(parsed.stub);
    }
    final total = stubs.fold<int>(0, (sum, s) => sum + s.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final s in stubs) {
      out.setRange(offset, offset + s.length, s);
      offset += s.length;
    }
    return (pdu: first, stub: out);
  }
}
