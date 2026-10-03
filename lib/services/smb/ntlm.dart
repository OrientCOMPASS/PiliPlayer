// 协议编解码代码按"每行一个字段"书写更直观, 因此不强制级联写法
// ignore_for_file: cascade_invocations

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, md5;

import 'package:PiliPlus/services/smb/md4.dart';

/// NTLMSSP 协商标志(见 MS-NLMP 2.2.2.5)
abstract final class NtlmFlags {
  static const int negotiateUnicode = 0x00000001;
  static const int requestTarget = 0x00000004;
  static const int negotiateSign = 0x00000010;
  static const int negotiateSeal = 0x00000020;
  static const int negotiateNtlm = 0x00000200;
  static const int negotiateAlwaysSign = 0x00008000;
  static const int negotiateExtendedSessionSecurity = 0x00080000;
  static const int negotiateTargetInfo = 0x00800000;
  static const int negotiateVersion = 0x02000000;
  static const int negotiate128 = 0x20000000;
  static const int negotiateKeyExch = 0x40000000;
  static const int negotiate56 = 0x80000000;

  /// 本机作为客户端声明的能力集。
  /// 注意: 故意不协商 NEGOTIATE_KEY_EXCH, 这样会话密钥就是 SessionBaseKey,
  /// EncryptedRandomSessionKey 可以为空(实现更简单, 服务端兼容性一致)。
  static const int clientType1 =
      negotiateUnicode |
      requestTarget |
      negotiateSign |
      negotiateSeal |
      negotiateNtlm |
      negotiateAlwaysSign |
      negotiateExtendedSessionSecurity |
      negotiateTargetInfo |
      negotiateVersion |
      negotiate128 |
      negotiate56;
}

/// Windows 版本信息(NEGOTIATE_VERSION 时需要), 这里用 Windows 10 19041
const List<int> kNtlmVersion = [
  0x0a,
  0x00,
  0x61,
  0x4a,
  0x00,
  0x00,
  0x00,
  0x0f,
];

Uint8List _utf16Le(String s) {
  final out = ByteData(s.length * 2);
  for (var i = 0; i < s.length; i++) {
    out.setUint16(i * 2, s.codeUnitAt(i), Endian.little);
  }
  return out.buffer.asUint8List();
}

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// 1601-01-01 到 1970-01-01 的微秒数
const int _epochDeltaMicros = 11644473600 * 1000000;

/// 当前时间的 FILETIME(自 1601-01-01 起的 100ns 计数), 小端 8 字节
Uint8List fileTimeNow([DateTime? at]) {
  final micros = (at ?? DateTime.now().toUtc()).microsecondsSinceEpoch;
  final ticks = (micros + _epochDeltaMicros) * 10;
  final out = ByteData(8)..setUint64(0, ticks, Endian.little);
  return out.buffer.asUint8List();
}

Uint8List ntlmSignatureBytes() => Uint8List.fromList([
  0x4e,
  0x54,
  0x4c,
  0x4d,
  0x53,
  0x53,
  0x50,
  0x00,
]);

/// NTLMSSP Type 1 (Negotiate), 见 MS-NLMP 2.2.1.1
Uint8List buildType1({String domain = '', String workstation = ''}) {
  const headerLen = 40;
  final domainBytes = domain.isEmpty ? Uint8List(0) : _utf16Le(domain);
  final wsBytes = workstation.isEmpty ? Uint8List(0) : _utf16Le(workstation);
  final total = headerLen + domainBytes.length + wsBytes.length;
  final out = Uint8List(total);
  final bd = ByteData.sublistView(out);

  out.setRange(0, 8, ntlmSignatureBytes());
  bd.setUint32(8, 1, Endian.little);
  bd.setUint32(12, NtlmFlags.clientType1, Endian.little);
  bd.setUint16(16, domainBytes.length, Endian.little);
  bd.setUint16(18, domainBytes.length, Endian.little);
  bd.setUint32(20, headerLen, Endian.little);
  bd.setUint16(24, wsBytes.length, Endian.little);
  bd.setUint16(26, wsBytes.length, Endian.little);
  bd.setUint32(28, headerLen + domainBytes.length, Endian.little);
  out.setRange(32, 40, kNtlmVersion);
  out.setRange(headerLen, headerLen + domainBytes.length, domainBytes);
  out.setRange(headerLen + domainBytes.length, total, wsBytes);
  return out;
}

