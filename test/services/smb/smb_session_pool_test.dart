import 'dart:io' show SocketException;

import 'package:PiliPlus/services/smb/smb2_client.dart' show NtStatus, SmbException;
import 'package:PiliPlus/services/smb/smb_session_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 会话复用池的判定逻辑（纯逻辑，不需要真实 smbd）。
///
/// 复用的前提是"错误分诊"要准：连接/会话层面的错误必须作废会话，
/// 文件层面的错误必须**保留**会话 —— 判反了要么反复重连（白握手），
/// 要么抱着一条坏连接一直失败。
void main() {
  group('isFatalError', () {
    test('会话失效要作废会话', () {
      expect(
        SmbSessionPool.isFatalError(
          const SmbException(NtStatus.userSessionDeleted, 'read'),
        ),
        isTrue,
      );
      expect(
        SmbSessionPool.isFatalError(
          const SmbException(NtStatus.networkSessionExpired, 'read'),
        ),
        isTrue,
      );
    });

    test('文件层面的错误不能连累会话', () {
      for (final status in [
        NtStatus.objectNameNotFound,
        NtStatus.objectPathNotFound,
        NtStatus.notADirectory,
        NtStatus.accessDenied,
        NtStatus.badNetworkName,
        NtStatus.endOfFile,
        NtStatus.noMoreFiles,
      ]) {
        expect(
          SmbSessionPool.isFatalError(SmbException(status, 'create')),
          isFalse,
          reason: 'status=0x${status.toRadixString(16)} 不该作废会话',
        );
      }
    });

    test('socket/超时等非协议错误一律视为连接不可信', () {
      expect(
        SmbSessionPool.isFatalError(
          const SocketException('Connection reset by peer'),
        ),
        isTrue,
      );
      expect(SmbSessionPool.isFatalError('plain string error'), isTrue);
      expect(SmbSessionPool.isFatalError(StateError('bad state')), isTrue);
    });
  });

  group('池的容量与空闲策略', () {
    test('上限与空闲超时常量在合理范围', () {
      // 播放器通常同时开 1~2 条 HTTP 连接(探测 + 拉流), 再留余量给浏览
      expect(SmbSessionPool.maxSessionsPerKey, greaterThanOrEqualTo(2));
      expect(SmbSessionPool.maxSessionsPerKey, lessThanOrEqualTo(8));
      // 要比 Samba 默认踢空闲会话的时间短, 否则会抱着一已被服务端踢掉的连接
      expect(
        SmbSessionPool.idleTimeout.inMinutes,
        lessThanOrEqualTo(5),
      );
    });

    test('未使用时 liveSessions 为 0', () {
      expect(SmbSessionPool.instance.liveSessions, 0);
    });
  });
}
