// lib/danmaku/sources/danmaku_source.dart
// 6 源统一接口 — 对应 SeleneTV 反编译的 qh0 接口
// (c=searchMedia, b=getEpisodes, a=getDanmaku)
//
// 抽象类叫 BaseDanmakuSource, 避免和 models/danmaku_media.dart 里的
// enum DanmakuSource 重名. 子类直接 import enum 不需要 hide/show.

import 'package:dio/dio.dart';
import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';

abstract class BaseDanmakuSource {
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
