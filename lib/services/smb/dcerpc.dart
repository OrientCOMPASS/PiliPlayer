// 协议编解码代码按"每行一个字段"书写更直观, 因此不强制级联写法
// ignore_for_file: cascade_invocations
import 'dart:convert' show utf8;
import 'dart:typed_data';

/// 最小 DCERPC (MS-RPCE) 客户端封帧/解析 + NDR32 编解码工具。
///
/// 只实现浏览 SMB 共享所需的部分: 连接式 RPC over 命名管道(\\srvsvc),
/// bind / bind_ack / request / response 四种 PDU, NDR32 小端。
/// 纯 Dart、零依赖, 可以在沙盒里对着真实的 smbd 直接联调
/// (见 `~/.ci/smb_testbed.sh` 与 `test/services/smb/smb_share_enum_test.dart`)。
abstract final class Dcerpc {
  static const int ptypeRequest = 0x00;
  static const int ptypeResponse = 0x02;
  static const int ptypeBind = 0x0b;
  static const int ptypeBindAck = 0x0c;
  static const int ptypeFault = 0x03;

  static const int flagFirstFrag = 0x01;
  static const int flagLastFrag = 0x02;

  /// 协商的分片大小, 与 Windows/libsmb2 客户端一致
  static const int maxFrag = 4280;

  /// 构造 BIND PDU(单上下文项, NDR32 传输语法)
  ///
  /// [iface] 为接口 UUID 的 16 字节 **wire 格式**(前 3 段小端、后 2 段大端),
  /// 见 [uuidToBytes]。
  static Uint8List buildBind({
    required int callId,
    required Uint8List iface,
    required int ifaceVersion,
    required int ifaceVersionMinor,
  }) {
    // NDR 传输语法: 8a885d04-1ceb-11c9-9fe8-08002b104860 v2.0
    final ndr = uuidToBytes(
      0x8a885d04,
      0x1ceb,
      0x11c9,
      [0x9f, 0xe8, 0x08, 0x00, 0x2b, 0x10, 0x48, 0x60],
    );
    // payload = bind 头(8) + 上下文计数(4) + 上下文项(4 + 20 + 20)
    final body = Uint8List(8 + 4 + 44);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, maxFrag, Endian.little); // max_xmit_frag
    bd.setUint16(2, maxFrag, Endian.little); // max_recv_frag
    bd.setUint32(4, 0, Endian.little); // assoc_group_id
    bd.setUint8(8, 1); // p_context_elem
    bd.setUint8(9, 0); // reserved
    bd.setUint16(10, 0, Endian.little); // reserved2
    // ---- 上下文项 ----
    bd.setUint16(12, 0, Endian.little); // p_cont_id
    bd.setUint8(14, 1); // n_transfer_syn
    bd.setUint8(15, 0); // reserved
    body.setRange(16, 32, iface); // abstract_syntax UUID
    bd.setUint16(32, ifaceVersion, Endian.little);
    bd.setUint16(34, ifaceVersionMinor, Endian.little);
    body.setRange(36, 52, ndr); // transfer_syntax UUID
    bd.setUint16(52, 2, Endian.little); // version
    bd.setUint16(54, 0, Endian.little); // version_minor
    return _frame(
      ptype: ptypeBind,
      callId: callId,
      flags: flagFirstFrag | flagLastFrag,
      payload: body,
    );
  }

  /// 解析 BIND_ACK。返回 (是否接受, 拒绝原因)。
  ///
  /// 二级地址(\PIPE\xxx 之类)长度可变, 其后的结果字段按 4 字节对齐,
  /// 这里按规范跳过; 报文太短视为解析失败。
  static ({bool accepted, int reason, String? secondaryAddress}) parseBindAck(
    Uint8List pdu,
  ) {
    if (pdu.length < 16) {
      return (accepted: false, reason: -1, secondaryAddress: null);
    }
    final bd = ByteData.sublistView(pdu);
    final ptype = bd.getUint8(2);
    if (ptype == ptypeFault) {
      return (accepted: false, reason: -2, secondaryAddress: null);
    }
    if (ptype != ptypeBindAck || pdu.length < 26) {
      return (accepted: false, reason: -3, secondaryAddress: null);
    }
    final secLen = bd.getUint16(24, Endian.little);
    var offset = 26 + secLen;
    String? secAddr;
    if (secLen > 0 && 26 + secLen <= pdu.length) {
      var end = 26 + secLen;
      while (end > 26 && pdu[end - 1] == 0) {
        end--;
      }
      secAddr = utf8.decode(pdu.sublist(26, end), allowMalformed: true);
    }
    // 对齐到 4 字节(PDU 起始算起)
    while (offset % 4 != 0) {
      offset++;
    }
    // p_results: n_results(1) + reserved(1) + reserved2(2), 然后才是
    // 第一个上下文的结果对 result(2)/reason(2)
    offset += 4;
    if (offset + 4 > pdu.length) {
      return (accepted: false, reason: -4, secondaryAddress: secAddr);
    }
    final result = bd.getUint16(offset, Endian.little);
    final reason = bd.getUint16(offset + 2, Endian.little);
    return (
      accepted: result == 0,
      reason: result == 0 ? 0 : reason,
      secondaryAddress: secAddr,
    );
  }

  /// 构造 REQUEST PDU
  static Uint8List buildRequest({
    required int callId,
    required int opnum,
    required Uint8List stub,
    int ctxId = 0,
  }) {
    final payload = Uint8List(8 + stub.length);
    final bd = ByteData.sublistView(payload);
    bd.setUint32(0, stub.length, Endian.little); // alloc_hint
    bd.setUint16(4, ctxId, Endian.little); // p_cont_id
    bd.setUint16(6, opnum, Endian.little);
    payload.setRange(8, payload.length, stub);
    return _frame(
      ptype: ptypeRequest,
      callId: callId,
      flags: flagFirstFrag | flagLastFrag,
      payload: payload,
    );
  }

  /// 解析 RESPONSE PDU 头部, 取出 stub 数据区
  static ({int ptype, int flags, int callId, int fragLength, Uint8List stub})
  parsePdu(Uint8List pdu) {
    final bd = ByteData.sublistView(pdu);
    final ptype = bd.getUint8(2);
    final flags = bd.getUint8(3);
    final fragLength = bd.getUint16(8, Endian.little);
    final callId = bd.getUint32(12, Endian.little);
    // response 头: alloc_hint(4) + ctx_id(2) + cancel_count(1) + reserved(1)
    final stub = pdu.length > 24 ? pdu.sublist(24) : Uint8List(0);
    return (
      ptype: ptype,
      flags: flags,
      callId: callId,
      fragLength: fragLength,
      stub: stub,
    );
  }

  static Uint8List _frame({
    required int ptype,
    required int callId,
    required int flags,
    required Uint8List payload,
  }) {
    final pdu = Uint8List(16 + payload.length);
    final bd = ByteData.sublistView(pdu);
    bd.setUint8(0, 5); // rpc_vers
    bd.setUint8(1, 0); // rpc_vers_minor
    bd.setUint8(2, ptype);
    bd.setUint8(3, flags);
    bd.setUint8(4, 0x10); // packed_drep: 小端 / ASCII / IEEE
    bd.setUint8(5, 0);
    bd.setUint8(6, 0);
    bd.setUint8(7, 0);
    bd.setUint16(8, pdu.length, Endian.little); // frag_length
    bd.setUint16(10, 0, Endian.little); // auth_length
    bd.setUint32(12, callId, Endian.little);
    pdu.setRange(16, pdu.length, payload);
    return pdu;
  }

  /// 把 UUID 各段编码成 RPC wire 格式(前 3 段小端, 后 8 字节按原序)
  static Uint8List uuidToBytes(
    int timeLow,
    int timeMid,
    int timeHiAndVersion,
    List<int> node,
  ) {
    final out = Uint8List(16);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, timeLow, Endian.little);
    bd.setUint16(4, timeMid, Endian.little);
    bd.setUint16(6, timeHiAndVersion, Endian.little);
    for (var i = 0; i < 8; i++) {
      out[8 + i] = node[i];
    }
    return out;
  }
}

