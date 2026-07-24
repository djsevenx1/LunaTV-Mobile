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
      final r = await d.get<String>(url);
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
      final r = await d.get<String>(url);
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
      } catch (_) {}

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
            options: Options(responseType: ResponseType.bytes),
          );
          final raw = r.data;
          if (raw == null || raw.isEmpty) continue;
          final xml = _inflateIqiyi(Uint8List.fromList(raw));
          if (xml.isEmpty) continue;
          all.addAll(_parseIqiyiXml(xml));
        } catch (_) {
          // 单段失败不阻断
        }
      }
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  // iqiyi .z 文件是 raw deflate, 头 2 字节 zlib header, 尾 4 字节 adler32.
  // dart:io zlib 解码 zlib 格式 (含 header), 直接 inflate 即可.
  String _inflateIqiyi(Uint8List raw) {
    if (raw.length < 8) return '';
    try {
      // 先按 zlib 格式解 (服务端大多会带 header)
      final s = utf8.decode(zlib.decode(raw));
      if (s.startsWith('<d ') || s.contains('<bulletInfo>')) return s;
    } catch (_) {}
    try {
      // 剥 2 字节头 + 4 字节尾, 走 raw deflate — Dart 没有 raw inflate
      // 只能按 zlib 格式. 大多数情况下服务端文件已带 zlib 头, 上面能解.
      // 极少数 raw deflate 直接当 string (退化方案)
      return utf8.decode(raw, allowMalformed: true);
    } catch (_) {
      return '';
    }
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
