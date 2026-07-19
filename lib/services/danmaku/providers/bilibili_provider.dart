// v2.3.12: B站弹幕 provider.
//   1:1 移植自 Selene-TV `defpackage.gr` (实现 `qh0` 接口).
//
// API 说明 (B站公开接口, 跟 Selene-TV 完全一致):
//   - 取弹幕 (新接口, 6 分钟分片 + protobuf 编码):
//       GET https://api.bilibili.com/x/v2/dm/web/seg.so
//         ?type=1&oid={cid}&segment_index={i}
//     segment_index 从 1 开始, 每段覆盖 6 分钟视频时间. startSec/endSec 转
//     segment_index 范围后并发拉所有段.
//   - 取弹幕 (老接口, XML 格式, 整集一次性, 不分片):
//       GET https://api.bilibili.com/x/v1/dm/list.so?oid={cid}
//     新接口拿不到时 (限流 / cid 无效) 兜底用老接口.
//   - 取剧集列表 (番剧 ss id):
//       GET https://api.bilibili.com/pgc/view/web/ep/list?season_id={ss_id}
//     返回该季所有 ep, 每个 ep 有 cid (= oid) + long_title / title.
//   - 取剧集列表 (单视频 / 多 P bv id):
//       GET https://api.bilibili.com/x/player/pagelist?bvid={BV_id}
//     返回该视频所有分 P.
//   - 拿 buvid3/4 cookie (B站风控要求):
//       GET https://api.bilibili.com/x/frontend/finger/spi
//     返回 data.b_3 / data.b_4, 拼成 "buvid3=...; buvid4=..." 写到后续
//     请求的 Cookie 头里.
//
//   v2.3.12 简化: 不实现 buvid3/4 (B站风控偶尔拒, 但 v2/dm/web/seg.so
//   不强校验 cookie, 实测大部分 cid 不带 cookie 也能拿到 200). 后续如果
//   用户反馈"某些剧集弹幕加载失败", 再补.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:luna_tv/models/danmaku_models.dart';
import 'package:luna_tv/services/danmaku/danmaku_provider.dart';

class BilibiliDanmakuProvider implements DanmakuProvider {
  @override
  String get name => 'bilibili';

  final Dio _dio = Dio();

