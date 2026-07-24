// lib/danmaku/sources/youku_danmaku.dart
// 优酷弹幕源 — SeleneTV l15.java 反编译移植
//
// 协议:
//   - 搜索:  https://search.youku.com/api/search?keyword={kw}
//   - 分集:  https://openapi.youku.com/v2/shows/videos.json?client_id=53e6cc67237fc59a
//                   &package=com.huawei.hwvplayer.youku&ext=show&show_id={id}
//   - token:  https://acs.youku.com/h5/mtop.com.youku.aplatform.weakget/1.0/
//                   ?jsv=2.5.1&appKey=24679788
//             → 从 _m_h5_tk cookie 取 _ 前段
//   - 弹幕:  https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/
//             mtop 签名: md5(token + "&" + t + "&" + appKey + "&" + dataJson)
//             appKey = 24679788
//   - 分片:  1 min 一段, JSON {playat, content, propertis:{color, pos}}
//   - token 过期自刷新: ret[0] 含 TOKEN 时重试

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class YoukuDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.youku;

  static const String _appKey = '24679788';
  static const String _tokenUrl =
      'https://acs.youku.com/h5/mtop.com.youku.aplatform.weakget/1.0/'
      '?jsv=2.5.1&appKey=$_appKey';
  static const String _danmuUrl =
      'https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/';
  static const String _clientId = '53e6cc67237fc59a';

  static final Map<String, String> _getHeaders = {
    'User-Agent': 'Mozilla/5.0',
    'Referer': 'https://v.youku.com',
  };
  static final Map<String, String> _postHeaders = {
    ..._getHeaders,
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  // 跨调用共享 token, 同 session 内复用, 失效时重抓
  String? _cachedToken;
  DateTime? _tokenTime;
  // ★ Cookie 持久化: token 请求返回的 set-cookie 全部存下来,
  //   后续弹幕 POST 请求带上 Cookie 头, 否则 mtop 校验 _m_h5_tk 失败 → TOKEN_EMPTY
  String? _cachedCookies;

  Dio _newDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        headers: _getHeaders,
        responseType: ResponseType.plain,
      ));

  Future<String> _fetchToken(Dio d) async {
    try {
      final r = await d.get<String>(_tokenUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: _getHeaders,
          ));
      // 优酷回 set-cookie, 多个值是逗号串在一起 (按 RFC 6265)
      final setCookie = r.headers.map['set-cookie'];
      if (setCookie != null) {
        // ★ 收集所有 cookie, 拼成 "k1=v1; k2=v2" 格式存下来
        final cookieParts = <String>[];
        String? token;
        for (final raw in setCookie) {
          for (final part in raw.split(',')) {
            final kv = part.trim().split(';').first.trim();
            final eq = kv.indexOf('=');
            if (eq <= 0) continue;
            final name = kv.substring(0, eq);
            final value = kv.substring(eq + 1);
            cookieParts.add(kv);
            if (name == '_m_h5_tk') {
              token = value.split('_').first;
            }
          }
        }
        if (cookieParts.isNotEmpty) {
          _cachedCookies = cookieParts.join('; ');
        }
        if (token != null) {
          debugPrint('[Youku] token fetched: '
              '${token.substring(0, token.length.clamp(0, 8))}... '
              'cookies=${cookieParts.length}');
          return token;
        }
      }
      debugPrint('[Youku] token fetch: no _m_h5_tk in cookies, '
          'set-cookie=${setCookie?.length ?? 0} entries');
    } catch (e) {
      debugPrint('[Youku] token fetch error: $e');
    }
    return '';
  }

  Future<String> _ensureToken(Dio d) async {
    if (_cachedToken != null && _tokenTime != null) {
      if (DateTime.now().difference(_tokenTime!).inMinutes < 25) {
        return _cachedToken!;
      }
    }
    final t = await _fetchToken(d);
    if (t.isNotEmpty) {
      _cachedToken = t;
      _tokenTime = DateTime.now();
    }
    return t;
  }

  String _md5Sign(String token, String t, String data) {
    final input = '$token&$t&$_appKey&$data';
    return md5.convert(utf8.encode(input)).toString();
  }

  @override
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio}) async {
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      final url = 'https://search.youku.com/api/search?keyword=' +
          Uri.encodeQueryComponent(keyword);
      final r = await d.get<String>(url,
          options: Options(headers: _getHeaders));
      if (r.data == null || r.data!.isEmpty) return [];
      final root = json.decode(r.data!);
      if (root is! Map) return [];
      final pages = root['pageComponentList'];
      if (pages is! List) return [];
      final out = <DanmakuMedia>[];
      final yearRe = RegExp(r'(\d{4})');
      for (final p in pages) {
        if (p is! Map) continue;
        final common = p['commonData'];
        if (common is! Map) continue;
        final isYk = (common['isYouku'] is num)
            ? (common['isYouku'] as num).toInt() == 1
            : false;
        if (!isYk) continue;
        final feature = common['feature']?.toString() ?? '';
        final year =
            int.tryParse(yearRe.firstMatch(feature)?.group(0) ?? '');
        var showId = common['realShowId']?.toString() ?? '';
        if (showId.isEmpty) {
          showId = common['showId']?.toString() ?? '';
        }
        if (showId.isEmpty) continue;
        final titleDto = common['titleDTO'];
        final title = (titleDto is Map)
            ? (titleDto['displayName']?.toString() ?? '')
            : '';
        out.add(DanmakuMedia(
          source: sourceEnum,
          mediaId: showId,
          title: title,
          type: feature.contains('电影') ? 'movie' : 'tv',
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
      final url = 'https://openapi.youku.com/v2/shows/videos.json'
          '?client_id=$_clientId'
          '&package=com.huawei.hwvplayer.youku'
          '&ext=show&show_id=$mediaId';
      final r = await d.get<String>(url,
          options: Options(headers: _getHeaders));
      if (r.data == null || r.data!.isEmpty) return [];
      final root = json.decode(r.data!);
      if (root is! Map) return [];
      final videos = root['videos'];
      if (videos is! List) return [];
      return videos.map<DanmakuEpisode>((v) {
        final m = v is Map ? v : const {};
        final durStr = m['duration']?.toString() ?? '0';
        final dur = (double.tryParse(durStr) ?? 0).ceil();
        var seqStr = m['seq']?.toString() ?? '';
        if (seqStr.isEmpty) seqStr = m['stage']?.toString() ?? '';
        final seq = int.tryParse(seqStr) ?? 0;
        final id = m['id']?.toString() ?? '';
        // 关键: videoId|时长 拼起来, 拉弹幕时 split
        final epId = '$id|$dur';
        var title = m['title']?.toString() ?? '';
        if (title.isEmpty) title = '第${m['stage']}集';
        return DanmakuEpisode(
          source: sourceEnum,
          episodeId: epId,
          order: seq,
          title: title,
        );
      }).where((e) => e.episodeId.split('|').first.isNotEmpty).toList();
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
    if (episodeId.isEmpty || !episodeId.contains('|')) return [];
    final parts = episodeId.split('|');
    final vid = parts[0];
    final totalSec = int.tryParse(parts[1]) ?? 0;
    if (vid.isEmpty) return [];
    final d = dio ?? _newDio();
    final own = dio == null;
    try {
      final totalSegs = totalSec > 0 ? (totalSec / 60.0).ceil() : 1;
      final startSeg = startSec > 0 ? (startSec / 60).floor() + 1 : 1;
      final endSeg = endSec > 0
          ? (endSec / 60.0).ceil().clamp(1, totalSegs)
          : totalSegs;
      if (startSeg > endSeg) return [];

      final all = <DanmakuComment>[];
      int emptyCount = 0;
      for (var seg = startSeg; seg <= endSeg; seg++) {
        final arr = await _fetchSegment(d, vid, seg, retry: false);
        if (arr.isEmpty) {
          emptyCount++;
          if (seg == 1) {
            debugPrint('[Youku] seg1 empty, vid=$vid totalSegs=$totalSegs');
          }
          // ★ 连续 3 段空 = 越界, break (避免 45+ 段死循环)
          if (emptyCount >= 3) break;
          continue;
        }
        emptyCount = 0;
        for (var i = 0; i < arr.length; i++) {
          final item = arr[i];
          if (item is! Map) continue;
          String propStr = item['propertis']?.toString() ?? '{}';
          Map prop = const {};
          try {
            prop = json.decode(propStr) as Map? ?? const {};
          } catch (_) {}
          final color = (prop['color'] is num)
              ? (prop['color'] as num).toInt()
              : 0xFFFFFF;
          int pos;
          switch (
              (prop['pos'] is num) ? (prop['pos'] as num).toInt() : 1) {
            case 4:
              pos = 4;
              break;
            case 5:
              pos = 5;
              break;
            default:
              pos = 1;
          }
          final playat =
              (item['playat'] is num) ? (item['playat'] as num).toInt() : 0;
          final content = item['content']?.toString() ?? '';
          if (content.isEmpty) continue;
          all.add(DanmakuComment(
            timeMs: playat,
            mode: pos,
            color: color,
            content: content,
          ));
        }
      }
      return all;
    } finally {
      if (own) d.close(force: true);
    }
  }

  // 拉单片, 失败 + token 过期时重试 1 次
  Future<List<dynamic>> _fetchSegment(
      Dio d, String vid, int seg, {bool retry = false}) async {
    try {
      final t = DateTime.now().millisecondsSinceEpoch.toString();
      final data = json.encode({'vid': vid, 'mat': seg});
      final token = await _ensureToken(d);
      if (token.isEmpty) {
        debugPrint('[Youku] _fetchSegment seg$seg: no token');
        return const [];
      }
      final sign = _md5Sign(token, t, data);
      final queryStr = '?jsv=2.7.0&appKey=$_appKey'
          '&t=$t&sign=$sign'
          '&api=mopen.youku.danmu.list&v=1.0'
          '&type=originaljson&dataType=jsonp&timeout=20000';
      final body = 'data=${Uri.encodeQueryComponent(data)}';
      final r = await d.post<String>(
        _danmuUrl + queryStr,
        data: body,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            ..._postHeaders,
            // ★ 带上 token 请求获取的 cookie, mtop 校验 _m_h5_tk
            if (_cachedCookies != null) 'Cookie': _cachedCookies,
          },
        ),
      );
      if (r.data == null || r.data!.isEmpty) return const [];
      final root = json.decode(r.data!);
      if (root is! Map) return const [];
      final ret = root['ret'];
      String ret0 = '';
      if (ret is List && ret.isNotEmpty) ret0 = ret[0]?.toString() ?? '';
      // ★ 优酷 ret 格式: "SUCCESS::调用成功" 或 "FAIL_SYS_XXX::xxx"
      //   不能用 == 'SUCCESS', 用 startsWith 匹配
      if (ret0.startsWith('SUCCESS')) {
        final dataObj = root['data'];
        if (dataObj is! Map) return const [];
        final resultStr = dataObj['result']?.toString() ?? '';
        if (resultStr.isEmpty) return const [];
        final result = json.decode(resultStr);
        if (result is! Map) return const [];
        final inner = result['data'];
        if (inner is! Map) return const [];
        final arr = inner['result'];
        if (arr is List) return arr;
        return const [];
      }
      debugPrint('[Youku] seg$seg ret=$ret0 (retry=$retry)');
      if (!retry && ret0.contains('TOKEN')) {
        _cachedToken = null;
        _tokenTime = null;
        _cachedCookies = null; // 清 cookie, 重新走 token 流程
        return _fetchSegment(d, vid, seg, retry: true);
      }
      return const [];
    } catch (e) {
      debugPrint('[Youku] _fetchSegment seg$seg exception: $e');
      return const [];
    }
  }
}
