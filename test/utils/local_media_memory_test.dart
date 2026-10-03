import 'dart:convert' show jsonEncode;

import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/utils/local_media_memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放设置记忆(第二十轮 需求1)的序列化回归测试。
///
/// 只测纯逻辑部分([LocalMediaSettings] 的 JSON 往返): 读写盒子那一层
/// ([LocalMediaMemory])要 Hive 初始化, 归 CI 的编译与真机验证。
///
/// 这里最容易出错的是"字段缺省语义": null 表示**不记忆该项**(下次跟随
/// 全局默认), 而不是"记住一个空值"—— 倍速与全局默认一致时不写、普通 2D
/// 片源不写 VR 块, 都靠这个语义撑着。
void main() {
  group('LocalMediaSettings JSON', () {
    test('全字段往返', () {
      const settings = LocalMediaSettings(
        speed: 1.5,
        vrProjection: VrProjection.sbs360,
        vrEye: VrEye.right,
        vrFov: 102.5,
        vrGyro: true,
      );
      final restored = LocalMediaSettings.fromEncoded(
        jsonEncode(settings.toJson()),
      );
      expect(restored, isNotNull);
      expect(restored!.speed, 1.5);
      expect(restored.vrProjection, VrProjection.sbs360);
      expect(restored.vrEye, VrEye.right);
      expect(restored.vrFov, 102.5);
      expect(restored.vrGyro, isTrue);
      expect(restored.hasVr, isTrue);
      expect(restored.isEmpty, isFalse);
    });

    test('null 字段不进 JSON, 读回来仍是 null(= 跟随全局默认)', () {
      const settings = LocalMediaSettings(speed: 2.0);
      final json = settings.toJson();
      expect(json.containsKey('speed'), isTrue);
      expect(json.containsKey('vr'), isFalse);
      expect(json.containsKey('eye'), isFalse);
      expect(json.containsKey('fov'), isFalse);
      expect(json.containsKey('gyro'), isFalse);

      final restored = LocalMediaSettings.fromEncoded(jsonEncode(json));
      expect(restored!.speed, 2.0);
      expect(restored.vrProjection, isNull);
      expect(restored.vrEye, isNull);
      expect(restored.vrFov, isNull);
      expect(restored.vrGyro, isNull);
      expect(restored.hasVr, isFalse);
    });

    test('空设置视为"没有记忆"', () {
      const settings = LocalMediaSettings();
      expect(settings.isEmpty, isTrue);
      expect(settings.toJson(), isEmpty);
    });

    test('脏数据不抛异常', () {
      expect(LocalMediaSettings.fromEncoded(null), isNull);
      expect(LocalMediaSettings.fromEncoded(''), isNull);
      expect(LocalMediaSettings.fromEncoded('not json'), isNull);
      expect(LocalMediaSettings.fromEncoded('[1,2,3]'), isNull);
      expect(LocalMediaSettings.fromEncoded(42), isNull);
    });

    test('不认识的枚举名/类型按 null 处理(旧版本数据向前兼容)', () {
      final restored = LocalMediaSettings.fromEncoded(
        jsonEncode(<String, Object?>{
          'speed': '1.5', // 类型不对
          'vr': 'cubemap', // 范围外格式, 枚举里没有
          'eye': 'middle',
          'fov': 90,
          'gyro': 'yes',
        }),
      );
      expect(restored, isNotNull);
      expect(restored!.speed, isNull);
      expect(restored.vrProjection, isNull);
      expect(restored.vrEye, isNull);
      expect(restored.vrFov, 90);
      expect(restored.vrGyro, isNull);
    });

    test('整数形式的倍速/视场角也能读(num -> double)', () {
      final restored = LocalMediaSettings.fromEncoded(
        jsonEncode(<String, Object?>{'speed': 2, 'fov': 90}),
      );
      expect(restored!.speed, 2.0);
      expect(restored.vrFov, 90.0);
    });
  });

  group('keyOf', () {
    test('同一 uri 稳定同键, 不同 uri 不同键', () {
      expect(
        LocalMediaMemory.keyOf('/storage/emulated/0/a.mkv'),
        LocalMediaMemory.keyOf('/storage/emulated/0/a.mkv'),
      );
      expect(
        LocalMediaMemory.keyOf('/storage/emulated/0/a.mkv'),
        isNot(LocalMediaMemory.keyOf('/storage/emulated/0/b.mkv')),
      );
      expect(
        LocalMediaMemory.keyOf('x').startsWith('localMem:'),
        isTrue,
      );
    });
  });
}