// ==================== SPNEGO(GSS-API) 封装 ====================
//
// 实测(Samba 4.17 + tcpdump 对比 smbclient): SMB2 SESSION_SETUP 的安全缓冲区
// 必须是 SPNEGO 封装(negTokenInit / negTokenResp), 直接塞裸 NTLMSSP 会被
// 服务端以 STATUS_INVALID_PARAMETER 拒绝(即使 gensec 层已经解析出了 Type1)。

/// OID 1.3.5.5.2 (SPNEGO)
const List<int> _oidSpnego = [
  0x06,
  0x06,
  0x2b,
  0x06,
  0x01,
  0x05,
  0x05,
  0x02,
];

/// OID 1.3.6.1.4.1.311.2.2.10 (NTLMSSP)
const List<int> _oidNtlm = [
  0x06,
  0x0a,
  0x2b,
  0x06,
  0x01,
  0x04,
  0x01,
  0x82,
  0x37,
  0x02,
  0x02,
  0x0a,
];

/// 最小 DER 编码(定长)
Uint8List _der(int tag, List<int> content) {
  final out = BytesBuilder(copy: false)..add([tag]);
  final len = content.length;
  if (len < 0x80) {
    out.add([len]);
  } else if (len < 0x100) {
    out.add([0x81, len]);
  } else if (len < 0x10000) {
    out.add([0x82, (len >> 8) & 0xff, len & 0xff]);
  } else {
    out.add([0x83, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff]);
  }
  out.add(content);
  return out.toBytes();
}

/// Type1 -> negTokenInit
Uint8List spnegoNegTokenInit(Uint8List ntlmMessage) {
  final mechTypes = _der(0xa0, _der(0x30, _oidNtlm));
  final mechToken = _der(0xa2, _der(0x04, ntlmMessage));
  final tokenInit = _der(0xa0, _der(0x30, [...mechTypes, ...mechToken]));
  return _der(0x60, [..._oidSpnego, ...tokenInit]);
}

/// Type3 -> negTokenResp
Uint8List spnegoNegTokenResp(Uint8List ntlmMessage) =>
    _der(0xa1, _der(0x30, _der(0xa2, _der(0x04, ntlmMessage))));

bool _isNtlmSignature(Uint8List b, int i) =>
    i + 8 <= b.length &&
    b[i] == 0x4e &&
    b[i + 1] == 0x54 &&
    b[i + 2] == 0x4c &&
    b[i + 3] == 0x4d &&
    b[i + 4] == 0x53 &&
    b[i + 5] == 0x53 &&
    b[i + 6] == 0x50 &&
    b[i + 7] == 0x00;

/// Type2 消息的精确长度(按字段偏移算, 便于从 SPNEGO 里切出来)
int ntlmType2Length(Uint8List m) {
  if (m.length < 48) {
    return m.length;
  }
  final bd = ByteData.sublistView(m);
  var end = 48;
  for (final at in [12, 40]) {
    // TargetNameFields / TargetInfoFields
    final len = bd.getUint16(at, Endian.little);
    final off = bd.getUint32(at + 4, Endian.little);
    if (off + len > end) {
      end = off + len;
    }
  }
  return end > m.length ? m.length : end;
}

/// 从安全缓冲区(SPNEGO 或裸 NTLMSSP)中取出 NTLMSSP 消息
Uint8List? unwrapNtlm(Uint8List blob) {
  for (var i = 0; i + 8 <= blob.length; i++) {
    if (_isNtlmSignature(blob, i)) {
      final message = blob.sublist(i);
      if (message.length >= 12) {
        final type = ByteData.sublistView(message).getUint32(8, Endian.little);
        if (type == 2) {
          return message.sublist(0, ntlmType2Length(message));
        }
      }
      return message;
    }
  }
  return null;
}

/// NTLMSSP Type 2 (Challenge) 解析结果
class NtlmChallenge {
  NtlmChallenge({
    required this.serverChallenge,
    required this.flags,
    required this.targetName,
    required this.targetInfo,
  });

  final Uint8List serverChallenge;
  final int flags;
  final String targetName;
  final Uint8List targetInfo;