/// NDR32 写侧(小端、4 字节对齐)
class NdrWriter {
  final BytesBuilder _b = BytesBuilder(copy: true);

  int get length => _b.length;

  void u16(int value) {
    align(2);
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _b.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    align(4);
    final data = ByteData(4)..setUint32(0, value & 0xffffffff, Endian.little);
    _b.add(data.buffer.asUint8List());
  }

  void align(int boundary) {
    final pad = (boundary - _b.length % boundary) % boundary;
    if (pad > 0) {
      _b.add(Uint8List(pad));
    }
  }

  /// 符合 NDR 的可变长 UTF-16 字符串(带 referent 的唯一指针由调用方给):
  /// max_count / offset / actual_count / 数据 / 4 字节对齐。
  /// [text] 不含结尾 NUL(由这里补上)。
  void conformantString(String text) {
    final units = <int>[];
    for (final code in text.codeUnits) {
      units.add(code);
    }
    units.add(0); // NUL 结尾计入 actual_count
    final count = units.length;
    u32(count); // max_count
    u32(0); // offset
    u32(count); // actual_count
    for (final unit in units) {
      final data = ByteData(2)..setUint16(0, unit, Endian.little);
      _b.add(data.buffer.asUint8List());
    }
    align(4);
  }

  Uint8List toBytes() => _b.toBytes();
}

/// NDR32 读侧(小端)
class NdrReader {
  NdrReader(this.data);

  final Uint8List data;
  int offset = 0;

  bool get hasMore => offset < data.length;

  int u16() {
    align(2);
    final value = ByteData.sublistView(data).getUint16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int u32() {
    align(4);
    final value = ByteData.sublistView(data).getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  void align(int boundary) {
    final pad = (boundary - offset % boundary) % boundary;
    offset += pad;
  }

  /// 读一个符合 NDR 的 UTF-16 字符串(max_count / offset / actual_count / 数据)。
  /// 调用方先读 referent, referent 为 0 时不要调这里。
  String conformantString() {
    final maxCount = u32();
    u32(); // 字符串内偏移(总是 0)
    final actualCount = u32();
    if (maxCount > 1 << 20 || actualCount > 1 << 20) {
      throw const FormatException('ndr: 字符串长度异常');
    }
    final units = <int>[];
    for (var i = 0; i < actualCount; i++) {
      if (offset + 2 > data.length) {
        break;
      }
      final unit = ByteData.sublistView(
        data,
      ).getUint16(offset, Endian.little);
      offset += 2;
      if (unit != 0) {
        units.add(unit);
      }
    }
    align(4);
    return String.fromCharCodes(units);
  }
}
