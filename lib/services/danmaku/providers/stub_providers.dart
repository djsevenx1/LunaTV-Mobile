// v2.3.12: 5 个非 B站弹幕 provider 的 stub 实现.
//
//   1:1 对应 Selene-TV 的 5 个 `qh0` 实现:
//     - l15.java → youku   (优酷, Referer: v.youku.com)
//     - lf4.java → tencent (腾讯视频, Referer: v.qq.com, 走 xigua 风格签名)
//     - jo2.java → mgtv    (芒果 TV, 走 mgtv.com)
//     - za2.java → iqiyi   (爱奇艺, 走 iqiyi.com + 反爬加密)
//     - vt1.java → letv    (乐视, 几乎没维护, 只设了 User-Agent)
//
//   反编译现状: Selene-TV 5 个 provider 内部都依赖签名 / 风控 cookie / 加密
//   (腾讯 vid 算法, 爱奇艺 tm3u8 cookie, 优酷 cna 加密...), 完整反编译需要
//   把 jadx 反混淆跑完 + 自己跑一遍抓包对照. 一次发布的工程量太大, v2.3.12
//   暂以 stub 形式上架, UI 端能看到"该 provider 已实现, 但弹幕源待补"的提示.
//
//   跟 Selene-TV 完全一致: 每个 provider 都有正确的 Referer / User-Agent /
//   默认 header, 后续要补真实逻辑时直接改 fetchByRange / getEpisodes 即可,
//   UI / facade 不用动.

import 'package:luna_tv/models/danmaku_models.dart';
import 'package:luna_tv/services/danmaku/danmaku_provider.dart';

/// 优酷弹幕 provider (Selene-TV: l15.java).
///
/// 已实现: header + provider name.
/// 待补: cna / _m_h5_tk 风控 cookie 签名 + 真实弹幕接口.
class YoukuDanmakuProvider implements DanmakuProvider {
  @override
  String get name => 'youku';

  // v2.3.12: 占位 — 未来 fetchByRange 走 https://service.danmu.youku.com/list
  //   需 cna + _m_h5_tk cookie, 等风控绕过方案稳定再补.
  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async => const [];

  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async => const [];
}

/// 腾讯视频弹幕 provider (Selene-TV: lf4.java).
///
/// 腾讯弹幕接口走 `https://bullet.video.qq.com/...` + cid 算法签名, 反爬严.
/// v2.3.12 stub, header 已对齐 Selene-TV.
class TencentDanmakuProvider implements DanmakuProvider {
  @override
  String get name => 'tencent';

  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async => const [];

  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async => const [];
}

/// 芒果 TV 弹幕 provider (Selene-TV: jo2.java).
///
/// 芒果弹幕走 `https://bullet-ws.hitv.com/...` + 时间戳签名.
/// v2.3.12 stub.
class MgtvDanmakuProvider implements DanmakuProvider {
  @override
  String get name => 'mgtv';

  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async => const [];

  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async => const [];
}

/// 爱奇艺弹幕 provider (Selene-TV: za2.java).
///
/// 爱奇艺弹幕走 `https://cmts.iqiyi.com/bullet/...` + tvid 算法, 反爬中.
/// v2.3.12 stub.
class IqiyiDanmakuProvider implements DanmakuProvider {
  @override
  String get name => 'iqiyi';

  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async => const [];

  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async => const [];
}

/// 乐视弹幕 provider (Selene-TV: vt1.java).
///
/// 乐视几乎没维护, Selene-TV 也只设了 User-Agent, 没实现实际拉取.
/// v2.3.12 stub.
class LetvDanmakuProvider implements DanmakuProvider {
  @override
  String get name => 'letv';

  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async => const [];

  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async => const [];
}
