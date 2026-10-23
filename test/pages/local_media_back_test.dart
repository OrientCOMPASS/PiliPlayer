import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「本地」板块 Tab 内浏览的返回键分发单测 —— 第二十九轮。
///
/// 浏览不再推新路由后, 系统返回键的语义全压在
/// [LocalMediaController.handleBack] 这一个状态机上:
///   浏览页内部层级(回上一级/退出检索) > 退出浏览回来源列表 > 不消费
/// (不消费时由外层按原逻辑处理: Tab 场景跳回首页 Tab, 独立路由场景 pop 路由。)
/// 这里不依赖 GetX 注册/Widget 树, 直接实例化控制器钉死分发顺序。
void main() {
  const source = LocalMediaSource(
    type: LocalMediaSourceType.device,
    name: '内部存储',
    url: '/storage/emulated/0',
  );

  group('LocalMediaController Tab 内浏览与返回键分发', () {
    late LocalMediaController controller;

    setUp(() => controller = LocalMediaController());

    test('初始不在浏览态, 返回键不消费(交回外层原逻辑)', () {
      expect(controller.browseTarget.value, isNull);
      expect(controller.handleBack(), isFalse);
    });

    test('openBrowser 进入浏览态; 浏览页回调未挂载时返回键=退出浏览', () {
      controller.openBrowser(source: source, path: '/Movies', title: '电影');
      final target = controller.browseTarget.value;
      expect(target, isNotNull);
      expect(target!.source.url, '/storage/emulated/0');
      expect(target.path, '/Movies');
      expect(target.title, '电影');
      expect(controller.handleBack(), isTrue);
      expect(controller.browseTarget.value, isNull);
    });

    test('浏览页已挂载: 返回键先被它消费(回上一级), 不退出浏览', () {
      controller.openBrowser(source: source, path: '/Movies');
      var popped = 0;
      bool back() {
        popped++;
        return true;
      }

      controller.registerBrowserBack(back);
      addTearDown(() => controller.unregisterBrowserBack(back));
      expect(controller.handleBack(), isTrue);
      expect(popped, 1);
      expect(controller.browseTarget.value, isNotNull);
    });

    test('浏览页在根层(回调返回 false): 返回键退出浏览回来源列表', () {
      controller.openBrowser(source: source, path: '/Movies');
      bool backAtRoot() => false;
      controller.registerBrowserBack(backAtRoot);
      addTearDown(() => controller.unregisterBrowserBack(backAtRoot));
      expect(controller.handleBack(), isTrue);
      expect(controller.browseTarget.value, isNull);
    });

    test('unregister 只摘自己挂的回调, 不误伤别人的', () {
      controller.openBrowser(source: source, path: '/a');
      bool backA() => true;
      bool backB() => true;
      controller
        ..registerBrowserBack(backA)
        ..unregisterBrowserBack(backB);
      // backA 仍在: 返回键应被它消费, 不应退出浏览
      expect(controller.handleBack(), isTrue);
      expect(controller.browseTarget.value, isNotNull);
      controller.unregisterBrowserBack(backA);
      // backA 摘掉后: 返回键回到"退出浏览"语义
      expect(controller.handleBack(), isTrue);
      expect(controller.browseTarget.value, isNull);
    });

    test('exitBrowse 直接回来源列表, 之后返回键不再消费', () {
      controller
        ..openBrowser(source: source, path: '/a')
        ..exitBrowse();
      expect(controller.browseTarget.value, isNull);
      expect(controller.handleBack(), isFalse);
    });

    test('两次 openBrowser 产生不同 target(内嵌页按 ValueKey 重建 State)', () {
      controller.openBrowser(source: source, path: '/a');
      final t1 = controller.browseTarget.value;
      controller
        ..exitBrowse()
        ..openBrowser(source: source, path: '/a');
      final t2 = controller.browseTarget.value;
      expect(identical(t1, t2), isFalse);
      expect(t2?.path, '/a');
    });

    test('openBrowser 可携带 initialItems(SMB 共享列表直进根目录)', () {
      controller.openBrowser(
        source: source,
        path: '',
        initialItems: const [],
      );
      expect(controller.browseTarget.value?.initialItems, isEmpty);
    });
  });
}
