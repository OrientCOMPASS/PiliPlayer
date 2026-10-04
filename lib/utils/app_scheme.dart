// ignore_for_file: constant_identifier_names

import 'dart:async' show StreamSubscription;
import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/fav_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/smb/smb_browse.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/dynamics/widgets/vote.dart';
import 'package:PiliPlus/pages/fan/view.dart';
import 'package:PiliPlus/pages/follow/view.dart';
import 'package:PiliPlus/pages/follow_type/followed/view.dart';
import 'package:PiliPlus/pages/live/view.dart';
import 'package:PiliPlus/pages/rank/view.dart';
import 'package:PiliPlus/pages/subscription_detail/view.dart';
import 'package:PiliPlus/pages/video/reply_reply/view.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/parse_string.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/url_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class PiliScheme {
  static late AppLinks appLinks;
  static StreamSubscription? listener;
  static final uriDigitRegExp = RegExp(r'/(\d+)');
  static final _prefixRegex = RegExp(r'^\S+://');

  static void init() {
    // Register our protocol only on Windows platform
    // registerProtocolHandler('bilibili');
    appLinks = AppLinks();

    listener?.cancel();
    listener = appLinks.uriLinkStream.listen(routePush);
  }

  static int? _videoProgress(Map<String, String> queryParameters) {
    if ((queryParameters['start_progress'] ?? queryParameters['dm_progress'])
        case final p?) {
      return int.tryParse(p);
    } else if (queryParameters['t'] case final t0?) {
      if (double.tryParse(t0) case final t1?) {
        return (t1 * 1000).toInt();
      }
    }
    return null;
  }

  static const MethodChannel _sharedMediaChannel = MethodChannel(
    'piliplus/local_media',
  );

  /// 自定义深链: **piliplayer://play?url=<百分号编码的目标地址>**
  /// (可选 `&title=<编码标题>`、`&start=<秒>`)。
  ///
  /// 为什么不是 `piliplayer://smb://…`: 按 RFC 3986, 一个 URI 只有一个
  /// scheme(到第一个 ":" 为止), 第二个 "://" 落在 scheme-specific part 里
  /// 属于保留字符的非法裸用——浏览器/WebView/系统意图解析器对此行为不一
  /// (截断、拒绝或错误路由)。标准做法是把嵌套地址整体百分号编码后作为
  /// 查询参数传递(与 Android 官方 deep link 指南一致), Dart 的
  /// [Uri.queryParameters] 取值时会自动解码。
  ///
  /// 目标地址支持: smb://(含 user:pass@, 走「本地」板块同一条播放链路,
  /// 直连/代理跟随设置)、http(s)://、ftp://(直链文件)、file://(本机路径)、
  /// content://(转系统分享链路)。
  static Future<bool> _playDeepLink(Uri uri) async {
    if (uri.host != 'play') {
      SmartDialog.showToast(
        '未知深链主机: ${uri.host}。格式: piliplayer://play?url=<百分号编码的地址>',
      );
      return false;
    }
    final target = uri.queryParameters['url'];
    if (target == null || target.isEmpty) {
      SmartDialog.showToast(
        '缺少 url 参数。格式: piliplayer://play?url=<百分号编码的地址>',
      );
      return false;
    }
    final title = uri.queryParameters['title'];
    final startSec = double.tryParse(uri.queryParameters['start'] ?? '');
    final progressMs = startSec != null ? (startSec * 1000).round() : null;
    final Uri targetUri;
    try {
      final parsed = Uri.parse(target);
      if (parsed.scheme.isEmpty) {
        throw const FormatException('no scheme');
      }
      targetUri = parsed;
    } catch (_) {
      SmartDialog.showToast('url 参数不是合法地址: $target');
      return false;
    }
    switch (targetUri.scheme.toLowerCase()) {
      case 'content':
        return _openSharedMedia(targetUri);
      case 'file':
        final path = targetUri.path;
        if (path.isEmpty) {
          SmartDialog.showToast('file 地址缺少路径');
          return false;
        }
        return _playDeepLinkItem(
          LocalMediaItem(
            name: title ?? path.substring(path.lastIndexOf('/') + 1),
            uri: path,
            source: const LocalMediaSource(
              type: LocalMediaSourceType.device,
              name: '深链',
              url: '',
            ),
          ),
          progressMs: progressMs,
        );
      case 'smb':
        final ep = SmbBrowse.parseEndpoint(target);
        if (ep == null) {
          SmartDialog.showToast('smb 地址格式不正确: $target');
          return false;
        }
        // userinfo: [domain;][user[:password]](百分号编码, Uri 已按最后一个
        // '@' 切分; 解码失败按原样处理)
        String? user;
        String? password;
        String? domain;
        var info = targetUri.userInfo;
        if (info.isNotEmpty) {
          try {
            info = Uri.decodeComponent(info);
          } catch (_) {}
          var cred = info;
          final semi = info.indexOf(';');
          if (semi >= 0) {
            domain = info.substring(0, semi);
            cred = info.substring(semi + 1);
          }
          final colon = cred.indexOf(':');
          if (colon >= 0) {
            user = cred.substring(0, colon);
            password = cred.substring(colon + 1);
          } else if (cred.isNotEmpty) {
            user = cred;
          }
        }
        final source = LocalMediaSource(
          type: LocalMediaSourceType.smb,
          name: ep.host,
          url: SmbBrowse.uri(
            host: ep.host,
            port: ep.port,
            share: ep.share,
            remotePath: ep.path,
          ),
          username: user,
          password: (password == null || password.isEmpty) ? null : password,
          domain: (domain == null || domain.isEmpty) ? null : domain,
        );
        final segs = ep.path
            .split(RegExp(r'[\\/]+'))
            .where((e) => e.isNotEmpty)
            .toList();
        final item = LocalMediaItem(
          name: title ?? (segs.isEmpty ? ep.share : segs.last),
          uri: source.url,
          source: source,
          remotePath: ep.path,
        );
        // 与「本地」板块完全同一条解析链: 默认 libmpv 内置 smb:// 直连,
        // 设置关闭时回退回环代理
        final playUrl = await LocalMediaService.resolvePlayUrl(item);
        return _playDeepLinkItem(item, playUrl: playUrl, progressMs: progressMs);
      case 'http' || 'https' || 'ftp':
        final segs = targetUri.pathSegments.where((e) => e.isNotEmpty).toList();
        final source = LocalMediaSource(
          type: targetUri.scheme.toLowerCase() == 'ftp'
              ? LocalMediaSourceType.ftp
              : LocalMediaSourceType.http,
          name: title ?? (segs.isEmpty ? '深链媒体' : segs.last),
          url: target,
        );
        return _playDeepLinkItem(
          LocalMediaItem(name: source.name, uri: target, source: source),
          progressMs: progressMs,
        );
      default:
        SmartDialog.showToast('深链暂不支持 ${targetUri.scheme}:// 协议');
        return false;
    }
  }

  /// 深链播放: 走与「本地」板块一致的播放页链路(本地媒体模式)
  static Future<bool> _playDeepLinkItem(
    LocalMediaItem item, {
    String? playUrl,
    int? progressMs,
  }) async {
    try {
      await PageUtils.toVideoPage(
        aid: 0,
        bvid: '',
        cid: item.cid,
        title: item.name,
        progress: progressMs,
        extraArguments: {
          'sourceType': SourceType.localMedia,
          'localMedia': item,
          'localPlaylist': [item],
          'localIndex': 0,
          'localPlayUrl': playUrl ?? item.uri,
        },
      );
      return true;
    } catch (err) {
      SmartDialog.showToast('无法播放: $err');
      return false;
    }
  }

  /// 打开系统分享/「用其他应用打开」的视频。
  ///
  /// content:// 无法被 mpv 直接读取: Kotlin 侧(MainActivity)经
  /// ContentResolver 导出文件描述符, 以 `fd://N` 交给定制 libmpv 的
  /// ffmpeg fd 协议; 播放页退出(await 返回)后关闭 fd。走与「本地」板块
  /// 完全相同的播放页链路(本地媒体模式: 无 B 站接口/弹幕/上报)。
  static Future<bool> _openSharedMedia(Uri uri) async {
    if (!Platform.isAndroid) {
      return false;
    }
    int? fd;
    try {
      final res = await _sharedMediaChannel.invokeMethod<Map<dynamic, dynamic>?>(
        'resolveContentMedia',
        {'uri': uri.toString()},
      );
      if (res == null) {
        return false;
      }
      final name =
          res['name'] is String && (res['name'] as String).isNotEmpty
          ? res['name'] as String
          : '分享的视频';
      final String playUrl;
      if (res['fd'] is int) {
        fd = res['fd'] as int;
        playUrl = 'fd://$fd';
      } else if (res['path'] is String && (res['path'] as String).isNotEmpty) {
        playUrl = res['path'] as String;
      } else {
        return false;
      }
      final item = LocalMediaItem(
        name: name,
        uri: playUrl,
        source: const LocalMediaSource(
          type: LocalMediaSourceType.device,
          name: '系统分享',
          url: '',
        ),
      );
      try {
        await PageUtils.toVideoPage(
          aid: 0,
          bvid: '',
          cid: item.cid,
          title: name,
          extraArguments: {
            'sourceType': SourceType.localMedia,
            'localMedia': item,
            'localPlaylist': [item],
            'localIndex': 0,
            'localPlayUrl': playUrl,
          },
        );
      } finally {
        // 播放页退出即释放 fd(Kotlin 侧另有数量兜底)
        if (fd != null) {
          try {
            await _sharedMediaChannel.invokeMethod('closeFd', {'fd': fd});
          } catch (_) {}
        }
      }
      return true;
    } catch (err) {
      SmartDialog.showToast('无法打开分享的视频: $err');
      return false;
    }
  }

  static Future<bool> routePushFromUrl(
    String url, {
    bool selfHandle = false,
    bool off = false,
    Map? parameters,
    int? businessId,
    int? oid,
  }) {
    try {
      if (url.startsWith('//')) {
        url = 'https:$url';
      } else if (!_prefixRegex.hasMatch(url)) {
        url = 'https://$url';
      }
      return routePush(
        Uri.parse(url),
        selfHandle: selfHandle,
        off: off,
        parameters: parameters,
        businessId: businessId,
        oid: oid,
      );
    } catch (_) {
      return Future.syncValue(false);
    }
  }

  /// 路由跳转
  static Future<bool> routePush(
    Uri uri, {
    bool selfHandle = false,
    bool off = false,
    Map? parameters,
    int? businessId,
    int? oid,
  }) async {
    // if (kDebugMode) debugPrint('onAppLink: $uri');

    final String scheme = uri.scheme;
    final String host = uri.host;
    final String path = uri.path;

    switch (scheme) {
      case 'bilibili':
        switch (host) {
          case 'root':
            Get.key.currentState!.popUntil(
              (Route<dynamic> route) => route.isFirst,
            );
            return true;
          case 'pgc':
            // bilibili://pgc/season/ep/123456?h5_awaken_params=random
            String? id = uriDigitRegExp.firstMatch(path)?.group(1);
            if (id != null) {
              bool isEp = path.contains('/ep/');
              PageUtils.viewPgc(
                seasonId: isEp ? null : id,
                epId: isEp ? id : null,
                progress: _videoProgress(uri.queryParameters),
              );
              return true;
            }
            return false;
          case 'space':
            // bilibili://space/12345678?frommodule=XX&h5awaken=random
            String? mid = uriDigitRegExp.firstMatch(path)?.group(1);
            if (mid != null) {
              if (path.startsWith('/realname')) {
                RequestUtils.showUserRealName(mid);
                return true;
              }
              PageUtils.toDupNamed('/member?mid=$mid', off: off);
              return true;
            }
            return false;
          case 'video':
            // bilibili://video/12345678?dm_progress=123000&cid=12345678&dmid=12345678
            // bilibili://video/{aid}/?comment_root_id=***&comment_secondary_id=***
            final queryParameters = uri.queryParameters;
            if (queryParameters['comment_root_id'] != null) {
              // to video reply
              String? oid = uriDigitRegExp.firstMatch(path)?.group(1);
              int? rpid = int.tryParse(queryParameters['comment_root_id']!);
              if (oid != null && rpid != null) {
                VideoReplyReplyPanel.toReply(
                  oid: int.parse(oid),
                  rootId: rpid,
                  rpIdStr: queryParameters['comment_secondary_id'],
                  type: 1,
                  uri: uri.replace(query: ''),
                );
                return true;
              }
              return false;
            }

            // to video
            // bilibili://video/12345678?page=0&h5awaken=random
            String? aid = uriDigitRegExp.firstMatch(path)?.group(1);
            String? bvid = IdUtils.bvRegex.firstMatch(path)?.group(0);
            if (aid != null || bvid != null) {
              final cid = queryParameters['cid'];
              if (cid != null) {
                bvid ??= IdUtils.av2bv(int.parse(aid!));
                PageUtils.toVideoPage(
                  bvid: bvid,
                  cid: int.parse(cid),
                  progress: _videoProgress(queryParameters),
                  off: off,
                );
              } else {
                videoPush(
                  aid != null ? int.parse(aid) : null,
                  bvid,
                  off: off,
                  progress: _videoProgress(queryParameters),
                );
              }
              return true;
            }
            return false;
          case 'live':
            // bilibili://live/12345678?extra_jump_from=1&from=1&is_room_feed=1&h5awaken=random
            String? roomId = uriDigitRegExp.firstMatch(path)?.group(1);
            if (roomId != null) {
              PageUtils.toLiveRoom(int.parse(roomId), off: off);
              return true;
            }
            return false;
          case 'bangumi':
            // bilibili://bangumi/season/12345678?h5_awaken_params=random
            if (path.startsWith('/season')) {
              String? seasonId = uriDigitRegExp.firstMatch(path)?.group(1);
              if (seasonId != null) {
                PageUtils.viewPgc(seasonId: seasonId, epId: null);
                return true;
              }
            }
            return false;
          case 'opus':
            bool hasMatch = _onPushDynDetail(uri, off);
            return hasMatch;
          case 'search':
            final keyword = uri.queryParameters['keyword'];
            if (keyword != null) {
              PageUtils.toDupNamed(
                '/searchResult',
                parameters: {'keyword': keyword},
                off: off,
              );
              return true;
            }
            Get.toNamed('/search');
            return true;
          case 'article':
            // bilibili://article/40679479?jump_opus=1&jump_opus_type=1&opus_type=article&h5awaken=random
            String? id = uriDigitRegExp.firstMatch(path)?.group(1);
            if (id != null) {
              PageUtils.toDupNamed(
                '/articlePage',
                parameters: {
                  'id': id,
                  'type': 'read',
                },
                off: off,
              );
              return true;
            }
            return false;
          case 'comment':
            if (path.startsWith("/detail/") || path.startsWith("/msg_fold/")) {
              // bilibili://comment/detail/17/832703053858603029/238686570016/?subType=0&anchor=238686628816&showEnter=1&extraIntentId=0&scene=1&enterName=%E6%9F%A5%E7%9C%8B%E5%8A%A8%E6%80%81%E8%AF%A6%E6%83%85&enterUri=bilibili://following/detail/832703053858603029
              // bilibili://comment/msg_fold/1/22222/33333/11111/?enterUri=bilibili://video/22222 //(aid)
              // bilibili://comment/msg_fold/11/22222/33333/11111/?enterUri=bilibili://following/detail/44444 (dynId)
              final pathSegments = uri.pathSegments;
              final queryParameters = uri.queryParameters;
              final type = int.parse(pathSegments[1]); // business_id
              final oid = int.parse(pathSegments[2]); // subject_id
              final rootId = int.parse(pathSegments[3]); // root_id // target_id
              // int subType = int.parse(queryParameters['subType'] ?? '0');
              // int extraIntentId =
              // int.parse(queryParameters['extraIntentId'] ?? '0');
              final enterUri = queryParameters['enterUri'];
              VideoReplyReplyPanel.toReply(
                oid: oid,
                rootId: rootId,
                rpIdStr:
                    queryParameters['anchor'] ?? pathSegments[3], // source_id
                type: type,
                uri: enterUri != null
                    ? Uri.parse(enterUri)
                    : const [11, 16, 17].contains(type)
                    ? Uri(
                        scheme: 'bilibili',
                        host: 'following',
                        path: 'detail/$oid',
                      )
                    : null,
              );
              return true;
            }
            return false;
          case 'following':
            // businessId == 17 => dynId == oid
            // bilibili://following/detail/832703053858603029 (dynId)
            // bilibili://following/detail/12345678?comment_root_id=654321\u0026comment_on=1
            String? cvid = RegExp(
              r'^/detail/cv(\d+)',
              caseSensitive: false,
            ).matchAsPrefix(path)?.group(1);
            if (cvid != null) {
              PageUtils.toDupNamed(
                '/articlePage',
                parameters: {
                  'id': cvid,
                  'type': 'read',
                },
                off: off,
              );
              return true;
            }
            if ((oid != null || businessId == 17) &&
                path.startsWith("/detail/")) {
              final queryParameters = uri.queryParameters;
              final commentRootId = queryParameters['comment_root_id'];
              if (commentRootId != null) {
                String? dynId = uriDigitRegExp.firstMatch(path)?.group(1);
                int? rpid = int.tryParse(commentRootId);
                if (dynId != null && rpid != null) {
                  VideoReplyReplyPanel.toReply(
                    oid: oid ?? int.parse(dynId),
                    rootId: rpid,
                    rpIdStr: queryParameters['comment_secondary_id'],
                    type: businessId ?? 17,
                    uri: uri.replace(query: ''),
                  );
                  return true;
                }
              }
            }
            return _onPushDynDetail(uri, off);
          case 'album':
            String? rid = uriDigitRegExp.firstMatch(path)?.group(1);
            if (rid != null) {
              PageUtils.pushDynFromId(rid: rid, off: off);
              return true;
            }
            return false;
          case 'medialist':
            String? mediaId = uriDigitRegExp.firstMatch(path)?.group(1);
            if (mediaId != null) {
              PageUtils.toDupNamed(
                '/favDetail',
                parameters: {
                  'mediaId': mediaId,
                  'heroTag': Utils.makeHeroTag(mediaId),
                },
                off: off,
              );
              return true;
            }
            return false;
          // bilibili://browser/?url=https%3A%2F%2Fwww.bilibili.com%2F
          case 'browser':
            if (selfHandle) return false;
            final url = uri.queryParameters['url'];
            if (url != null) {
              _toWebview(url, off, parameters);
              return true;
            }
            return false;
          case bilibili_m:
            // bilibili://m.bilibili.com/topic-detail?topic_id=1028161&frommodule=H5&h5awaken=xxx
            final id = uri.queryParameters['topic_id'];
            if (id != null) {
              PageUtils.toDupNamed(
                '/dynTopic',
                parameters: {'id': id},
                off: off,
              );
              return true;
            }
            return false;
          case 'cheese':
            // bilibili://cheese/season/123456
            String? seasonId = uriDigitRegExp.firstMatch(path)?.group(1);
            if (seasonId != null) {
              PageUtils.viewPugv(seasonId: seasonId);
              return true;
            }
            return false;
          case 'history':
            Get.toNamed('/history');
            return true;
          case 'main':
            if (path.startsWith('/favorite')) {
              final tab = uri.queryParameters['tab'];
              int index = 0;
              if (tab != null) {
                try {
                  index = FavTabType.values.byName(tab).index;
                } catch (e) {
                  if (kDebugMode) debugPrint('favorite jump: $e');
                }
              }
              Get.toNamed('/fav', arguments: index);
              return true;
            }
            return false;
          case 'livearea':
            Get.to(
              SimpleScaffold(
                appBar: AppBar(title: const Text('直播')),
                body: const ViewSafeArea(child: LivePage()),
              ),
            );
            return true;
          case 'rank':
            Get.to(
              SimpleScaffold(
                appBar: AppBar(title: const Text('排行榜')),
                body: const ViewSafeArea(child: RankPage()),
              ),
            );
            return true;
          case 'login':
            Get.toNamed('/loginPage');
            return true;
          case 'music':
            if (path.startsWith('/playlist/')) {
              final mediaId = uriDigitRegExp.firstMatch(path)?.group(1);
              if (mediaId != null) {
                Get.toNamed(
                  '/favDetail',
                  parameters: {
                    'mediaId': mediaId,
                    'heroTag': Utils.makeHeroTag(mediaId),
                  },
                );
                return true;
              }
            }
            return false;
          case 'download':
            Get.toNamed('/download');
            return true;
          default:
            if (!selfHandle) {
              // if (kDebugMode) debugPrint('$uri');
              SmartDialog.showToast('未知路径:$uri，请截图反馈给开发者');
            }
            return false;
        }
      case 'http' || 'https':
        return _fullPathPush(
          uri,
          selfHandle: selfHandle,
          off: off,
          parameters: parameters,
        );
      // 系统「用其他应用打开/分享」进来的视频文件(第十六轮: 注册为系统
      // 视频播放器): content:// 经 ContentResolver 导出 fd 后以 fd://N
      // 交给定制 libmpv(fd 协议)播放, file:// 直接按路径播。
      case 'content' || 'file':
        return _openSharedMedia(uri);
      // 自定义深链(第十七轮): piliplayer://play?url=<百分号编码的地址>
      case 'piliplayer':
        return _playDeepLink(uri);
      default:
        final aid = IdUtils.avRegexExact.matchAsPrefix(path)?.group(1);
        final bvid = IdUtils.bvRegexExact.matchAsPrefix(path)?.group(0);
        if (aid != null || bvid != null) {
          videoPush(
            aid != null ? int.parse(aid) : null,
            bvid,
            off: off,
          );
          return true;
        }
        if (!selfHandle) {
          // if (kDebugMode) debugPrint('$uri');
          SmartDialog.showToast('未知路径:$uri，请截图反馈给开发者');
        }
        return false;
    }
  }

  static const b23_tv = 'b23.tv';
  static const bilibili = 'bilibili.com';
  static const bilibili_m = 'm.$bilibili';
  static const bilibili_t = 't.$bilibili';
  static const bilibili_live = 'live.$bilibili';
  static const bilibili_space = 'space.$bilibili';
  static const bilibili_search = 'search.$bilibili';
  static const bilibili_music = 'music.$bilibili';

  static Future<bool> _fullPathPush(
    Uri uri, {
    bool selfHandle = false,
    bool off = false,
    Map? parameters,
  }) async {
    // https://m.bilibili.com/bangumi/play/ss39708
    // https | m.bilibili.com | /bangumi/play/ss39708

    String host = uri.host;

    void launchURL() {
      if (!selfHandle) {
        _toWebview(uri.toString(), off, parameters);
      }
    }

    if (!host.contains(bilibili) && !host.contains(b23_tv)) {
      launchURL();
      return false;
    }

    // redirect
    if (host.contains(b23_tv)) {
      String? redirectUrl = await UrlUtils.parseRedirectUrl(uri.toString());
      if (redirectUrl != null) {
        uri = Uri.parse(redirectUrl);
        host = uri.host;
      }
    }

    if (!host.contains(bilibili)) {
      launchURL();
      return false;
    }

    final path = uri.path;
    late final queryParameters = uri.queryParameters;

    if (host.contains(bilibili_t)) {
      if (_onPushDynDetail(uri, off)) {
        return true;
      } else if (path.startsWith('/vote')) {
        // t.bilibili.com/vote/h5/index?vote_id={{vote_id}}#/result
        if (queryParameters['vote_id'] case final voteIdStr?) {
          final voteId = int.tryParse(voteIdStr);
          if (voteId != null) {
            if (Get.context != null) {
              showVoteDialog(Get.context!, voteId);
            }
            return true;
          }
        }
      }
      launchURL();
      return false;
    } else if (host.contains(bilibili_live)) {
      String? roomId = uriDigitRegExp.firstMatch(path)?.group(1);
      if (roomId != null) {
        PageUtils.toLiveRoom(int.parse(roomId), off: off);
        return true;
      }
      launchURL();
      return false;
    } else if (host.contains(bilibili_space)) {
      void toType({
        required String mid,
        required String? type,
      }) {
        switch (type) {
          case 'follow':
            FollowPage.toFollowPage(mid: mid);
            break;
          case 'fans':
            FansPage.toFansPage(mid: mid);
            break;
          case 'followed':
            FollowedPage.toFollowedPage(mid: mid);
            break;
          default:
            PageUtils.toDupNamed('/member?mid=$mid', off: off);
        }
      }

      // space.bilibili.com/h5/follow?mid={{mid}}&type={{type}}
      if (path.startsWith('/h5/follow')) {
        final mid = queryParameters['mid'];
        final type = queryParameters['type'];
        if (mid != null) {
          toType(mid: mid, type: type);
          return true;
        }
      }

      // space.bilibili.com/{{uid}}/lists/{{season_id}}
      // space.bilibili.com/{{uid}}/lists?sid={{season_id}}
      // space.bilibili.com/{{uid}}/channel/collectiondetail?sid={{season_id}}
      final sid =
          queryParameters['sid'] ??
          RegExp(r'lists/(\d+)').firstMatch(path)?.group(1);
      if (sid != null) {
        SubDetailPage.toSubDetailPage(int.parse(sid));
        return true;
      }

      // space.bilibili.com/{{mid}}/relation/{{type}}
      final mid = uriDigitRegExp.firstMatch(path)?.group(1);
      final type = RegExp(r'relation/([a-z]+)').firstMatch(path)?.group(1);
      if (mid != null) {
        toType(mid: mid, type: type);
        return true;
      }
      launchURL();
      return false;
    } else if (host.contains(bilibili_search)) {
      String? keyword = uri.queryParameters['keyword'];
      if (keyword != null) {
        PageUtils.toDupNamed(
          '/searchResult',
          parameters: {'keyword': keyword},
          off: off,
        );
        return true;
      }
      launchURL();
      return false;
    } else if (host.contains(bilibili_music)) {
      // music.bilibili.com/pc/music-detail?music_id=MA***
      // music.bilibili.com/h5-music-detail?music_id=MA***
      if (path.contains('music-detail')) {
        final musicId = uri.queryParameters['music_id'];
        if (musicId != null && musicId.startsWith('MA')) {
          PageUtils.toDupNamed(
            '/musicDetail',
            parameters: {'musicId': musicId},
          );
          return true;
        }
      }
      launchURL();
      return false;
    }

    final pathSegments = uri.pathSegments;
    if (pathSegments.isEmpty) {
      launchURL();
      return false;
    }
    final first = pathSegments.first;
    final String? area = const ['mobile', 'h5', 'v'].contains(first)
        ? pathSegments.elementAtOrNull(1)
        : first;
    // if (kDebugMode) debugPrint('area: $area');
    switch (area) {
      case 'note' || 'note-app':
        String? id = uri.queryParameters['cvid'];
        if (id != null) {
          PageUtils.toDupNamed(
            '/articlePage',
            parameters: {
              'id': id,
              'type': 'read',
            },
            off: off,
          );
          return true;
        }
        launchURL();
        return false;
      case 'dynamic' || 'opus':
        bool hasMatch = _onPushDynDetail(uri, off);
        if (!hasMatch) {
          launchURL();
        }
        return hasMatch;
      case 'playlist':
        // http://m.bilibili.com/playlist/pl12345678?bvid=BVxxxxxxxx&page_type=4
        String? mediaId = RegExp(
          r'/pl(\d+)',
          caseSensitive: false,
        ).firstMatch(path)?.group(1);
        String? bvid =
            uri.queryParameters['bvid'] ??
            IdUtils.bvRegex.firstMatch(path)?.group(0);
        if (bvid != null) {
          if (mediaId != null) {
            final res = await SearchHttp.ab2cWithDimension(bvid: bvid);
            final cid = res?.cid;
            if (cid != null) {
              PageUtils.toVideoPage(
                bvid: bvid,
                cid: cid,
                dimension: res!.dimension,
                title: res.title,
                extraArguments: {
                  'sourceType': SourceType.playlist,
                  'favTitle': '播放列表',
                  'mediaId': mediaId,
                  'desc': true,
                  'isContinuePlaying': true,
                },
              );
            }
          } else {
            videoPush(null, bvid, off: off);
          }
          return true;
        }
        launchURL();
        return false;
      case 'bangumi':
        // www.bilibili.com/bangumi/play/ep{eid}?start_progress={offset}&thumb_up_dm_id={dmid}
        // if (kDebugMode) debugPrint('番剧');
        bool hasMatch = PageUtils.viewPgcFromUri(
          path,
          progress: _videoProgress(uri.queryParameters),
        );
        if (hasMatch) {
          return true;
        }
        launchURL();
        return false;
      case 'video':
        // if (kDebugMode) debugPrint('投稿');
        final res = IdUtils.matchAvorBv(input: path);
        if (res.isNotEmpty) {
          final queryParameters = uri.queryParameters;
          final rootIdStr = queryParameters['comment_root_id'];
          final part = queryParameters['p'];
          if (rootIdStr != null) {
            VideoReplyReplyPanel.toReply(
              oid: res.av ?? IdUtils.bv2av(res.bv!),
              rootId: int.parse(rootIdStr),
              rpIdStr: queryParameters['comment_secondary_id'],
              type: 1,
              uri: uri.replace(query: part != null ? 'p=$part' : ''),
            );
            return true;
          }
          videoPush(
            res.av,
            res.bv,
            off: off,
            progress: _videoProgress(queryParameters),
            part: part,
          );
          return true;
        }
        launchURL();
        return false;
      case 'read':
        if (path.contains('readlist')) {
          String? id = RegExp(
            r'/rl(\d+)',
            caseSensitive: false,
          ).firstMatch(path)?.group(1);
          if (id != null) {
            PageUtils.toDupNamed(
              '/articleList',
              parameters: {'id': id},
              off: off,
            );
            return true;
          }
          launchURL();
          return false;
        }
        // if (kDebugMode) debugPrint('专栏');
        String? id = RegExp(
          r'cv(\d+)',
          caseSensitive: false,
        ).firstMatch(path)?.group(1);
        if (id != null) {
          PageUtils.toDupNamed(
            '/articlePage',
            parameters: {
              'id': id,
              'type': 'read',
            },
            off: off,
          );
          return true;
        }
        launchURL();
        return false;
      case 'space':
        // if (kDebugMode) debugPrint('个人空间');
        String? mid = uriDigitRegExp.firstMatch(path)?.group(1);
        if (mid != null) {
          PageUtils.toDupNamed(
            '/member?mid=$mid',
            off: off,
          );
          return true;
        }
        launchURL();
        return false;
      case 'medialist':
        String? mediaId = RegExp(r'/ml(\d+)').firstMatch(path)?.group(1);
        if (mediaId != null) {
          PageUtils.toDupNamed(
            '/favDetail',
            parameters: {
              'mediaId': mediaId,
              'heroTag': Utils.makeHeroTag(mediaId),
            },
            off: off,
          );
          return true;
        }
        launchURL();
        return false;
      case 'topic' || 'topic-detail':
        String? id = uri.queryParameters['topic_id'];
        if (id != null) {
          PageUtils.toDupNamed(
            '/dynTopic',
            parameters: {'id': id},
            off: off,
          );
          return true;
        }
        launchURL();
        return false;
      case 'comment':
        // https://www.bilibili.com/h5/comment/sub?oid=123456&pageType=1&root=87654321
        final queryParameters = uri.queryParameters;
        final oid = queryParameters['oid'];
        final root = queryParameters['root'];
        final pageType = queryParameters['pageType'];
        if (oid != null && root != null && pageType != null) {
          VideoReplyReplyPanel.toReply(
            oid: int.parse(oid),
            rootId: int.parse(root),
            rpIdStr: queryParameters['comment_secondary_id'],
            type: int.parse(pageType),
            uri: Uri(scheme: 'bilibili', host: 'video', path: oid),
          );
          return true;
        }
        launchURL();
        return false;
      case 'match' || 'game':
        if (path.contains('match/data/detail') ||
            path.contains('match/singledata')) {
          String? cid = uriDigitRegExp.firstMatch(path)?.group(1);
          if (cid != null) {
            PageUtils.toDupNamed(
              '/matchInfo',
              parameters: {'cid': cid},
              off: off,
            );
            return true;
          }
        }
        launchURL();
        return false;
      case 'cheese':
        // https://www.bilibili.com/cheese/play/ss123456
        bool hasMatch = PageUtils.viewPgcFromUri(path, isPgc: false);
        if (hasMatch) {
          return true;
        }
        launchURL();
        return false;
      case 'audio':
        // https://www.bilibili.com/audio/au123456
        String? oid = RegExp(
          r'/au(\d+)',
          caseSensitive: false,
        ).firstMatch(path)?.group(1);
        if (oid != null) {
          AudioPage.toAudioPage(
            itemType: 3,
            oid: int.parse(oid),
            from: PlaylistSource.AUDIO_CARD,
          );
          return true;
        }
        launchURL();
        return false;
      case 'bubble':
        // https://www.bilibili.com/bubble/home/1
        final id = uriDigitRegExp.firstMatch(path)?.group(1);
        if (id != null) {
          Get.toNamed('/bubble', arguments: {'id': id});
          return true;
        }
        launchURL();
        return false;
      default:
        final res = IdUtils.matchAvorBv(input: area?.split('?').first);
        if (res.isNotEmpty) {
          videoPush(
            res.av,
            res.bv,
            off: off,
          );
          return true;
        }
        launchURL();
        return false;
    }
  }

  static bool _onPushDynDetail(Uri uri, bool off) {
    String? id = uriDigitRegExp.firstMatch(uri.path)?.group(1);
    bool isRid = uri.queryParameters['type'] == '2';
    if (id != null) {
      PageUtils.pushDynFromId(
        id: isRid ? null : id,
        rid: isRid ? id : null,
        off: off,
      );
      return true;
    }
    return false;
  }

  static void _toWebview(
    String url,
    bool off,
    Map? parameters,
  ) {
    PageUtils.toDupNamed(
      '/webview',
      parameters: {
        'url': url,
        ...?parameters,
      },
      off: off,
    );
  }

  // 投稿跳转
  static Future<void> videoPush(
    int? aid,
    String? bvid, {
    bool showDialog = true,
    bool off = false,
    int? progress, // milliseconds
    String? part,
  }) async {
    try {
      aid ??= IdUtils.bv2av(bvid!);
      bvid ??= IdUtils.av2bv(aid);
      if (showDialog) {
        SmartDialog.showLoading<dynamic>(msg: '获取中...');
      }
      final res = await SearchHttp.ab2cWithDimension(
        bvid: bvid,
        aid: aid,
        part: parseIntOrNull(part),
      );
      final cid = res?.cid;
      if (showDialog) {
        SmartDialog.dismiss();
      }
      if (cid != null) {
        PageUtils.toVideoPage(
          aid: aid,
          bvid: bvid,
          cid: cid,
          progress: progress,
          off: off,
          dimension: res!.dimension,
          title: res.title,
        );
      }
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('video获取失败: $e');
    }
  }
}
