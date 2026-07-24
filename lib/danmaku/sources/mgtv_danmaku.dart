// lib/danmaku/sources/mgtv_danmaku.dart
// 芒果TV弹幕源 — SeleneTV jo2.java 反编译移植
//
// 协议:
//   - 搜索:  https://mobileso.bz.mgtv.com/so/v2/search?wd={kw}&t=video&p=0
//   - 分集:  https://pcweb.api.miguvideo.com/pc/player/core/v1/playurl?cid={cid}
//            返回 videos[] 含 url + title
//   - 弹幕:  https://bullet-ott.hitv.com/bullet/list?vid={vid}&start={start}&end={end}
//            zlib 压缩的 JSON
//   - 分片:  按 start/end 时间区间, 单次最大 5 min
//
// 反编译 jo2.java 的 R8 混淆很重, 走标准公开协议.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class MgtvDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.mgtv;

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Referer': 'https://www.mgtv.com/',
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
      final url = 'https://mobileso.bz.mgtv.com/so/v2/search'
          '?wd=${Uri.encodeQueryComponent(keyword)}&t=video&p=0';
      final r = await d.get<String>(url,
          options: Options(headers: _headers));
      if (r.data == null || r.data!.isEmpty) return [];
      final root = json.decode(r.data!);
      if (root is! Map) return [];
      final data = root['data'];
      if (data is! Map) return [];
      final contents = data['contents'];
      if (contents is! List) return [];
      final out = <DanmakuMedia>[];
      for (final item in contents) {
        if (item is! Map) continue;
        final type = item['type']?.toString() ?? '';
        // type: 1=单视频(电影), 2=剧集
        if (type != '1' && type != '2') continue;
        final cid = item['clip_id']?.toString() ??
            item['video_id']?.toString() ??
            item['id']?.toString() ??
            '';
        if (cid.isEmpty) continue;
        final title = item['title']?.toString() ?? '';
        final year = int.tryParse(item['year']?.toString() ?? '0');
        out.add(DanmakuMedia(
          source: sourceEnum,
          mediaId: cid,
          title: title,
          type: type == '1' ? 'movie' : 'tv',
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
      final url = 'https://pcweb.api.miguvideo.com/pc/player/core/v1/playurl'
          '?cid=$mediaId';
      final r = await d.get<String>(url,
          options: Options(headers: _headers));
      if (r.data == null || r.data!.isEmpty) return [];
      final root = json.decode(r.data!);
      if (root is! Map) return [];
      final data = root['data'];
      if (data is! Map) return [];
      final info = data['info'];
      if (info is! Map) return [];
      final videos = info['videos'];
      if (videos is! List || videos.isEmpty) {
        return [
          DanmakuEpisode(
            source: sourceEnum,
            episodeId: mediaId,
            order: 1,
            title: info['title']?.toString() ?? '正片',
          )
        ];
      }
      return videos.map<DanmakuEpisode>((e) {
        final m = e is Map ? e : const {};
        final vid = m['id']?.toString() ??
            m['video_id']?.toString() ??
            m['url']?.toString() ??
            '';
        final order = (m['seq'] is num)
            ? (m['seq'] as num).toInt()
            : ((m['index'] is num) ? (m['index'] as num).toInt() : 0);
        return DanmakuEpisode(
          source: sourceEnum,
          episodeId: vid,
          order: order,
          title: m['title']?.toString() ?? '',
        );
      }).where((e) => e.episodeId.isNotEmpty).toList();
    } catch (_) {
      return [
        DanmakuEpisode(
          source: sourceEnum,
          episodeId: mediaId,
          order: 1,
          title: '正片',
        )
      ];
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
      final e = endSec > 0 ? endSec : 3600 * 8; // 8h 上限
      final all = <DanmakuComment>[];
      int emptyCount = 0;
      const batchSize = 15;
      while (s < e) {
        // 构建当前批次的分片区间列表 (每片 300s)
        final batchPairs = <List<int>>[];
        var bs = s;
        for (var i = 0; i < batchSize && bs < e; i++) {
          final be = (bs + 300).clamp(0, e);
          batchPairs.add([bs, be]);
          bs = be;
        }
        // 并行请求整批 (8 个分片同时), 每段独立 try/catch
        final results = await Future.wait(
          batchPairs.map((pair) async {
            final segStart = pair[0];
            final segEnd = pair[1];
            try {
              final url = 'https://bullet-ott.hitv.com/bullet/list'
                  '?vid=$episodeId&start=$segStart&end=$segEnd';
              final r = await d.get<List<int>>(
                url,
                options: Options(
                  responseType: ResponseType.bytes,
                  headers: _headers,
                ),
              );
              final raw = r.data;
              if (raw != null && raw.isNotEmpty) {
                final text = _decodeMgtv(Uint8List.fromList(raw));
                if (text.isNotEmpty) {
                  return _parseMgtvJson(text);
                } else {
                  if (segStart == 0) {
                    debugPrint(
                        '[Mgtv] first seg decode empty, raw=${raw.length}B');
                  }
                }
              }
              return const <DanmakuComment>[];
            } catch (err) {
              if (segStart == 0) debugPrint('[Mgtv] first seg error: $err');
              return const <DanmakuComment>[];
            }
          }),
        );
        // 处理结果 (保持原有解析逻辑不变)
        for (final parsed in results) {
          if (parsed.isEmpty) {
            emptyCount++;
          } else {
            all.addAll(parsed);
            emptyCount = 0;
          }
        }
        // ★ 连续 3 段空 = 越界, break (每批结束后检查, 避免 96 段死循环)
        if (emptyCount >= 3) break;
        s = bs;
      }
      debugPrint('[Mgtv] vid=$episodeId → ${all.length} comments');
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  String _decodeMgtv(Uint8List raw) {
    if (raw.length < 2) return '';
    final looksJson = (String s) => s.startsWith('{') || s.startsWith('[');

    // 方案 1: 标准 zlib (带 header)
    try {
      final s = utf8.decode(zlib.decode(raw));
      if (looksJson(s)) return s;
    } catch (_) {}

    // 方案 2: raw deflate (无 header)
    try {
      final decoder = ZLibDecoder(raw: true);
      final s = utf8.decode(decoder.convert(raw));
      if (looksJson(s)) return s;
    } catch (_) {}

    // 方案 3: 剥 2 字节头 + 4 字节尾, raw deflate
    if (raw.length > 6) {
      try {
        final body = raw.sublist(2, raw.length - 4);
        final decoder = ZLibDecoder(raw: true);
        final s = utf8.decode(decoder.convert(body));
        if (looksJson(s)) return s;
      } catch (_) {}
    }

    // 方案 4: 直接当文本
    try {
      final s = utf8.decode(raw, allowMalformed: true);
      if (looksJson(s)) return s;
    } catch (_) {}

    return '';
  }

  List<DanmakuComment> _parseMgtvJson(String jsonStr) {
    final out = <DanmakuComment>[];
    try {
      final root = json.decode(jsonStr);
      if (root is! Map) return out;
      final data = root['data'];
      if (data is! Map) return out;
      final items = data['items'];
      if (items is! List) return out;
      for (final item in items) {
        if (item is! Map) continue;
        final t = (item['time'] is num) ? (item['time'] as num).toInt() : 0;
        final content = item['content']?.toString() ??
            item['msg']?.toString() ??
            '';
        if (content.isEmpty) continue;
        int mode = 1;
        final type = item['type']?.toString() ?? '';
        if (type.contains('top')) {
          mode = 5;
        } else if (type.contains('bottom')) {
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
    } catch (_) {}
    return out;
  }
}
