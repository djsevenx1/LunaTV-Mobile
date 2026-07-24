// lib/danmaku/sources/bilibili_danmaku.dart
// B站弹幕源 — SeleneTV gr.java 反编译移植
//
// 协议:
//   - 搜索:  https://api.bilibili.com/x/web-interface/search/all/v2?keyword={kw}
//   - 分集:  season  → https://api.bilibili.com/pgc/view/web/ep/list?season_id={sid}
//            bvid    → https://api.bilibili.com/x/player/pagelist?bvid={bvid}
//   - 弹幕:  https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid={cid}&segment_index={seg}
//            protobuf 二进制 (DmSegMobileReply), 6 min 一片
//   - mediaId 两种格式: "ep:{seasonId}" 番剧 / "bv:{bvid}" 普通视频
//
// 注: SeleneTV 用的是 wq4.R 走 Ktor 反射解 protobuf. 我们这边手写
//     protobuf wire format 解码 (varint + length-delimited), 只取弹幕段
//     (DanmakuElem), 其他字段忽略. 这样不用加 protobuf 包.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

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

  @override
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio}) async {
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      final url = 'https://api.bilibili.com/x/web-interface/search/all/v2'
          '?keyword=${Uri.encodeQueryComponent(keyword)}'
          '&platform=pc&duration=0&order=totalrank';
      final r = await d.get<String>(url);
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
        );
        if (r.data == null || r.data!.isEmpty) return [];
        final root = json.decode(r.data!);
        if (root is! Map) return [];
        final result = root['result'];
        if (result is! Map) return [];
        final eps = result['episodes'];
        if (eps is! List) return [];
        return eps.map<DanmakuEpisode>((e) {
          final m = e is Map ? e : const {};
          return DanmakuEpisode(
            source: sourceEnum,
            episodeId: (m['id'] is num) ? (m['id'] as num).toInt().toString() : '',
            order: (m['ord'] is num) ? (m['ord'] as num).toInt() : 0,
            title: m['share_copy']?.toString() ?? m['long_title']?.toString() ?? '',
          );
        }).where((e) => e.episodeId.isNotEmpty).toList();
      } else if (mediaId.startsWith('bv:')) {
        final bvid = mediaId.substring(3);
        final r = await d.get<String>(
          'https://api.bilibili.com/x/player/pagelist?bvid=$bvid',
        );
        if (r.data == null || r.data!.isEmpty) return [];
        final root = json.decode(r.data!);
        if (root is! Map) return [];
        final data = root['data'];
        if (data is! List) return [];
        return data.map<DanmakuEpisode>((p) {
          final m = p is Map ? p : const {};
          return DanmakuEpisode(
            source: sourceEnum,
            episodeId: (m['cid'] is num) ? (m['cid'] as num).toInt().toString() : '',
            order: (m['page'] is num) ? (m['page'] as num).toInt() : 0,
            title: m['part']?.toString() ?? '',
          );
        }).where((e) => e.episodeId.isNotEmpty).toList();
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
      final startSeg = startSec > 0 ? (startSec / 360).floor() + 1 : 1;
      final endSeg = endSec > 0 ? (endSec / 360.0).ceil() : 1000;

      final all = <DanmakuComment>[];
      for (var seg = startSeg; seg <= endSeg; seg++) {
        final url = 'https://api.bilibili.com/x/v2/dm/web/seg.so'
            '?type=1&oid=$episodeId&segment_index=$seg';
        try {
          final r = await d.get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
          );
          final raw = r.data;
          if (raw == null || raw.isEmpty) break;
          all.addAll(_parseDmSegMobile(Uint8List.fromList(raw)));
        } catch (_) {
          break; // 404 = 末尾
        }
      }
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  // 手解 DmSegMobileReply protobuf:
  //   message DmSegMobileReply { repeated DanmakuElem elems = 1; ... }
  //   message DanmakuElem {
  //     int64 id = 1;        int32 progress = 2;  (ms)
  //     int32 mode = 3;      int32 fontsize = 4;
  //     uint32 color = 5;    string content = 6;
  //     int64 ctime = 7;     int32 weight = 10;
  //     ...
  //   }
  List<DanmakuComment> _parseDmSegMobile(Uint8List raw) {
    final out = <DanmakuComment>[];
    try {
      // 跳过外层 DmSegMobileReply, 找 field 1 (length-delimited) = elems
      // 直接 walk wire format 找所有 DanmakuElem 嵌入消息
      final elems = _readEmbeddedMessages(raw, 1);
      for (final e in elems) {
        final progress = _readInt32Field(e, 2) ?? 0;
        final mode = _readInt32Field(e, 3) ?? 1;
        final color = _readUint32Field(e, 5) ?? 0xFFFFFF;
        final content = _readStringField(e, 6) ?? '';
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
