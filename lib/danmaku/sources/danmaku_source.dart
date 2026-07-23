// lib/danmaku/sources/danmaku_source.dart
// 6 源统一接口 — 对应 SeleneTV 反编译的 qh0 接口
// (c=searchMedia, b=getEpisodes, a=getDanmaku)

import 'package:dio/dio.dart';
import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';

abstract class DanmakuSource {
  DanmakuSource get sourceEnum;

  /// 搜索剧集
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio});

  /// 拿分集列表
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId, {Dio? dio});

  /// 拉弹幕
  /// [startSec]/[endSec] 0 = 全部
  /// [episodeId] 对应 DanmakuEpisode.episodeId
  Future<List<DanmakuComment>> getDanmaku(
    String episodeId, {
    int startSec = 0,
    int endSec = 0,
    Dio? dio,
  });
}
