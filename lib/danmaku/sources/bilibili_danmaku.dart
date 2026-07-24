// lib/danmaku/sources/bilibili_danmaku.dart
// B站弹幕源 — SeleneTV gr.java 反编译移植
//
// 协议 (对齐 SeleneTV gr.java):
//   - 搜索:  https://api.bilibili.com/x/web-interface/search/all/v2?keyword={kw}
//   - 分集:  season  → https://api.bilibili.com/pgc/view/web/ep/list?season_id={sid}
//            bvid    → https://api.bilibili.com/x/player/pagelist?bvid={bvid}
//   - 弹幕:  https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid={cid}&segment_index={seg}
//            protobuf 二进制 (DmSegMobileReply), 6 min 一片
//   - ★ buvid3: 先 GET https://www.bilibili.com 暖场, 再 GET finger/spi 取 b_3/b_4
//               组 Cookie: buvid3={b_3}; buvid4={b_4}, 不带会被 -412 风控
//   - ★ content 字段: protobuf DanmakuElem field 7 (不是 6, 6 是 midHash)
//   - ★ list.so 回退: seg.so 全空时走 https://api.bilibili.com/x/v1/dm/list.so?oid={oid}
//                     raw deflate (Inflater(true)) + XML <d p="t,mode,fs,color,...">text</d>
//   - mediaId 两种格式: "ep:{seasonId}" 番剧 / "bv:{bvid}" 普通视频

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class BilibiliDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.bilibili;

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

  // ---- buvid3 cookie 缓存 (对齐 SeleneTV gr.b 字段) ----
  String? _cachedCookie;

  static const Map<String, String> _segHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com',
    'Origin': 'https://www.bilibili.com',
  };

  /// 获取 buvid3 Cookie — 对齐 SeleneTV gr.e():
  ///   1. GET https://www.bilibili.com (暖场)
  ///   2. GET https://api.bilibili.com/x/frontend/finger/spi → JSON {data:{b_3, b_4}}
  ///   3. 组 "buvid3={b_3}; buvid4={b_4}"
  Future<String> _getBuvid3Cookie(Dio dio) async {
    if (_cachedCookie != null) return _cachedCookie!;
    try {
      // 1. 暖场访问 (SeleneTV gr.e() 第一步)
      await dio.get<String>(
        'https://www.bilibili.com',
        options: Options(
          headers: _segHeaders,
          responseType: ResponseType.plain,
        ),
      );
    } catch (_) {}
    try {
      // 2. 取 finger/spi
      final r = await dio.get<String>(
        'https://api.bilibili.com/x/frontend/finger/spi',
        options: Options(
          headers: _segHeaders,
          responseType: ResponseType.plain,
        ),
      );
      if (r.data != null && r.data!.isNotEmpty) {
        final root = json.decode(r.data!);
        if (root is Map) {
          final data = root['data'];
          if (data is Map) {
            final b3 = data['b_3']?.toString() ?? '';
            final b4 = data['b_4']?.toString() ?? '';
            if (b3.isNotEmpty) {
              _cachedCookie = 'buvid3=$b3; buvid4=$b4';
              debugPrint('[Bilibili] buvid3 cookie fetched: '
                  '${b3.substring(0, b3.length.clamp(0, 12))}...');
              return _cachedCookie!;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[Bilibili] finger/spi error: $e');
    }
    // 兜底: dummy buvid3 (可能被 412, 但 list.so 回退仍可工作)
    _cachedCookie = 'buvid3=infoc; buvid4=00000000-0000-0000-0000-000000000000';
    return _cachedCookie!;
  }

  @override
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio}) async {
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      final url = 'https://api.bilibili.com/x/web-interface/search/all/v2'
          '?keyword=${Uri.encodeQueryComponent(keyword)}'
          '&platform=pc&duration=0&order=totalrank';
      final r = await d.get<String>(url,
          options: Options(
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://search.bilibili.com',
              'Cookie': 'buvid3=infoc; b_nut=100',
            },
            responseType: ResponseType.plain,
          ));
      if (r.data == null || r.data!.isEmpty) return [];
      final root = json.decode(r.data!);
      if (root is! Map) return [];
      final data = root['data'];
      if (data is! Map) return [];
      final result = data['result'];
      if (result is! List) return [];
      final out = <DanmakuMedia>[];
      for (final group in result) {
        if (group is! Map) continue;
        final resultType = group['result_type']?.toString();
        final dataList = group['data'];
        if (dataList is! List) continue;
        for (final item in dataList) {
          if (item is! Map) continue;
          // 只取番剧 (media_bangumi) 和 普通视频 (video)
          if (resultType == 'media_bangumi' || resultType == 'media_ft') {
            final sid = item['season_id']?.toString();
            if (sid == null || sid.isEmpty) continue;
            out.add(DanmakuMedia(
              source: sourceEnum,
              mediaId: 'ep:$sid',
              title: item['title']?.toString().replaceAll('<em class="keyword">', '').replaceAll('</em>', '') ?? '',
              type: 'tv',
              year: int.tryParse(item['season_year']?.toString() ?? '0') ?? 0,
              poster: null,
              episodeCount: 80,
            ));
          } else if (resultType == 'video') {
            final bvid = item['bvid']?.toString();
            if (bvid == null || bvid.isEmpty) continue;
            out.add(DanmakuMedia(
              source: sourceEnum,
              mediaId: 'bv:$bvid',
              title: item['title']?.toString().replaceAll('<em class="keyword">', '').replaceAll('</em>', '') ?? '',
              type: 'movie',
              year: null,
              poster: null,
              episodeCount: 1,
            ));
          }
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
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId, {Dio? dio}) async {
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      if (mediaId.startsWith('ep:')) {
        final sid = mediaId.substring(3);
        final r = await d.get<String>(
          'https://api.bilibili.com/pgc/view/web/ep/list?season_id=$sid',
          options: Options(headers: _segHeaders, responseType: ResponseType.plain),
        );
        if (r.data == null || r.data!.isEmpty) return [];
        final root = json.decode(r.data!);
        if (root is! Map) return [];
        final result = root['result'];
        if (result is! Map) return [];
        final eps = result['episodes'];
        if (eps is! List) return [];
        // ★ 对齐 SeleneTV gr.b(): episodeId = cid (optLong), 不是 id/epid!
        //   seg.so 的 oid 必须是 cid, 用 epid 会被风控/返空 → "暂无弹幕"
        final out = <DanmakuEpisode>[];
        for (var i = 0; i < eps.length; i++) {
          final m = eps[i] is Map ? eps[i] as Map : const {};
          final cid = (m['cid'] is num) ? (m['cid'] as num).toInt().toString() : '';
          if (cid.isEmpty) continue;
          // title: long_title → title → "第{i+1}集" (对齐 SeleneTV)
          String title = m['long_title']?.toString() ?? '';
          if (title.isEmpty) {
            title = m['title']?.toString() ?? '';
            if (title.isEmpty) {
              title = '第${i + 1}集';
            }
          }
          out.add(DanmakuEpisode(
            source: sourceEnum,
            episodeId: cid,
            order: i + 1, // 对齐 SeleneTV: index+1, 不用 ord 字段
            title: title,
          ));
        }
        return out;
      } else if (mediaId.startsWith('bv:')) {
        final bvid = mediaId.substring(3);
        final r = await d.get<String>(
          'https://api.bilibili.com/x/player/pagelist?bvid=$bvid',
          options: Options(headers: _segHeaders, responseType: ResponseType.plain),
        );
        if (r.data == null || r.data!.isEmpty) return [];
        final root = json.decode(r.data!);
        if (root is! Map) return [];
        final data = root['data'];
        if (data is! List) return [];
        // ★ 对齐 SeleneTV gr.b(): episodeId = cid, order = index+1,
        //   title = part → "P{index+1}"
        final out = <DanmakuEpisode>[];
        for (var i = 0; i < data.length; i++) {
          final m = data[i] is Map ? data[i] as Map : const {};
          final cid = (m['cid'] is num) ? (m['cid'] as num).toInt().toString() : '';
          if (cid.isEmpty) continue;
          String title = m['part']?.toString() ?? '';
          if (title.isEmpty) {
            title = 'P${i + 1}';
          }
          out.add(DanmakuEpisode(
            source: sourceEnum,
            episodeId: cid,
            order: i + 1,
            title: title,
          ));
        }
        return out;
      }
      return [];
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
      // 1. 获取 buvid3 Cookie (对齐 SeleneTV gr.e())
      final cookie = await _getBuvid3Cookie(d);
      final reqHeaders = {
        ..._segHeaders,
        'Cookie': cookie,
      };

      // 2. 分段计算 (对齐 SeleneTV: 360s/段, 默认 100 段)
      final startSeg = startSec > 0 ? (startSec / 360).floor() + 1 : 1;
      final endSeg = endSec > 0
          ? (endSec / 360.0).ceil().clamp(1, 100)
          : 100; // SeleneTV 默认 100 段

      // 3. 遍历 seg.so protobuf 段
      final all = <DanmakuComment>[];
      for (var seg = startSeg; seg <= endSeg; seg++) {
        final url = 'https://api.bilibili.com/x/v2/dm/web/seg.so'
            '?type=1&oid=$episodeId&segment_index=$seg';
        try {
          final r = await d.get<List<int>>(
            url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: reqHeaders,
            ),
          );
          final raw = r.data;
          if (raw == null || raw.isEmpty) {
            // 空段 = 越界, 对齐 SeleneTV: 立即 break
            break;
          }
          final parsed = _parseDmSegMobile(Uint8List.fromList(raw));
          if (parsed.isEmpty) {
            // 有数据但解析 0 条 (可能 -412 JSON 或风控页)
            if (seg == 1) {
              debugPrint('[Bilibili] seg1 parsed 0, raw=${raw.length}B '
                  'head=${raw.length >= 8 ? raw.sublist(0, 8) : raw}');
            }
            // 对齐 SeleneTV: 空段 break
            break;
          }
          all.addAll(parsed);
        } on DioException catch (e) {
          final code = e.response?.statusCode;
          debugPrint('[Bilibili] seg$seg DioException: $code ${e.message}');
          // 任何错误都 break (对齐 SeleneTV: xg0.a 异常 → 返空 → break)
          break;
        } catch (e) {
          debugPrint('[Bilibili] seg$seg error: $e');
          break;
        }
      }

      if (all.isNotEmpty) {
        debugPrint('[Bilibili] oid=$episodeId → ${all.length} comments (seg.so)');
        return all;
      }

      // 4. list.so 回退 (对齐 SeleneTV gr.a(): seg.so 全空 + startSec==0 + endSec==0)
      if (startSec == 0 && endSec == 0) {
        try {
          final listUrl =
              'https://api.bilibili.com/x/v1/dm/list.so?oid=$episodeId';
          final r = await d.get<List<int>>(
            listUrl,
            options: Options(
              responseType: ResponseType.bytes,
              headers: reqHeaders,
            ),
          );
          final raw = r.data;
          if (raw != null && raw.isNotEmpty) {
            final xml = _inflateListSo(Uint8List.fromList(raw));
            if (xml.isNotEmpty) {
              final parsed = _parseListSoXml(xml);
              debugPrint('[Bilibili] list.so fallback → ${parsed.length} comments');
              return parsed;
            }
          }
        } catch (e) {
          debugPrint('[Bilibili] list.so fallback error: $e');
        }
      }

      debugPrint('[Bilibili] oid=$episodeId → 0 comments (all paths failed)');
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  // ---- list.so raw deflate 解压 (对齐 SeleneTV xg0.b: Inflater(true)) ----
  String _inflateListSo(Uint8List raw) {
    if (raw.length < 2) return '';

    // 方案 1: raw deflate (Inflater(true) = SeleneTV 方式)
    try {
      final bytes = ZLibDecoder(raw: true).convert(raw);
      final s = utf8.decode(bytes, allowMalformed: true);
      if (s.contains('<d ') || s.contains('<i')) return s;
    } catch (_) {}

    // 方案 2: 标准 zlib (带 header)
    try {
      final bytes = zlib.decode(raw);
      final s = utf8.decode(bytes, allowMalformed: true);
      if (s.contains('<d ') || s.contains('<i')) return s;
    } catch (_) {}

    // 方案 3: 直接当文本 (未压缩)
    try {
      final s = utf8.decode(raw, allowMalformed: true);
      if (s.contains('<d ') || s.contains('<i')) return s;
    } catch (_) {}

    return '';
  }

  // ---- list.so XML 解析: <d p="time,mode,fontsize,color,...">text</d> ----
  static final RegExp _dRe =
      RegExp(r'<d\s+p="([^"]*)"[^>]*>([^<]*)</d>');

  List<DanmakuComment> _parseListSoXml(String xml) {
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

  String _decodeEntities(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1) ?? '', radix: 16);
          return code != null ? String.fromCharCode(code) : m.group(0)!;
        })
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1) ?? '');
          return code != null ? String.fromCharCode(code) : m.group(0)!;
        })
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  // ---- protobuf 解析: DmSegMobileReply → DanmakuElem ----
  //   message DmSegMobileReply { repeated DanmakuElem elems = 1; }
  //   message DanmakuElem {
  //     int64 id = 1;        int32 progress = 2;  (ms)
  //     int32 mode = 3;      int32 fontsize = 4;
  //     uint32 color = 5;    string midHash = 6;  ← 不是 content!
  //     string content = 7;  ← ★ 弹幕文本 (旧代码误用 field 6)
  //     int64 ctime = 8;     int32 weight = 9;
  //     string action = 10;  int32 pool = 11;
  //     string idStr = 12;   int32 attr = 13;
  //   }
  List<DanmakuComment> _parseDmSegMobile(Uint8List raw) {
    final out = <DanmakuComment>[];
    try {
      final elems = _readEmbeddedMessages(raw, 1);
      for (final e in elems) {
        final progress = _readInt32Field(e, 2) ?? 0;
        final mode = _readInt32Field(e, 3) ?? 1;
        final color = _readUint32Field(e, 5) ?? 0xFFFFFF;
        final content = _readStringField(e, 7) ?? ''; // ★ field 7 = content
        if (content.isEmpty) continue;
        out.add(DanmakuComment(
          timeMs: progress,
          mode: mode,
          color: color,
          content: content,
        ));
      }
    } catch (_) {}
    return out;
  }

  // 简易 protobuf wire format 解析 (varint + length-delimited)
  List<Uint8List> _readEmbeddedMessages(Uint8List data, int targetField) {
    final out = <Uint8List>[];
    var i = 0;
    while (i < data.length) {
      final tag = _readVarint(data, i);
      if (tag == null) break;
      i = tag.next;
      final fieldNo = tag.value >> 3;
      final wire = tag.value & 0x7;
      if (wire == 2 && fieldNo == targetField) {
        final len = _readVarint(data, i);
        if (len == null) break;
        i = len.next;
        if (i + len.value > data.length) break;
        out.add(Uint8List.sublistView(data, i, i + len.value));
        i += len.value;
      } else if (wire == 0) {
        final v = _readVarint(data, i);
        if (v == null) break;
        i = v.next;
      } else if (wire == 1) {
        i += 8;
      } else if (wire == 5) {
        i += 4;
      } else if (wire == 2) {
        final v = _readVarint(data, i);
        if (v == null) break;
        i = v.next + v.value;
      } else {
        break;
      }
    }
    return out;
  }

  int? _readInt32Field(Uint8List msg, int fieldNo) {
    return _readInt64Field(msg, fieldNo, isUnsigned: false)?.toInt();
  }

  int? _readUint32Field(Uint8List msg, int fieldNo) {
    final v = _readInt64Field(msg, fieldNo, isUnsigned: true);
    return v?.toInt();
  }

  String? _readStringField(Uint8List msg, int fieldNo) {
    var i = 0;
    while (i < msg.length) {
      final tag = _readVarint(msg, i);
      if (tag == null) return null;
      i = tag.next;
      final f = tag.value >> 3;
      final w = tag.value & 0x7;
      if (f == fieldNo && w == 2) {
        final len = _readVarint(msg, i);
        if (len == null) return null;
        i = len.next;
        if (i + len.value > msg.length) return null;
        return utf8.decode(msg.sublist(i, i + len.value));
      } else if (w == 0) {
        final v = _readVarint(msg, i);
        if (v == null) return null;
        i = v.next;
      } else if (w == 1) {
        i += 8;
      } else if (w == 5) {
        i += 4;
      } else if (w == 2) {
        final v = _readVarint(msg, i);
        if (v == null) return null;
        i = v.next + v.value;
      } else {
        return null;
      }
    }
    return null;
  }

  int? _readInt64Field(Uint8List msg, int fieldNo, {bool isUnsigned = false}) {
    var i = 0;
    while (i < msg.length) {
      final tag = _readVarint(msg, i);
      if (tag == null) return null;
      i = tag.next;
      final f = tag.value >> 3;
      final w = tag.value & 0x7;
      if (f == fieldNo && w == 0) {
        final v = _readVarint(msg, i);
        if (v == null) return null;
        return v.value;
      } else if (w == 0) {
        final v = _readVarint(msg, i);
        if (v == null) return null;
        i = v.next;
      } else if (w == 1) {
        i += 8;
      } else if (w == 5) {
        i += 4;
      } else if (w == 2) {
        final v = _readVarint(msg, i);
        if (v == null) return null;
        i = v.next + v.value;
      } else {
        return null;
      }
    }
    return null;
  }

  _Varint? _readVarint(Uint8List data, int start) {
    var result = 0;
    var shift = 0;
    var i = start;
    while (i < data.length) {
      final b = data[i];
      result |= (b & 0x7F) << shift;
      i++;
      if ((b & 0x80) == 0) {
        return _Varint(result, i);
      }
      shift += 7;
      if (shift >= 64) return null;
    }
    return null;
  }
}

class _Varint {
  final int value;
  final int next;
  const _Varint(this.value, this.next);
}
