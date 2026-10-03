import 'package:PiliPlus/plugin/pl_player/utils/gamepad.dart';
import 'package:flutter_test/flutter_test.dart';

/// VR 手柄环视的换算逻辑(需求5)。
///
/// 摇杆读数本身来自 native(Gamepad.kt 缓存 MotionEvent 的模拟轴,
/// Dart 侧轮询), 这一段纯数学是"手感"的全部来源, 必须钉死:
///   * 死区: 摇杆静置的抖动不能让画面慢慢飘;
///   * 方向: 推右 = 看右(yaw 增大), 推上 = 看上(pitch 减小);
///   * 时间片夹取: 掉帧/切后台回来不能瞬移。
void main() {
  group('GamepadMath.axis', () {
    test('死区内归零(含边界)', () {
      expect(GamepadMath.axis(0), 0);
      expect(GamepadMath.axis(0.1), 0);
      expect(GamepadMath.axis(-0.1), 0);
      expect(GamepadMath.axis(GamepadMath.deadZone), 0);
      expect(GamepadMath.axis(-GamepadMath.deadZone), 0);
    });

    test('满偏映射到 ±1', () {
      expect(GamepadMath.axis(1), 1);
      expect(GamepadMath.axis(-1), -1);
    });

    test('死区外线性重映射, 刚过死区时从 0 平滑起步', () {
      // (0.575 - 0.15) / 0.85 == 0.5
      expect(GamepadMath.axis(0.575), closeTo(0.5, 1e-9));
      expect(GamepadMath.axis(-0.575), closeTo(-0.5, 1e-9));
      // 刚过死区一点点, 增量也应该只有一点点
      expect(GamepadMath.axis(0.16).abs(), lessThan(0.02));
    });

    test('异常值不炸', () {
      expect(GamepadMath.axis(double.nan), 0);
      expect(GamepadMath.axis(double.infinity), 0);
      expect(GamepadMath.axis(double.negativeInfinity), 0);
    });
  });

  group('GamepadMath.look', () {
    test('推右 = yaw 增大, 推上 = pitch 减小', () {
      final right = GamepadMath.look(1, 0, 0.1);
      expect(right.yaw, closeTo(GamepadMath.degPerSec * 0.1, 1e-9));
      expect(right.pitch, 0);

      final up = GamepadMath.look(0, -1, 0.1);
      expect(up.yaw, 0);
      expect(up.pitch, closeTo(-GamepadMath.degPerSec * 0.1, 1e-9));

      final downRight = GamepadMath.look(1, 1, 0.1);
      expect(downRight.yaw, greaterThan(0));
      expect(downRight.pitch, greaterThan(0));
    });

    test('静止与非法时间片不产生增量', () {
      expect(GamepadMath.look(0, 0, 0.1).yaw, 0);
      expect(GamepadMath.look(0.05, -0.05, 0.1).pitch, 0);
      expect(GamepadMath.look(1, 1, 0).yaw, 0);
      expect(GamepadMath.look(1, 1, -1).yaw, 0);
    });

    test('时间片夹取: 卡顿之后不会一次转飞', () {
      final jumped = GamepadMath.look(1, 0, 30);
      expect(
        jumped.yaw,
        closeTo(GamepadMath.degPerSec * GamepadMath.maxDeltaSeconds, 1e-9),
      );
    });

    test('半偏时角速度约为满偏的一半', () {
      // 时间片要小于 maxDeltaSeconds, 否则先被夹取(那是上一条测试的事)
      const dt = 0.2;
      final half = GamepadMath.look(0.575, 0, dt);
      final full = GamepadMath.look(1, 0, dt);
      expect(half.yaw, closeTo(GamepadMath.degPerSec * dt * 0.5, 1e-9));
      expect(full.yaw, closeTo(GamepadMath.degPerSec * dt, 1e-9));
      expect(half.yaw, closeTo(full.yaw / 2, 1e-9));
    });
  });
}
