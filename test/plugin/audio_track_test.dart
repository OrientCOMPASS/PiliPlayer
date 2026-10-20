import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack;

/// 底栏「音轨」快切按钮的纯逻辑回归测试 —— 第二十八轮。
///
/// 按钮本体(view.dart 的 BottomControlType.audioTrack)与轨道切换
/// (selectInternalAudioById -> mpv aid)都要真机播放器才能跑, 这里钉死
/// 两个纯函数:
///   * trackLabel —— 轨道展示名(标题 > 语言 > 序号, 末尾附编码);
///   * audioTrackLabel —— 当前生效音轨 id 解析成展示名, auto/no/未知
///     一律回退「自动」(底栏按钮旁的标签就是它)。
void main() {
  group('PlPlayerController.trackLabel', () {
    test('标题优先, 末尾附编码', () {
      expect(
        PlPlayerController.trackLabel(
          id: '1',
          title: '国语',
          language: 'zh',
          codec: 'aac',
        ),
        '国语 (aac)',
      );
    });

    test('无标题用语言', () {
      expect(
        PlPlayerController.trackLabel(id: '2', language: 'ja', codec: 'flac'),
        'ja (flac)',
      );
    });

    test('标题语言都没有时用轨道序号', () {
      expect(PlPlayerController.trackLabel(id: '7'), '轨道 7');
    });

    test('编码为空不附加括号', () {
      expect(
        PlPlayerController.trackLabel(id: '3', title: '原声', codec: ''),
        '原声',
      );
    });
  });

  group('PlPlayerController.audioTrackLabel', () {
    final tracks = [
      AudioTrack('1', '国语', 'zh'),
      AudioTrack('2', '原声', 'ja'),
    ];

    test('命中轨道显示轨道名', () {
      expect(PlPlayerController.audioTrackLabel('2', tracks), '原声');
    });

    test('auto/no/空一律显示自动', () {
      expect(PlPlayerController.audioTrackLabel('auto', tracks), '自动');
      expect(PlPlayerController.audioTrackLabel('no', tracks), '自动');
      expect(PlPlayerController.audioTrackLabel('', tracks), '自动');
    });

    test('未知 id 回退自动(轨道表未就绪的窗口期)', () {
      expect(PlPlayerController.audioTrackLabel('99', tracks), '自动');
    });

    test('空轨道列表显示自动', () {
      expect(PlPlayerController.audioTrackLabel('auto', const []), '自动');
    });
  });
}