  static NtlmChallenge? parse(Uint8List msg) {
    if (msg.length < 32) {
      return null;
    }
    final bd = ByteData.sublistView(msg);
    if (bd.getUint32(8, Endian.little) != 2) {
      return null;
    }
    final nameLen = bd.getUint16(12, Endian.little);
    final nameOff = bd.getUint32(16, Endian.little);
    final flags = bd.getUint32(20, Endian.little);
    final challenge = msg.sublist(24, 32);
    var infoLen = 0;
    var infoOff = 0;
    if (msg.length >= 48) {
      infoLen = bd.getUint16(40, Endian.little);
      infoOff = bd.getUint32(44, Endian.little);
    }
    Uint8List slice(int off, int len) {
      if (len <= 0 || off < 0 || off + len > msg.length) {
        return Uint8List(0);
      }
      return msg.sublist(off, off + len);
    }

    return NtlmChallenge(
      serverChallenge: challenge,
      flags: flags,
      targetName: _decodeUtf16(slice(nameOff, nameLen)),
      targetInfo: slice(infoOff, infoLen),
    );
  }

  /// AV_PAIR 类型 (MS-NLMP 2.2.2.1)
  static const int avNbComputerName = 0x0001;
  static const int avNbDomainName = 0x0002;
  static const int avDnsComputerName = 0x0003;
  static const int avDnsDomainName = 0x0004;
  static const int avDnsTreeName = 0x0005;

  /// 解析 TargetInfo 里的 AV_PAIR 序列, 返回 类型 -> UTF-16 值。
  /// 服务端的权威主机名就在这里(MsvAvDnsComputerName / MsvAvNbComputerName),
  /// 比 NBSTAT 探测可靠, 用于\"尽量以主机名展示/连接\"。
  Map<int, String> avPairs() {
    final out = <int, String>{};
    final info = targetInfo;
    if (info.length < 4) {
      return out;
    }
    final bd = ByteData.sublistView(info);
    var offset = 0;
    while (offset + 4 <= info.length) {
      final id = bd.getUint16(offset, Endian.little);
      final len = bd.getUint16(offset + 2, Endian.little);
      offset += 4;
      if (id == 0x0000) {
        break; // MsvAvEOL
      }
      if (len < 0 || offset + len > info.length) {
        break;
      }
      if (len > 0) {
        out[id] = _decodeUtf16(info.sublist(offset, offset + len));
      }
      offset += len;
    }
    return out;
  }

  @override
  String toString() =>
      'NtlmChallenge(target=$targetName, flags=0x${flags.toRadixString(16)}, '
      'infoLen=${targetInfo.length}, challenge=${_hex(serverChallenge)})';
}

