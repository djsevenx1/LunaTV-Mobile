// v2.3.12: 弹幕源接口.
//   1:1 移植自 Selene-TV `defpackage.qh0` 3 方法接口:
//     - a(int, int, String)        → fetchByRange (取 [start, end] 时间段内的弹幕)
//     - b(String)                 → getEpisodes   (按 mediaId 拿剧集列表)
//     - c(String)                 → searchMedia   (按标题搜媒体)
//
// 不同 provider 走不同实现, 但对外 API 一致. UI 层只跟 [DanmakuProvider] 打交道.

import '../models/danmaku_models.dart';

abstract class DanmakuProvider {
  /// provider 标识, 用于日志 / 路由, e.g. "bilibili"
  String get name;

  /// 取 [startSec]..[endSec] 之间的弹幕, [oid] 是 provider 内的剧集 id
  /// (B站 = cid, 爱奇艺 = tv id, ...).
  ///
  /// 返空 list = 该 provider 拿不到, 上层应该 fallback 到下一个 provider.
  /// 抛异常 = provider 整个挂了, 上层应该 catch + 跳过本 provider.
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  });

  /// 按 [mediaId] 拿剧集列表.
  ///
  /// [mediaId] 形式由各 provider 决定:
  ///   - B站: `ss12345` (剧集 ss) 或 `BV1xxxxxx` (单视频 bv)
  ///   - 腾讯/优酷/爱奇艺: provider 内部 id
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId);

  /// 按 [title] 搜媒体, 返回最多 N 个匹配结果.
  ///
  /// 用户在播放页输 "想看的剧名" 时, 这个方法返回候选.
  Future<List<DanmakuMedia>> searchMedia(String title);
}
