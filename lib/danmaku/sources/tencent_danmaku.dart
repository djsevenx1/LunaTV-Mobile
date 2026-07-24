// lib/danmaku/sources/tencent_danmaku.dart
// 腾讯视频弹幕源 — SeleneTV lf4.java 反编译移植
//
// 协议:
//   - 搜索:  https://v.qq.com/x/search/?q={kw}  (HTML, 解析 card)
//            简化版: 用官方 hint API → https://h5vv.video.qq.com/gethint?word=...
//   - 分集:  https://vv.video.qq.com/getvideoinfo?vid={vid}  (JSONP callback)
//   - 弹幕:  https://bullet.video.qq.com/fcgi-bin/bulletin/list
//            POST  body: {"vid":"...","cid":"...","page":seg}
//            响应: zlib + JSON
//   - 分片:  5 min 一片
//
// 反编译 R8 混淆很重, 我们用公开的 H5/PC 端协议, 走 HTML header + JSONP.
// 对没抓到 vid 的剧集直接走 title 搜索 + 拿 episode list.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class TencentDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.tencent;

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'Referer': 'https://v.qq.com/',
  };
  static const Map<String, String> _postHeaders = {
    ..._headers,
    'Content-Type': 'application/json',
    'Origin': 'https://v.qq.com',
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
      // hint API 不需要 sign, 简单 GET
      final url = 'https://h5vv.video.qq.com/gethint?word=' +
          Uri.encodeQueryComponent(keyword);
      final r = await d.get<String>(url,
          options: Options(headers: _headers));
      if (r.data == null || r.data!.isEmpty) return [];
      var body = r.data!;
      // 可能是 JSONP: callback({...}); → 剥 callback
      final pIdx = body.indexOf('(');
      final lIdx = body.lastIndexOf(')');
      if (pIdx >= 0 && lIdx > pIdx) {
        body = body.substring(pIdx + 1, lIdx);
      }
      final root = json.decode(body);
      if (root is! Map) return [];
      final list = root['list'];
      if (list is! List) return [];
      final out = <DanmakuMedia>[];
      for (final item in list) {
        if (item is! Map) continue;
        final doc = item['doc'] ?? item;
        if (doc is! Map) continue;
        final vid = doc['id']?.toString() ??
            doc['vid']?.toString() ??
            doc['playVid']?.toString() ??
            '';
        if (vid.isEmpty) continue;
        final title = doc['title']?.toString() ?? '';
        final year = int.tryParse(doc['year']?.toString() ?? '0');
        final type = doc['type']?.toString() ?? 'tv';
        out.add(DanmakuMedia(
          source: sourceEnum,
          mediaId: vid,
          title: title,
          type: type.contains('电影') ? 'movie' : 'tv',
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
      // getvideoinfo 返回 JSONP
      final url = 'https://vv.video.qq.com/getvideoinfo'
          '?otype=json&vid=$mediaId';
      final r = await d.get<String>(url,
          options: Options(headers: _headers));
      if (r.data == null || r.data!.isEmpty) return [];
      var body = r.data!;
      final pIdx = body.indexOf('(');
      final lIdx = body.lastIndexOf(')');
      if (pIdx >= 0 && lIdx > pIdx) {
        body = body.substring(pIdx + 1, lIdx);
      }
      final root = json.decode(body);
      if (root is! Map) return [];
      final fl = root['fl']; // 旧格式
      if (fl is! Map) {
        // 单集电影
        final vinfo = root['vinfo'];
        if (vinfo is Map) {
          final vid = mediaId;
          return [
            DanmakuEpisode(
              source: sourceEnum,
              episodeId: '$vid|0',
              order: 1,
              title: vinfo['title']?.toString() ?? '正片',
            )
          ];
        }
        return [];
      }
      // 多集
      final out = <DanmakuEpisode>[];
      // fl.fi 是按清晰度分组的分集列表, 取 mp4 组
      final fiList = fl['fi'];
      if (fiList is List) {
        for (var i = 0; i < fiList.length; i++) {
          final e = fiList[i];
          if (e is! Map) continue;
          final vid = e['id']?.toString() ?? '';
          if (vid.isEmpty) continue;
          final title = e['name']?.toString() ?? e['title']?.toString() ?? '第${i + 1}集';
          out.add(DanmakuEpisode(
            source: sourceEnum,
            episodeId: '$vid|0',
            order: i + 1,
            title: title,
          ));
        }
      }
      return out;
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
    final parts = episodeId.split('|');
    final vid = parts[0];
    if (vid.isEmpty) return [];
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      // 1) 拿总时长, 决定段数
      int totalSegs = 1;
      try {
        final infoUrl = 'https://vv.video.qq.com/getvideoinfo?otype=json&vid=$vid';
        final r = await d.get<String>(infoUrl,
            options: Options(headers: _headers));
        if (r.data != null && r.data!.isNotEmpty) {
          var body = r.data!;
          final pIdx = body.indexOf('(');
          final lIdx = body.lastIndexOf(')');
          if (pIdx >= 0 && lIdx > pIdx) {
            body = body.substring(pIdx + 1, lIdx);
          }
          final root = json.decode(body);
          if (root is Map) {
            final fl = root['fl'];
            if (fl is Map) {
              final dur = (fl['totaltime'] is num) ? (fl['totaltime'] as num).toInt() : 0;
              if (dur > 0) {
                totalSegs = (dur / 300.0).ceil();
                if (totalSegs < 1) totalSegs = 1;
              }
            }
          }
        }
      } catch (_) {}

      int startSeg = startSec > 0 ? (startSec / 300).floor() + 1 : 1;
      int endSeg = endSec > 0
          ? (endSec / 300.0).ceil().clamp(1, totalSegs)
          : totalSegs;
      if (startSeg > endSeg) return [];
      if (endSeg > 40) endSeg = 40; // ★ v2.5.46: 40 段上限 (~3.3h)

      final all = <DanmakuComment>[];
      // 并行批量加载: 每批 15 个分片同时请求, 批次结束后检查连续空段
      const batchSize = 15;
      var seg = startSeg;
      var emptyCount = 0;
      while (seg <= endSeg) {
        final batchSegs = <int>[];
        for (var i = 0; i < batchSize && seg <= endSeg; i++, seg++) {
          batchSegs.add(seg);
        }
        final results = await Future.wait(
          batchSegs.map((s) async {
            try {
              final r = await d.post<List<int>>(
                'https://bullet.video.qq.com/fcgi-bin/bulletin/list',
                data: utf8.encode(json.encode({
                  'vid': vid,
                  'cid': vid,
                  'page': s,
                })),
                options: Options(
                  responseType: ResponseType.bytes,
                  headers: _postHeaders,
                ),
              );
              final raw = r.data;
              if (raw == null || raw.isEmpty) {
                return <DanmakuComment>[];
              }
              final text = _decodeTencent(Uint8List.fromList(raw));
              if (text.isEmpty) {
                debugPrint('[Tencent] seg$s decode empty, raw=${raw.length}B');
                return <DanmakuComment>[];
              }
              return _parseTencentJson(text);
            } on DioException catch (e) {
              debugPrint('[Tencent] seg$s DioException: ${e.response?.statusCode} ${e.message}');
              return <DanmakuComment>[];
            } catch (e) {
              debugPrint('[Tencent] seg$s error: $e');
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
        if (emptyCount >= 3) break;
      }
      debugPrint('[Tencent] vid=$vid → ${all.length} comments');
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  // 腾讯弹幕响应: 可能是 zlib 压缩或 raw deflate, 解出后是 JSON
  String _decodeTencent(Uint8List raw) {
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

  List<DanmakuComment> _parseTencentJson(String jsonStr) {
    final out = <DanmakuComment>[];
    try {
      final root = json.decode(jsonStr);
      if (root is! Map) return out;
      // 多种字段名兼容: barrage_list / comments / arr
      List? list;
      for (final k in ['barrage_list', 'comments', 'arr', 'danmaku_list']) {
        final v = root[k];
        if (v is List) {
          list = v;
          break;
        }
      }
      if (list == null) return out;
      for (final item in list) {
        if (item is! Map) continue;
        final t = (item['time'] is num)
            ? (item['time'] as num).toInt()
            : ((item['playat'] is num) ? (item['playat'] as num).toInt() : 0);
        final content = item['content']?.toString() ??
            item['msg']?.toString() ??
            item['text']?.toString() ??
            '';
        if (content.isEmpty) continue;
        // mode: 0=滚动 1=顶部 2=底部 (腾讯)
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
        if (c is String) {
          // "0xFFFFFF" 形式
          if (c.startsWith('0x') || c.startsWith('#')) {
            color = int.tryParse(c.substring(c.startsWith('#') ? 1 : 2), radix: 16) ?? 0xFFFFFF;
          } else {
            color = int.tryParse(c) ?? 0xFFFFFF;
          }
        }
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
