import 'dart:math' show Random;

import 'package:PiliPlus/models/common/enum_with_label.dart';

enum PlayRepeat implements EnumWithLabel {
  pause('播完暂停'),
  listOrder('顺序播放'),
  singleCycle('单个循环'),
  listCycle('列表循环'),
  autoPlayRelated('自动连播'),

  /// 随机播放(第十八轮新增)。
  /// **必须追加在枚举末尾**: 设置里持久化的是 index, 插队会静默改变
  /// 老用户已保存的播放顺序语义。
  shuffleList('随机播放'),
  ;

  @override
  final String label;
  const PlayRepeat(this.label);

  /// 随机播放的索引选择: 在 [length] 个条目里均匀随机挑一个, 尽量避开
  /// [current](条目数 >1 时保证不连续重复同一条)。current 非法时纯随机。
  static int randomIndex(int length, int current) {
    if (length <= 0) {
      return -1;
    }
    if (length == 1) {
      return 0;
    }
    final rng = Random();
    if (current < 0 || current >= length) {
      return rng.nextInt(length);
    }
    final i = rng.nextInt(length - 1);
    return i >= current ? i + 1 : i;
  }
}
