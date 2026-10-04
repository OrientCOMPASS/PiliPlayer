import 'dart:async';
import 'dart:io' show exit, Platform;
import 'dart:math' as math;

import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyUpEvent, LogicalKeyboardKey, HardwareKeyboard;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class PlayerFocus extends StatelessWidget {
  /// 手柄 L1/R1 的单次快退/快进步长
  static const Duration kShoulderSeek = Duration(seconds: 60);

  const PlayerFocus({
    super.key,
    required this.child,
    required this.plPlayerController,
    this.introController,
    required this.onSendDanmaku,
    this.canPlay,
    this.onSkipSegment,
    this.onRefresh,
  });

  final Widget child;
  final PlPlayerController plPlayerController;
  final CommonIntroController? introController;
  final VoidCallback onSendDanmaku;
  final ValueGetter<bool>? canPlay;
  final ValueGetter<bool>? onSkipSegment;
  final VoidCallback? onRefresh;

  static bool _shouldHandle(LogicalKeyboardKey logicalKey) {
    return logicalKey == LogicalKeyboardKey.tab ||
        logicalKey == LogicalKeyboardKey.arrowLeft ||
        logicalKey == LogicalKeyboardKey.arrowRight ||
        logicalKey == LogicalKeyboardKey.arrowUp ||
        logicalKey == LogicalKeyboardKey.arrowDown;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        final handled = _handleKey(context, event);
        if (handled || _shouldHandle(event.logicalKey)) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  bool get isFullScreen => plPlayerController.isFullScreen.value;
  bool get hasPlayer => plPlayerController.videoPlayerController != null;

  void _setVolume({required bool isIncrease}) {
    final volume = isIncrease
        ? math.min(
            plPlayerController.maxVolume,
            plPlayerController.volume.value + 0.1,
          )
        : math.max(0.0, plPlayerController.volume.value - 0.1);
    plPlayerController.setVolume(volume);
  }

  void _updateVolume(KeyEvent event, {required bool isIncrease}) {
    if (event is KeyDownEvent) {
      if (hasPlayer) {
        _setVolume(isIncrease: isIncrease);
        plPlayerController
          ..longPressTimer?.cancel()
          ..longPressTimer = Timer.periodic(
            const Duration(milliseconds: 150),
            (_) => _setVolume(isIncrease: isIncrease),
          );
      }
    } else if (event is KeyUpEvent) {
      plPlayerController.cancelLongPressTimer();
    }
  }

  bool _handleKey(BuildContext context, KeyEvent event) {
    final key = event.logicalKey;

    // VR 操作模式下的手柄按键(第十九轮 需求5): 三角 = 摆正视角,
    // 方块 = 切换眼位。安卓把 PS 手柄的 △ 报成 KEYCODE_BUTTON_Y、□ 报成
    // KEYCODE_BUTTON_X(Xbox 手柄上就是 Y / X), Flutter 侧对应
    // gameButtonY / gameButtonX。
    //
    // 这两个键在 VR 模式下**优先吃掉**, 并且不去点亮控件层 —— 手柄环视时
    // 弹出播放器 UI 只会挡住画面与 VR 按钮(需求原文: 手柄操作不应唤起
    // 播放器 UI)。摇杆部分见 VrControlLayer 的 GamepadPoller。
    // (第二十轮按需求 revert: 十字键不再改成视角步进/长按连发, 仍是
    //  原来的快退快进与音量。)
    if (plPlayerController.vrControlMode.value) {
      // 只认 KeyDownEvent: 长按产生的是 KeyRepeatEvent, 不会重复触发
      if (key == LogicalKeyboardKey.gameButtonY) {
        if (event is KeyDownEvent) {
          plPlayerController.resetVrView();
        }
        return true;
      }
      if (key == LogicalKeyboardKey.gameButtonX) {
        if (event is KeyDownEvent) {
          plPlayerController.toggleVrEye();
        }
        return true;
      }
    }

    // DS/DualShock 手柄的 × 键(安卓 KEYCODE_BUTTON_A -> gameButtonA,
    // Xbox 手柄上就是 A): **全屏时**切换播放/暂停(第二十轮 需求1),
    // 与空格键、双击画面中间是同一个动作(带播放/暂停的浮层反馈)。
    // 非全屏不吃这个键, 让它继续走系统焦点(否则页面里的按钮没法用手柄确认)。
    if (key == LogicalKeyboardKey.gameButtonA && isFullScreen) {
      if (event is KeyDownEvent && hasPlayer) {
        if (plPlayerController.isLive || (canPlay?.call() ?? true)) {
          plPlayerController.onDoubleTapCenter();
        }
      }
      return true;
    }

    final isKeyQ = key == LogicalKeyboardKey.keyQ;
    if (isKeyQ || key == LogicalKeyboardKey.keyR) {
      if (HardwareKeyboard.instance.isMetaPressed) {
        if (isKeyQ && Platform.isMacOS) {
          exit(0);
        }
        return true;
      }
      if (event is KeyDownEvent) {
        if (plPlayerController.isLive) {
          onRefresh?.call();
        } else {
          introController!.onStartTriple();
        }
      } else if (event is KeyUpEvent && !plPlayerController.isLive) {
        introController!.onCancelTriple(isKeyQ);
      }
      return true;
    } else if (event is KeyDownEvent) {
      if (introController?.isTripling ?? false) {
        introController!.onCancelTriple();
      }
    }

    // 手柄肩键(第十八轮手柄适配): L1/R1 = 快退/快进 60 秒。
    // 十字键左/右(快退/快进用户设定时长, 默认 10s)与上/下(音量)天然
    // 映射为方向键, 走下面既有分支; B 键已在 MainActivity 映射为返回。
    if (key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.gameButtonRight1) {
      if (event is KeyDownEvent && hasPlayer && !plPlayerController.isLive) {
        if (key == LogicalKeyboardKey.gameButtonRight1) {
          plPlayerController.onForward(kShoulderSeek);
        } else {
          plPlayerController.onBackward(kShoulderSeek);
        }
      }
      return true;
    }

    final isArrowUp = key == LogicalKeyboardKey.arrowUp;
    if (isArrowUp || key == LogicalKeyboardKey.arrowDown) {
      _updateVolume(event, isIncrease: isArrowUp);
      return true;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (!plPlayerController.isLive) {
        if (event is KeyDownEvent) {
          if (hasPlayer && !plPlayerController.longPressStatus.value) {
            plPlayerController
              ..longPressTimer?.cancel()
              ..longPressTimer = Timer(
                const Duration(milliseconds: 200),
                () => plPlayerController
                  ..cancelLongPressTimer()
                  ..setLongPressStatus(true),
              );
          }
        } else if (event is KeyUpEvent) {
          plPlayerController.cancelLongPressTimer();
          if (hasPlayer) {
            if (plPlayerController.longPressStatus.value) {
              plPlayerController.setLongPressStatus(false);
            } else {
              plPlayerController.onForward(
                plPlayerController.fastForBackwardDuration,
              );
            }
          }
        }
      }
      return true;
    }

    if (event is KeyDownEvent) {
      switch (key) {
        case LogicalKeyboardKey.space:
          if (plPlayerController.isLive || canPlay!()) {
            if (hasPlayer) {
              plPlayerController.onDoubleTapCenter();
            }
          }
          return true;

        case LogicalKeyboardKey.keyF:
          final isFullScreen = this.isFullScreen;
          if (isFullScreen && plPlayerController.controlsLock.value) {
            plPlayerController
              ..controlsLock.value = false
              ..showControls.value = false;
          }
          plPlayerController.triggerFullScreen(
            status: !isFullScreen,
            inAppFullScreen: HardwareKeyboard.instance.isShiftPressed,
          );
          return true;

        case LogicalKeyboardKey.keyD:
          final newVal = !plPlayerController.enableShowDanmakuAdaptive.value;
          plPlayerController.enableShowDanmakuAdaptive.value = newVal;
          if (!plPlayerController.tempPlayerConf) {
            GStorage.setting.put(
              plPlayerController.isLive
                  ? SettingBoxKey.enableShowLiveDanmaku
                  : SettingBoxKey.enableShowDanmaku,
              newVal,
            );
          }
          return true;

        case LogicalKeyboardKey.keyP:
          return true;

        case LogicalKeyboardKey.keyM:
          if (hasPlayer) {
            final isMuted = !plPlayerController.isMuted;
            plPlayerController.videoPlayerController!.setVolume(
              isMuted ? 0 : plPlayerController.volume.value * 100,
            );
            plPlayerController.isMuted = isMuted;
            SmartDialog.showToast('${isMuted ? '' : '取消'}静音');
          }
          return true;

        case LogicalKeyboardKey.keyS:
          if (hasPlayer && isFullScreen) {
            plPlayerController.takeScreenshot();
          }
          return true;

        case LogicalKeyboardKey.keyL:
          if (isFullScreen || plPlayerController.isDesktopPip) {
            plPlayerController.onLockControl(
              !plPlayerController.controlsLock.value,
            );
          }
          return true;

        case LogicalKeyboardKey.enter:
          if (onSkipSegment?.call() ?? false) {
            return true;
          }
          onSendDanmaku();
          return true;
      }

      if (!plPlayerController.isLive) {
        final isDigit1 = key == LogicalKeyboardKey.digit1;
        if (isDigit1 || key == LogicalKeyboardKey.digit2) {
          if (HardwareKeyboard.instance.isShiftPressed && hasPlayer) {
            final speed = isDigit1 ? 1.0 : 2.0;
            if (speed != plPlayerController.playbackSpeed) {
              plPlayerController.setPlaybackSpeed(speed);
            }
            SmartDialog.showToast('${speed}x播放');
          }
          return true;
        }

        switch (key) {
          case LogicalKeyboardKey.arrowLeft:
            if (hasPlayer) {
              plPlayerController.onBackward(
                plPlayerController.fastForBackwardDuration,
              );
            }
            return true;

          case LogicalKeyboardKey.keyW:
            if (HardwareKeyboard.instance.isMetaPressed) {
              return true;
            }
            introController?.actionCoinVideo();
            return true;

          case LogicalKeyboardKey.keyE:
            introController?.actionFavVideo(isQuick: true);
            return true;

          case LogicalKeyboardKey.keyT || LogicalKeyboardKey.keyV:
            introController?.viewLater();
            return true;

          case LogicalKeyboardKey.keyG:
            if (introController case final UgcIntroController ugcCtr) {
              ugcCtr.actionRelationMod(context);
            }
            return true;

          case LogicalKeyboardKey.bracketLeft:
            if (introController case final introController?) {
              if (!introController.prevPlay()) {
                SmartDialog.showToast('已经是第一集了');
              }
            }
            return true;

          case LogicalKeyboardKey.bracketRight:
            if (introController case final introController?) {
              if (!introController.nextPlay()) {
                SmartDialog.showToast('已经是最后一集了');
              }
            }
            return true;
        }
      }
    }

    return false;
  }
}
