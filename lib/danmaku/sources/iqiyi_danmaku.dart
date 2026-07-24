// lib/danmaku/sources/iqiyi_danmaku.dart
// 爱奇艺弹幕源 — SeleneTV vt1.java 反编译移植
//
// 协议:
//   - 搜索:  https://search.video.iqiyi.com/o?if=html5&key={kw}
//   - 分集:  https://pcw-api.iqiyi.com/albums/album/avlistinfo?aid={aid}&page=1&size=60
//   - 时长:  https://pcw-api.iqiyi.com/video/video/baseinfo/{tvid}
//   - 弹幕:  https://cmts.iqiyi.com/bullet/{p2}/{tvid}/{tvid}_300_{seg}.z
//   - 分片:  5 min 一片, raw deflate (zlib) + XML, 走 er.a 正则解析
//   - 上限:  100 段 (≈ 8h20min)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class IqiyiDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.iqiyi;

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
      final url = 'https://search.video.iqiyi.com/o?if=html5&key=' +
          Uri.encodeQueryComponent(keyword);
      final r = await d.get<String>(url,
          options: Options(headers: _bulletHeaders));
      final body = r.data ?? '';
      if (body.isEmpty) return [];
      final root = json.decode(body);
      final data = root is Map ? root['data'] : null;
      if (data is! Map) return [];
      final docs = data['docinfos'];
      if (docs is! List) return [];
      final out = <DanmakuMedia>[];
      for (final item in docs) {
        if (item is! Map) continue;
        final album = item['albumDocInfo'];
        if (album is! Map) continue;
        if (album['siteId']?.toString() != 'iqiyi') continue;
        final channel = (album['channel']?.toString() ?? '').split(',');
        final chan = channel.length > 1 ? channel[1] : '';
        final aid = album['albumId']?.toString();
        final title = album['albumTitle']?.toString() ?? '';
        if (aid == null || aid.isEmpty) continue;
        final release = album['releaseDate']?.toString() ?? '';
        final year =
            release.length >= 4 ? int.tryParse(release.substring(0, 4)) : null;
        out.add(DanmakuMedia(
          source: sourceEnum,
          mediaId: aid,
          title: title,
          type: chan == '1' ? 'movie' : 'tv',
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
      final url = 'https://pcw-api.iqiyi.com/albums/album/avlistinfo'
          '?aid=$mediaId&page=1&size=60';
      final r = await d.get<String>(url,
          options: Options(headers: _bulletHeaders));
      final body = r.data ?? '';
      if (body.isEmpty) {
        return [
          DanmakuEpisode(
              source: sourceEnum, episodeId: mediaId, order: 1, title: '正片')
        ];
      }
      final root = json.decode(body);
      final data = root is Map ? root['data'] : null;
      if (data is! Map) {
        return [
          DanmakuEpisode(
              source: sourceEnum, episodeId: mediaId, order: 1, title: '正片')
        ];
      }
      final eps = data['epsodelist'];
      if (eps is! List || eps.isEmpty) {
        return [
          DanmakuEpisode(
              source: sourceEnum, episodeId: mediaId, order: 1, title: '正片')
        ];
      }
      return eps.map<DanmakuEpisode>((e) {
        final m = e is Map ? e : const {};
        return DanmakuEpisode(
          source: sourceEnum,
          episodeId: (m['tvId'] ?? '').toString(),
          order: (m['order'] is num) ? (m['order'] as num).toInt() : 0,
          title: m['name']?.toString() ?? '',
        );
      }).where((e) => e.episodeId.isNotEmpty).toList();
    } catch (_) {
      return [
        DanmakuEpisode(
            source: sourceEnum, episodeId: mediaId, order: 1, title: '正片')
      ];
    } finally {
      if (own) d.close(force: true);
    }
  }

  static const Map<String, String> _bulletHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://www.iqiyi.com',
  };

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
      // 1) 拿总时长, 决定段数
      int totalSegs = 100;
      try {
        final infoR = await d.get<String>(
          'https://pcw-api.iqiyi.com/video/video/baseinfo/$episodeId',
          options: Options(headers: _bulletHeaders),
        );
        if (infoR.data != null && infoR.data!.isNotEmpty) {
          final info = json.decode(infoR.data!);
          if (info is Map && info['data'] is Map) {
            final dur = (info['data']['durationSec'] as num?)?.toInt() ?? 0;
            if (dur > 0) {
              totalSegs = (dur / 300.0).ceil();
              if (totalSegs < 1) totalSegs = 1;
            }
          }
        }
      } catch (e) {
        debugPrint('[iQiyi] baseinfo failed: $e');
      }

      int startSeg = startSec > 0 ? (startSec / 300).floor() + 1 : 1;
      int endSeg = endSec > 0
          ? (endSec / 300.0).ceil().clamp(1, totalSegs)
          : totalSegs;
      if (startSeg > endSeg) endSeg = startSeg;
      if (endSeg > 100) endSeg = 100; // 单源硬上限

      // 2) URL 路径: 前 2 位做子目录
      final prefix = episodeId.length >= 2
          ? episodeId.substring(0, 2)
          : episodeId;

      final all = <DanmakuComment>[];
      for (var seg = startSeg; seg <= endSeg; seg++) {
        final url = 'https://cmts.iqiyi.com/bullet/'
            '$prefix/$episodeId/${episodeId}_300_$seg.z';
        try {
          final r = await d.get<List<int>>(
            url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: _bulletHeaders,
            ),
          );
          final raw = r.data;
          if (raw == null || raw.isEmpty) {
            if (seg > 1) break;
            continue;
          }
          final xml = _inflateIqiyi(Uint8List.fromList(raw));
          if (xml.isEmpty) {
            debugPrint('[iQiyi] seg$seg inflate empty, raw=${raw.length}B '
                'head=${raw.length >= 4 ? raw.sublist(0, 4) : raw}');
            if (seg > 1) break;
            continue;
          }
          final parsed = _parseIqiyiXml(xml);
          if (parsed.isEmpty && seg == 1) {
            debugPrint('[iQiyi] seg1 parsed 0 from xml len=${xml.length}');
          }
          all.addAll(parsed);
        } on DioException catch (e) {
          debugPrint('[iQiyi] seg$seg DioException: ${e.response?.statusCode} ${e.message}');
          if (seg > 1) break;
        } catch (e) {
          debugPrint('[iQiyi] seg$seg error: $e');
          if (seg > 1) break;
        }
      }
      debugPrint('[iQiyi] tvid=$episodeId → ${all.length} comments');
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  // iqiyi .z 文件可能有两种格式:
  //   1) zlib 格式 (0x78 0x9c 头 + adler32 尾) — dart:io zlib.decode 可直接解
  //   2) raw deflate (无头无尾) — 需 ZLibDecoder(raw: true)
  // 解出后是 XML, 含 <d p="..."> 文本</d> 或 <bulletInfo> 结构.
  String _inflateIqiyi(Uint8List raw) {
    if (raw.length < 2) return '';

    // 方案 1: 标准 zlib (带 header)
    try {
      final bytes = zlib.decode(raw);
      final s = utf8.decode(bytes);
      if (s.startsWith('<') || s.contains('<bulletInfo>') || s.contains('<d ')) {
        return s;
      }
    } catch (_) {}

    // 方案 2: raw deflate (无 zlib header)
    try {
      final decoder = ZLibDecoder(raw: true);
      final bytes = decoder.convert(raw);
      final s = utf8.decode(bytes);
      if (s.startsWith('<') || s.contains('<bulletInfo>') || s.contains('<d ')) {
        return s;
      }
    } catch (_) {}

    // 方案 3: 剥 2 字节头 + 4 字节尾再试 zlib
    if (raw.length > 6) {
      try {
        final body = raw.sublist(2, raw.length - 4);
        final decoder = ZLibDecoder(raw: true);
        final bytes = decoder.convert(body);
        final s = utf8.decode(bytes);
        if (s.startsWith('<') || s.contains('<bulletInfo>') || s.contains('<d ')) {
          return s;
        }
      } catch (_) {}
    }

    // 方案 4: 退化 — 直接当 UTF-8 文本 (极少数未压缩响应)
    try {
      final s = utf8.decode(raw, allowMalformed: true);
      if (s.startsWith('<') || s.contains('<d ')) return s;
    } catch (_) {}

    return '';
  }

  static final RegExp _dRe = RegExp(r'<d\s+p="([^"]*)"[^>]*>([^<]*)</d>');

  List<DanmakuComment> _parseIqiyiXml(String xml) {
    if (xml.isEmpty) return const [];
    final out = <DanmakuComment>[];
    for (final m in _dRe.allMatches(xml)) {
      final p = m.group(1) ?? '';
      final raw = m.group(2) ?? '';
      final parts = p.split(',');
      if (parts.length < 4) continue;
      final t = double.tryParse(parts[0]);
      if (t == null) continue;
      final mode = int.tryParse(parts[1]) ?? 1;
      final color = int.tryParse(parts[3]) ?? 0xFFFFFF;
      final text = raw
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&apos;', "'")
          .replaceAll('&amp;', '&');
      if (text.isEmpty) continue;
      out.add(DanmakuComment(
        timeMs: (t * 1000).toInt(),
        mode: mode,
        color: color,
        content: text,
      ));
    }
    return out;
  }
}