String _decodeUtf16(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// NTOWFv2: MD4(password) 的 UTF-16 摘要, 再以其为 key 对
/// UPPER(User)+Domain 做 HMAC-MD5 (MS-NLMP 3.3.2)
Uint8List ntowfv2({
  required String password,
  required String user,
  required String domain,
}) {
  final ntHash = md4(_utf16Le(password));
  return Uint8List.fromList(
    Hmac(md5, ntHash).convert(_utf16Le(user.toUpperCase() + domain)).bytes,
  );
}

/// NTLMv2 认证响应
class NtlmResponse {
  NtlmResponse({
    required this.lmChallengeResponse,
    required this.ntChallengeResponse,
    required this.sessionKey,
    required this.ntProofStr,
  });

  final Uint8List lmChallengeResponse;
  final Uint8List ntChallengeResponse;

  /// 用于 SMB2 签名的会话密钥(SessionBaseKey)
  final Uint8List sessionKey;
  final Uint8List ntProofStr;
}

/// 计算 NTLMv2 的 LM/NT 响应与会话密钥 (MS-NLMP 3.3.2 / 4.2.4)
NtlmResponse computeNtlmV2({
  required Uint8List responseKeyNt,
  required Uint8List serverChallenge,
  required Uint8List clientChallenge,
  required Uint8List targetInfo,
  required Uint8List timestamp,
  Uint8List? lmClientChallenge,
}) {
  final lmChallenge = lmClientChallenge ?? clientChallenge;
  Uint8List hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(Hmac(md5, key).convert(data).bytes);

  // temp = RespType | HiRespType | Z(6) | Time | ClientChallenge | Z(4) | AvPairs | Z(4)
  final temp = BytesBuilder()
    ..add([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    ..add(timestamp)
    ..add(clientChallenge)
    ..add([0x00, 0x00, 0x00, 0x00])
    ..add(targetInfo)
    ..add([0x00, 0x00, 0x00, 0x00]);
  final tempBytes = temp.toBytes();

  final ntProofStr = hmac(responseKeyNt, [...serverChallenge, ...tempBytes]);
  final ntChallengeResponse = Uint8List.fromList([
    ...ntProofStr,
    ...tempBytes,
  ]);
  final sessionKey = hmac(responseKeyNt, ntProofStr);

  // LMv2
  final lmProof = hmac(responseKeyNt, [...serverChallenge, ...lmChallenge]);
  final lmChallengeResponse = Uint8List.fromList([...lmProof, ...lmChallenge]);

  return NtlmResponse(
    lmChallengeResponse: lmChallengeResponse,
    ntChallengeResponse: ntChallengeResponse,
    sessionKey: sessionKey,
    ntProofStr: ntProofStr,
  );
}

/// NTLMSSP Type 3 (Authenticate)
///
/// [anonymous] 为 true 时不带用户名/密码, 由服务端映射为 guest。
Uint8List buildType3({
  required NtlmChallenge challenge,
  required NtlmResponse? response,
  String domain = '',
  String user = '',
  String workstation = '',
  bool anonymous = false,
  int? flags,
}) {
  final lm = response?.lmChallengeResponse ?? Uint8List(0);
  final nt = response?.ntChallengeResponse ?? Uint8List(0);
  final domainBytes = domain.isEmpty ? Uint8List(0) : _utf16Le(domain);
  final userBytes = user.isEmpty ? Uint8List(0) : _utf16Le(user);
  final wsBytes = workstation.isEmpty ? Uint8List(0) : _utf16Le(workstation);
  final sessionKey = Uint8List(0); // 未协商 KEY_EXCH

  const headerLen = 88; // 含 Version(8) 与 MIC(16)
  final payloadLen =
      lm.length +
      nt.length +
      domainBytes.length +
      userBytes.length +
      wsBytes.length +
      sessionKey.length;
  final out = Uint8List(headerLen + payloadLen);
  final bd = ByteData.sublistView(out);

  out.setRange(0, 8, ntlmSignatureBytes());
  bd.setUint32(8, 3, Endian.little);

  var offset = headerLen;
  void field(int at, List<int> data) {
    bd.setUint16(at, data.length, Endian.little);
    bd.setUint16(at + 2, data.length, Endian.little);
    bd.setUint32(at + 4, offset, Endian.little);
    out.setRange(offset, offset + data.length, data);
    offset += data.length;
  }

  field(12, lm);
  field(20, nt);
  field(28, domainBytes);
  field(36, userBytes);
  field(44, wsBytes);
  field(52, sessionKey);
  bd.setUint32(
    60,
    flags ?? (challenge.flags | NtlmFlags.negotiateUnicode),
    Endian.little,
  );
  out.setRange(64, 72, kNtlmVersion);
  // MIC 先置零, 计算完再写回
  out.setRange(72, 88, Uint8List(16));

  if (!anonymous && response != null) {
    final mic = Hmac(
      md5,
      response.sessionKey,
    ).convert(out).bytes; // 此时 MIC 区域为全零
    out.setRange(72, 88, mic);
  }
  return out;
}

/// 便捷方法: 直接由账号密码与 Type2 生成 Type3 与会话密钥
({Uint8List type3, Uint8List sessionKey}) authenticate({
  required NtlmChallenge challenge,
  required String user,
  required String password,
  required String domain,
  String workstation = 'PILIPLAYER',
  Random? random,
}) {
  final rng = random ?? Random.secure();
  final clientChallenge = Uint8List.fromList(
    List<int>.generate(8, (_) => rng.nextInt(256)),
  );
  final responseKey = ntowfv2(
    password: password,
    user: user,
    domain: domain,
  );
  final resp = computeNtlmV2(
    responseKeyNt: responseKey,
    serverChallenge: challenge.serverChallenge,
    clientChallenge: clientChallenge,
    targetInfo: challenge.targetInfo,
    timestamp: fileTimeNow(),
    lmClientChallenge: clientChallenge,
  );
  final type3 = buildType3(
    challenge: challenge,
    response: resp,
    domain: domain,
    user: user,
    workstation: workstation,
  );
  return (type3: type3, sessionKey: resp.sessionKey);
}

/// 匿名会话: Type1 之后直接用空凭据构造 Type3, 由服务端映射为 guest
Uint8List buildAnonymousType3(NtlmChallenge challenge) => buildType3(
  challenge: challenge,
  response: null,
  anonymous: true,
);

/// 调试用
String ntlmHex(List<int> bytes) => _hex(bytes);
