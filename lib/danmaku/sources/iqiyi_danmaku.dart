// lib/danmaku/sources/iqiyi_danmaku.dart
// 爱奇艺弹幕源 — SeleneTV 反编译移植 (vg0.b bulletInfo 解析 + xg0.b raw deflate)
//
// 协议:
//   - 搜索:  https://search.video.iqiyi.com/o?if=html5&key={kw}
//   - 分集:  https://pcw-api.iqiyi.com/albums/album/avlistinfo?aid={aid}&page=1&size=60
//   - 时长:  https://pcw-api.iqiyi.com/video/video/baseinfo/{tvid}
//   - 弹幕:  https://cmts.iqiyi.com/bullet/{tvid[-4:-2]}/{tvid[-2:]}/{tvid}_300_{seg}.z
//            ★ 路径用 tvid 末 4 位拆 2+2, 不是前 2 位 (旧实现 bug)
//   - 分片:  5 min 一片 (_300_ = 300s), raw deflate (Inflater nowrap=true) + XML
//   - XML:   <bulletInfo><showTime>(秒)</showTime><content>..</content><color>(hex)</color></bulletInfo>
//            兼容旧 <d p="time,mode,fs,color">text</d> 格式

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
      // 1) 拿总时长, 决定段数 (best-effort, 失败则用大上限靠 404/空收尾)
      int totalSegs = 60;
      try {
        final infoR = await d.get<String>(
          'https://pcw-api.iqiyi.com/video/video/baseinfo/$episodeId',
          options: Options(headers: _bulletHeaders),
        );
        if (infoR.data != null && infoR.data!.isNotEmpty) {
          final info = json.decode(infoR.data!);
          if (info is Map && info['data'] is Map) {
            final dm = info['data'] as Map;
            final durStr = (dm['duration'] ?? dm['durationSec'])?.toString() ??
                '0';
            final dur = _parseDuration(durStr);
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

      // 2) URL 路径: tvid 末 4 位拆 2+2 (SeleneTV / 公开协议一致)
      final p1 = episodeId.length >= 4
          ? episodeId.substring(episodeId.length - 4, episodeId.length - 2)
          : episodeId;
      final p2 = episodeId.length >= 4
          ? episodeId.substring(episodeId.length - 2)
          : episodeId;

      final all = <DanmakuComment>[];
      for (var seg = startSeg; seg <= endSeg; seg++) {
        final url = 'https://cmts.iqiyi.com/bullet/'
            '$p1/$p2/${episodeId}_300_$seg.z';
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
            // 空 body = 越界段
            if (seg > 1) break;
            continue;
          }
          final xml = _inflateIqiyi(Uint8List.fromList(raw));
          if (xml.isEmpty) {
            // 解不出 XML (非 .z 数据, 多半是越界 404 页)
            if (seg > 1) break;
            continue;
          }
          final parsed = _parseIqiyi(xml);
          if (parsed.isEmpty) {
            if (seg == 1) {
              debugPrint('[iQiyi] seg1 parsed 0, xmllen=${xml.length} '
                  'head=${xml.length >= 40 ? xml.substring(0, 40) : xml}');
            } else {
              // 段有 XML 但无弹幕节点 = 越界空段, 收尾
              break;
            }
          }
          all.addAll(parsed);
        } on DioException catch (e) {
          debugPrint('[iQiyi] seg$seg DioException: '
              '${e.response?.statusCode} ${e.message}');
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

  // 时长可能是纯秒数 ("2700") 或 HH:MM:SS ("01:15:30")
  int _parseDuration(String s) {
    s = s.trim();
    if (s.isEmpty) return 0;
    if (s.contains(':')) {
      final parts = s.split(':');
      int h = 0, m = 0, sec = 0;
      if (parts.length == 3) {
        h = int.tryParse(parts[0]) ?? 0;
        m = int.tryParse(parts[1]) ?? 0;
        sec = int.tryParse(parts[2]) ?? 0;
      } else if (parts.length == 2) {
        m = int.tryParse(parts[0]) ?? 0;
        sec = int.tryParse(parts[1]) ?? 0;
      }
      return h * 3600 + m * 60 + sec;
    }
    return int.tryParse(s) ?? 0;
  }

  // iqiyi .z 文件: SeleneTV 用 Inflater(true) = raw deflate (无 zlib 头).
  // 这里多级兜底以兼容 zlib 包装 / 直接文本.
  String _inflateIqiyi(Uint8List raw) {
    if (raw.length < 2) return '';
    final ok = (String s) =>
        s.startsWith('<') || s.contains('<bulletInfo>') || s.contains('<d ');

    // 方案 1: raw deflate (SeleneTV Inflater(true)) — 优先, iqiyi .z 多为裸 deflate
    try {
      final s = utf8.decode(ZLibDecoder(raw: true).convert(raw));
      if (ok(s)) return s;
    } catch (_) {}

    // 方案 2: 标准 zlib (带 header)
    try {
      final s = utf8.decode(zlib.decode(raw));
      if (ok(s)) return s;
    } catch (_) {}

    // 方案 3: 剥 2 字节头 + 4 字节尾再 raw deflate
    if (raw.length > 6) {
      try {
        final s = utf8.decode(
            ZLibDecoder(raw: true).convert(raw.sublist(2, raw.length - 4)));
        if (ok(s)) return s;
      } catch (_) {}
    }

    // 方案 4: 退化 — 直接当 UTF-8 文本 (极少数未压缩响应)
    try {
      final s = utf8.decode(raw, allowMalformed: true);
      if (ok(s)) return s;
    } catch (_) {}

    return '';
  }

  // ---- 解析: bulletInfo (新) + <d> (旧) 双格式 ----
  static final RegExp _bulletInfoRe =
      RegExp(r'<bulletInfo>([\s\S]*?)</bulletInfo>');
  static final RegExp _showTimeRe = RegExp(r'<showTime>([\s\S]*?)</showTime>');
  static final RegExp _contentRe = RegExp(r'<content>([\s\S]*?)</content>');
  static final RegExp _colorRe = RegExp(r'<color>([\s\S]*?)</color>');
  static final RegExp _hexEntityRe = RegExp(r'&#x([0-9a-fA-F]+);');
  static final RegExp _decEntityRe = RegExp(r'&#(\d+);');
  static final RegExp _dRe = RegExp(r'<d\s+p="([^"]*)"[^>]*>([^<]*)</d>');

  List<DanmakuComment> _parseIqiyi(String xml) {
    if (xml.isEmpty) return const [];
    final out = <DanmakuComment>[];

    // 1) bulletInfo 格式 (SeleneTV vg0.b)
    for (final m in _bulletInfoRe.allMatches(xml)) {
      final block = m.group(1) ?? '';
      final showTimeStr =
          _showTimeRe.firstMatch(block)?.group(1)?.trim() ?? '';
      final showTime = int.tryParse(showTimeStr);
      if (showTime == null || showTime < 0) continue;
      final contentRaw = _contentRe.firstMatch(block)?.group(1) ?? '';
      final content = _decodeEntities(contentRaw);
      if (content.isEmpty) continue;
      final colorStr = _colorRe.firstMatch(block)?.group(1)?.trim() ?? '';
      final color = colorStr.isEmpty
          ? 0xFFFFFF
          : (int.tryParse(colorStr, radix: 16) ?? 0xFFFFFF);
      out.add(DanmakuComment(
        timeMs: showTime * 1000, // showTime 单位是秒
        mode: 1,
        color: color,
        content: content,
      ));
    }
    if (out.isNotEmpty) return out; // bulletInfo 命中就不再走 <d>

    // 2) 旧 <d p="time,mode,fs,color">text</d> 格式
    for (final m in _dRe.allMatches(xml)) {
      final p = m.group(1) ?? '';
      final raw = m.group(2) ?? '';
      final parts = p.split(',');
      if (parts.length < 4) continue;
      final t = double.tryParse(parts[0]);
      if (t == null) continue;
      final mode = int.tryParse(parts[1]) ?? 1;
      final color = int.tryParse(parts[3]) ?? 0xFFFFFF;
      final text = _decodeEntities(raw);
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

  // HTML 实体解码 — 对齐 SeleneTV vg0.b: &#xHH; / &#DD; / &lt; &gt; &quot; &apos; &amp;
  String _decodeEntities(String s) {
    if (!s.contains('&')) return s;
    var r = s.replaceAllMapped(_hexEntityRe, (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });
    r = r.replaceAllMapped(_decEntityRe, (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });
    r = r
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&'); // &amp; 最后, 避免二次解码
    return r;
  }
}
