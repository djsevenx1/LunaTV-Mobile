// lib/danmaku/sources/le_danmaku.dart
// 乐视弹幕源 — SeleneTV za2.java 反编译移植
//
// 协议 (基于 R8 反编译 za2.java + 公开乐视 H5 协议):
//   - 搜索:  https://so.le.com/s?wd={kw}  (HTML, 解析 video 卡片)
//   - 分集:  https://api.le.com/album/episodeList?albumId={aid}
//   - 弹幕:  https://hd-my.le.com/danmu/list?vid={vid}&start={s}&end={e}
//            JSON 格式
//   - 视频详情: https://api.le.com/video/detail?videoId={vid}
//
// SeleneTV za2 反编译很弱, 这里走乐视 PC 公开 API.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class LeDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.le;

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  };

  Dio _newDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        headers: _headers,
        responseType: ResponseType.plain,
      ));

  @override
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio}) async {
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      // 走乐视 so.le.com HTML, 内部抓 vid 列表
      final url = 'https://so.le.com/s?wd=' + Uri.encodeQueryComponent(keyword);
      final r = await d.get<String>(url,
          options: Options(headers: _headers));
      if (r.data == null || r.data!.isEmpty) return [];
      final html = r.data!;
      final out = <DanmakuMedia>[];
      // 乐视搜索结果: data-aid="..." data-vid="..."
      final aidRe = RegExp(r'data-aid="(\d+)"[^>]*data-vid="(\d+)"[^>]*>([\s\S]*?)</a>');
      final yearRe = RegExp(r'(\d{4})');
      for (final m in aidRe.allMatches(html)) {
        final aid = m.group(1);
        final vid = m.group(2);
        if (aid == null || vid == null) continue;
        final titleHtml = m.group(3) ?? '';
        final title = titleHtml.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        final year = int.tryParse(yearRe.firstMatch(titleHtml)?.group(0) ?? '');
        out.add(DanmakuMedia(
          source: sourceEnum,
          mediaId: aid, // 用 aid 走分集列表
          title: title,
          type: title.contains('电影') ? 'movie' : 'tv',
          year: year,
          poster: null,
          episodeCount: 80,
        ));
      }
      return out;
    } catch (_) {
      return [];
    } finally {
      if (own) d.close(force: true);
    }
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId, {Dio? dio}) async {
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      final url = 'https://api.le.com/album/episodeList?albumId=$mediaId';
      final r = await d.get<String>(url,
          options: Options(headers: _headers));
      if (r.data == null || r.data!.isEmpty) return [];
      final root = json.decode(r.data!);
      if (root is! Map) return [];
      final data = root['data'];
      if (data is! Map) return [];
      final videos = data['videos'];
      if (videos is! List) {
        // 当成单集 (电影)
        return [
          DanmakuEpisode(
            source: sourceEnum,
            episodeId: mediaId,
            order: 1,
            title: '正片',
          )
        ];
      }
      return videos.map<DanmakuEpisode>((e) {
        final m = e is Map ? e : const {};
        final vid = m['videoId']?.toString() ??
            m['id']?.toString() ??
            '';
        return DanmakuEpisode(
          source: sourceEnum,
          episodeId: vid,
          order: (m['episode'] is num)
              ? (m['episode'] as num).toInt()
              : 0,
          title: m['name']?.toString() ?? m['title']?.toString() ?? '',
        );
      }).where((e) => e.episodeId.isNotEmpty).toList();
    } catch (_) {
      return [];
    } finally {
      if (own) d.close(force: true);
    }
  }

  @override
  Future<List<DanmakuComment>> getDanmaku(
    String episodeId, {
    int startSec = 0,
    int endSec = 0,
    Dio? dio,
  }) async {
    if (episodeId.isEmpty) return [];
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      int s = startSec;
      final e = endSec > 0 ? endSec : 3600 * 8;
      final all = <DanmakuComment>[];
      int emptyCount = 0;
      // 并行批量加载: 每批 15 个分片同时请求, 批次结束后检查连续空段
      const batchSize = 15;
      while (s < e) {
        // 构建本批分片 (start,end) 列表
        final batchSegs = <List<int>>[];
        for (var i = 0; i < batchSize && s < e; i++) {
          final segEnd = (s + 300).clamp(0, e);
          batchSegs.add([s, segEnd]);
          s = segEnd;
        }
        final results = await Future.wait(
          batchSegs.map((se) async {
            final segStart = se[0];
            final segEnd = se[1];
            try {
              final url = 'https://hd-my.le.com/danmu/list'
                  '?vid=$episodeId&start=$segStart&end=$segEnd';
              final r = await d.get<String>(url,
                  options: Options(headers: _headers));
              if (r.data == null || r.data!.isEmpty) {
                return <DanmakuComment>[];
              }
              final text = r.data!;
              // 兼容 JSONP
              var body = text;
              final pIdx = body.indexOf('(');
              final lIdx = body.lastIndexOf(')');
              if (pIdx >= 0 && lIdx > pIdx && body.indexOf(';') > 0) {
                body = body.substring(pIdx + 1, lIdx);
              }
              final root = json.decode(body);
              final out = <DanmakuComment>[];
              if (root is Map) {
                final data = root['data'];
                List? list;
                if (data is List) {
                  list = data;
                } else if (data is Map) {
                  for (final k in ['list', 'items', 'danmu', 'barrage_list']) {
                    final v = data[k];
                    if (v is List) {
                      list = v;
                      break;
                    }
                  }
                }
                if (list != null) {
                  for (final item in list) {
                    if (item is! Map) continue;
                    final t = (item['time'] is num)
                        ? (item['time'] as num).toInt()
                        : ((item['playat'] is num) ? (item['playat'] as num).toInt() : 0);
                    final content = item['content']?.toString() ??
                        item['text']?.toString() ??
                        '';
                    if (content.isEmpty) continue;
                    int mode = 1;
                    final type = item['type']?.toString() ?? '';
                    if (type == 'top') {
                      mode = 5;
                    } else if (type == 'bottom') {
                      mode = 4;
                    }
                    int color = 0xFFFFFF;
                    final c = item['color'];
                    if (c is num) color = c.toInt();
                    out.add(DanmakuComment(
                      timeMs: t * 1000,
                      mode: mode,
                      color: color,
                      content: content,
                    ));
                  }
                }
              }
              return out;
            } catch (e) {
              if (segStart == 0) debugPrint('[Le] first seg error: $e');
              return <DanmakuComment>[];
            }
          }),
        );
        for (final batchComments in results) {
          if (batchComments.isEmpty) {
            emptyCount++;
          } else {
            emptyCount = 0;
            all.addAll(batchComments);
          }
        }
        // ★ 连续 3 段空 = 越界, break (避免 96 段死循环)
        if (emptyCount >= 3) break;
      }
      debugPrint('[Le] vid=$episodeId → ${all.length} comments');
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }
}