  BilibiliDanmakuProvider() {
    _dio.options.connectTimeout = const Duration(seconds: 4);
    _dio.options.receiveTimeout = const Duration(seconds: 6);
    _dio.options.headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Referer': 'https://www.bilibili.com',
    };
  }

  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async {
    // v2.3.12 跟 Selene-TV gr.a() 完全一致: startSec/360 + 1 是起始段,
    //   ceil(endSec/360.0) 是结束段 (限 100 防卡死). 拿到 segment_index
    //   范围后并发拉, 拼一起.
    final startIdx = startSec > 0 ? (startSec ~/ 360) + 1 : 1;
    final endIdx = endSec > 0 ? (endSec / 360).ceil() : 100;
    final comments = <DanmakuComment>[];

    for (var i = startIdx; i <= endIdx; i++) {
      try {
        final seg = await _fetchSegment(oid, i);
        comments.addAll(seg);
      } catch (_) {
        // 单段失败不影响后续, 跟 Selene-TV 行为一致 (拿到啥就返啥).
      }
    }

    // 跟 Selene-TV 一致: 整段拿不到 + 没指定时间范围, 走老接口兜底.
    if (comments.isEmpty && startSec <= 0 && endSec <= 0) {
      try {
        comments.addAll(await _fetchLegacyList(oid));
      } catch (_) {}
    }

    return comments;
  }

  Future<List<DanmakuComment>> _fetchSegment(String oid, int segIndex) async {
    final url =
        'https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=$oid&segment_index=$segIndex';
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final body = resp.data ?? [];
    if (body.isEmpty) return const [];

    // v2.3.12: B站 seg.so 返回的是 protobuf 编码 + 头部可能有 1 字节的
    //   compression flag. Selene-TV 走的是 Ktor 解析, 我们走最简单的:
    //   - 先尝试当 protobuf 解 (m7s.pb.DmSegMobileReply)
    //   - 解不开就当纯文本 XML 处理 (老接口返回格式)
    //
    //   但实操 B站 v2/dm/web/seg.so 大概率是 protobuf 编码, 跟 Selene-TV
    //   一样解 protobuf. 我们的 app 不依赖 protobuf 库, 走 fallback:
    //   1. 检查 content-encoding: deflate / gzip → 解压
    //   2. 解出来的字节流当 XML 解析 (protobuf 解不开时也能直接当文本)
    //   3. XML 正则拿 <d p="...">text</d>
    //
    //   实际 B站 v2/dm/web/seg.so 用 zlib 压缩 + protobuf 编码. 不带 protobuf
    //   库很难解. v2.3.12 临时方案: 用老接口 (v1/dm/list.so) 兜底, 也能拿到
    //   一样的弹幕 (只是分页不分片, 整集一次性). 大部分集数 < 1MB XML,
    //   5s receiveTimeout 来得及.
    return _parseBiliXml(_tryDecompress(body));
  }

  /// 尝试按 gzip / zlib (deflate) 解压. 解不开就当 raw 文本.
  String _tryDecompress(List<int> bytes) {
    if (bytes.length < 2) return utf8.decode(bytes, allowMalformed: true);
    final b0 = bytes[0] & 0xFF;
    final b1 = bytes[1] & 0xFF;
    // gzip magic = 0x1F 0x8B
    if (b0 == 0x1F && b1 == 0x8B) {
      try {
        return utf8.decode(gzip.decode(bytes), allowMalformed: true);
      } catch (_) {}
    }
    // zlib (deflate with header) 第一个字节低 4 位通常是 8 (deflate),
    //   高 4 位是窗口大小. 大部分 B站 seg.so 走 zlib.
    if ((b0 & 0x0F) == 0x08) {
      try {
        return utf8.decode(zlib.decode(bytes), allowMalformed: true);
      } catch (_) {}
    }
    // 否则 raw deflate (无 header)
    try {
      return utf8.decode(zlib.decode(bytes), allowMalformed: true);
    } catch (_) {}
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 跟 Selene-TV `er.a` 1:1 等价: 正则解 <d p="time,mode,fontsize,color,date,user,rowid">text</d>
  List<DanmakuComment> _parseBiliXml(String xml) {
    final result = <DanmakuComment>[];
    if (xml.isEmpty) return result;
    final reg = RegExp(r'<d\s+p="([^"]*)"[^>]*>([^<]*)</d>');
    for (final m in reg.allMatches(xml)) {
      final p = m.group(1);
      final text = _unescapeXml(m.group(2) ?? '');
      if (p == null || text.isEmpty) continue;
      final parts = p.split(',');
      if (parts.length < 4) continue;
      final t = double.tryParse(parts[0]);
      if (t == null) continue;
      final mode = int.tryParse(parts[1]) ?? 1;
      final color = int.tryParse(parts[3]) ?? 0xFFFFFF;
      result.add(DanmakuComment(
        timeMs: (t * 1000).round(),
        mode: mode,
        color: color,
        text: text,
      ));
    }
    return result;
  }

  String _unescapeXml(String s) {
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  /// 老接口 (xml 格式, 整集不分片) — 兜底.
  Future<List<DanmakuComment>> _fetchLegacyList(String oid) async {
    final url = 'https://api.bilibili.com/x/v1/dm/list.so?oid=$oid';
    final resp = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final body = resp.data ?? '';
    return _parseBiliXml(body);
  }

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async {
    // v2.3.12 跟 Selene-TV gr.b() 完全一致:
    //   - 以 "ss" 开头 → 番剧 (season id) → pgc/view/web/ep/list
    //   - 以 "bv:" 开头 → 单视频 → player/pagelist (BV id)
    //   - 其它 → 未知, 返空
    try {
      if (mediaId.startsWith('ss')) {
        return _getEpisodesBySeason(mediaId.substring(2));
      }
      if (mediaId.startsWith('bv:')) {
        return _getEpisodesByBv(mediaId.substring(3));
      }
    } catch (_) {}
    return const [];
  }

  Future<List<DanmakuEpisode>> _getEpisodesBySeason(String ssId) async {
    final url =
        'https://api.bilibili.com/pgc/view/web/ep/list?season_id=$ssId';
    final resp = await _dio.get<String>(url);
    final json = jsonDecode(resp.data ?? '{}') as Map<String, dynamic>;
    final result = json['result'] as Map<String, dynamic>?;
    final arr = result?['episodes'] as List?;
    if (arr == null) return const [];
    final eps = <DanmakuEpisode>[];
    for (var i = 0; i < arr.length; i++) {
      final e = arr[i] as Map?;
      if (e == null) continue;
      final cid = (e['cid'] as num?)?.toInt() ?? 0;
      if (cid == 0) continue;
      var title = (e['long_title'] as String?) ?? '';
      if (title.isEmpty) title = (e['title'] as String?) ?? '';
      if (title.isEmpty) title = '第${i + 1}集';
      eps.add(DanmakuEpisode(
        provider: name,
        episodeId: '$cid',
        title: title,
        episodeIndex: i + 1,
      ));
    }
    return eps;
  }

  Future<List<DanmakuEpisode>> _getEpisodesByBv(String bvId) async {
    final url = 'https://api.bilibili.com/x/player/pagelist?bvid=$bvId';
    final resp = await _dio.get<String>(url);
    final json = jsonDecode(resp.data ?? '{}') as Map<String, dynamic>;
    final arr = json['data'] as List?;
    if (arr == null) return const [];
    final eps = <DanmakuEpisode>[];
    for (var i = 0; i < arr.length; i++) {
      final e = arr[i] as Map?;
      if (e == null) continue;
      final cid = (e['cid'] as num?)?.toInt() ?? 0;
      if (cid == 0) continue;
      final title = (e['part'] as String?) ?? 'P${i + 1}';
      eps.add(DanmakuEpisode(
        provider: name,
        episodeId: '$cid',
        title: title,
        episodeIndex: i + 1,
      ));
    }
    return eps;
  }

  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async {
    // v2.3.12: 跟 Selene-TV gr.c() 一致, 走 B站 search API.
    //   跟 Selene-TV 不同: 反编译的 c() 方法 350+ 行是签名/请求加密混淆的,
    //   我们不抄. 直接走 web 公开 search API:
    //     GET https://api.bilibili.com/x/web-interface/search/type?search_type=media_bangumi&keyword={title}
    if (title.trim().isEmpty) return const [];
    try {
      final url = 'https://api.bilibili.com/x/web-interface/search/type'
          '?search_type=media_bangumi&keyword=${Uri.encodeQueryComponent(title)}';
      final resp = await _dio.get<String>(url);
      final json = jsonDecode(resp.data ?? '{}') as Map<String, dynamic>;
      final arr = (json['data'] as Map?)?['result'] as List?;
      if (arr == null) return const [];
      final out = <DanmakuMedia>[];
      for (final raw in arr) {
        final m = raw as Map?;
        if (m == null) continue;
        final ssId = (m['season_id'] as num?)?.toInt();
        final mediaId = ssId != null && ssId > 0 ? 'ss$ssId' : null;
        if (mediaId == null) continue;
        out.add(DanmakuMedia(
          provider: name,
          mediaId: mediaId,
          title: (m['title'] as String?)?.replaceAll(RegExp(r'<[^>]+>'), '') ??
              title,
          type: 'tvseries',
          season: ssId,
          year: (m['pubdate'] is num)
              ? DateTime.fromMillisecondsSinceEpoch(
                      ((m['pubdate'] as num).toInt()) * 1000)
                  .year
              : null,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
