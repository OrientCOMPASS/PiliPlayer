import 'dart:typed_data';

/// MD4 (RFC 1320)。
///
/// `package:crypto` 只提供 MD5/SHA 系列, 而 NTLM 的 NTOWFv1 必须用 MD4,
/// 所以这里自带一份实现(纯 Dart, 无平台依赖)。
/// 已知答案测试见 `test/services/smb/ntlm_test.dart`。
Uint8List md4(List<int> message) {
  final bitLen = message.length * 8;
  final input = <int>[...message, 0x80];
  while (input.length % 64 != 56) {
    input.add(0);
  }
  final lenBytes = ByteData(8)..setUint64(0, bitLen, Endian.little);
  input.addAll(lenBytes.buffer.asUint8List());

  var a = 0x67452301;
  var b = 0xefcdab89;
  var c = 0x98badcfe;
  var d = 0x10325476;

  int rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xffffffff;

  for (var off = 0; off < input.length; off += 64) {
    final x = Uint32List(16);
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      x[i] =
          input[j] |
          (input[j + 1] << 8) |
          (input[j + 2] << 16) |
          (input[j + 3] << 24);
    }

    var aa = a;
    var bb = b;
    var cc = c;
    var dd = d;

    // Round 1: F(x,y,z) = (x & y) | (~x & z)
    int f(int x, int y, int z) => (x & y) | ((~x & 0xffffffff) & z);

    // 按 RFC 1320 的顺序展开: 每步更新一个寄存器并轮转 (a,b,c,d)
    void r1(int i, int s) {
      // a = rotl(a + F(b,c,d) + X[i], s) 然后轮转 (a,b,c,d)
      final v = rotl((a + f(b, c, d) + x[i]) & 0xffffffff, s);
      a = d;
      d = c;
      c = b;
      b = v;
    }

    void r2(int i, int s) {
      int g(int x, int y, int z) => (x & y) | (x & z) | (y & z);
      final v =
          rotl(
            (a +
                g(b, c, d) +
                x[i] +
                0x5a827999) &
            0xffffffff,
            s,
          );
      a = d;
      d = c;
      c = b;
      b = v;
    }

    void r3(int i, int s) {
      int h(int x, int y, int z) => x ^ y ^ z;
      final v =
          rotl(
            (a +
                h(b, c, d) +
                x[i] +
                0x6ed9eba1) &
            0xffffffff,
            s,
          );
      a = d;
      d = c;
      c = b;
      b = v;
    }

    // Round 1
    r1(0, 3);
    r1(1, 7);
    r1(2, 11);
    r1(3, 19);
    r1(4, 3);
    r1(5, 7);
    r1(6, 11);
    r1(7, 19);
    r1(8, 3);
    r1(9, 7);
    r1(10, 11);
    r1(11, 19);
    r1(12, 3);
    r1(13, 7);
    r1(14, 11);
    r1(15, 19);
    // Round 2
    r2(0, 3);
    r2(4, 5);
    r2(8, 9);
    r2(12, 13);
    r2(1, 3);
    r2(5, 5);
    r2(9, 9);
    r2(13, 13);
    r2(2, 3);
    r2(6, 5);
    r2(10, 9);
    r2(14, 13);
    r2(3, 3);
    r2(7, 5);
    r2(11, 9);
    r2(15, 13);
    // Round 3
    r3(0, 3);
    r3(8, 9);
    r3(4, 11);
    r3(12, 15);
    r3(2, 3);
    r3(10, 9);
    r3(6, 11);
    r3(14, 15);
    r3(1, 3);
    r3(9, 9);
    r3(5, 11);
    r3(13, 15);
    r3(3, 3);
    r3(11, 9);
    r3(7, 11);
    r3(15, 15);

    a = (a + aa) & 0xffffffff;
    b = (b + bb) & 0xffffffff;
    c = (c + cc) & 0xffffffff;
    d = (d + dd) & 0xffffffff;
  }

  final out = ByteData(16)
    ..setUint32(0, a, Endian.little)
    ..setUint32(4, b, Endian.little)
    ..setUint32(8, c, Endian.little)
    ..setUint32(12, d, Endian.little);
  return out.buffer.asUint8List();
}
