import 'package:PiliPlus/models/common/enum_with_label.dart';

/// 「本地」板块的列表排序方式
enum LocalMediaSort with EnumWithLabel {
  name('名称'),
  modified('修改时间'),
  size('大小'),
  ;

  @override
  final String label;
  const LocalMediaSort(this.label);
}
