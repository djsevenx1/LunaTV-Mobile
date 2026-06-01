import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:gbk_codec/gbk_codec.dart';
import '../models/search_resource.dart';
import '../models/search_result.dart';
import 'content_filter_service.dart';
import 'local_search_cache_service.dart';

/// 分页搜索结果
class SearchPageResult {
  final List<SearchResult> results;
  final int pageCount;

  SearchPageResult({
    required this.results,
    required this.pageCount,
  });
}

/// 下游搜索服务
class DownstreamService {
  /// 从指定的搜索资源API搜索
  static Future<List<SearchResult>> searchFromApi(
    SearchResource resource,
    String query,
  ) async {
    try {
      final apiBaseUrl = resource.api;
      final apiUrl =
          '$apiBaseUrl?ac=videolist&wd=${Uri.encodeComponent(query)}';

      final firstPageResult = await searchPage(
        resource: resource,
        query: query,
        page: 1,
        url: apiUrl,
      );

      final results = firstPageResult.results;
      final pageCountFromFirst = firstPageResult.pageCount;

      const maxSearchPages = 5;

      final pageCount = pageCountFromFirst;

      final pagesToFetch = (pageCount - 1) < (maxSearchPages - 1)
          ? pageCount - 1
          : maxSearchPages - 1;

      if (pagesToFetch > 0) {
        final additionalPageFutures = <Future<List<SearchResult>>>[];

        for (int page = 2; page <= pagesToFetch + 1; page++) {
          final pageUrl =
              '$apiBaseUrl?ac=videolist&wd=${Uri.encodeComponent(query)}&pg=$page';

          final pageFuture = searchPage(
            resource: resource,
            query: query,
            page: page,
            url: pageUrl,
          ).then((pageResult) => pageResult.results);

          additionalPageFutures.add(pageFuture);
        }

        final additionalResults = await Future.wait(additionalPageFutures);

        for (final pageResults in additionalResults) {
          if (pageResults.isNotEmpty) {
            results.addAll(pageResults);
          }
        }
      }

      // 过滤包含黄色关键词的结果
      final filteredResults = results.where((result) {
        return !ContentFilterService.shouldFilter(result.typeName);
      }).toList();

      return filteredResults;
    } catch (error) {
      return [];
    }
  }

  /// 清理 HTML 标签
  static String _cleanHtmlTags(String text) {
    if (text.isEmpty) return '';

    String cleanedText = text
        .replaceAll(RegExp(r'<[^>]+>'), '\n')
        .replaceAll(RegExp(r'\n+'), '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'^\n+|\n+$'), '')
        .trim();

    return _decodeHtmlEntities(cleanedText);
  }

  /// 解码 HTML 实体
  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  /// 分页搜索
  static Future<SearchPageResult> searchPage({
    required SearchResource resource,
    required String query,
    required int page,
    required String url,
  }) async {
    // 先查缓存
    final cache = LocalSearchCacheService();
    final cached = cache.getCachedSearchPage(resource.key, query, page);

    if (cached != null) {
      if (cached.status == CachedPageStatus.ok) {
        return SearchPageResult(
          results: cached.data.cast<SearchResult>(),
          pageCount: cached.pageCount ?? 1,
        );
      } else {
        return SearchPageResult(results: [], pageCount: 1);
      }
    }

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 8));

      // 检查 403 状态码，缓存 forbidden
      if (response.statusCode == 403) {
        cache.setCachedSearchPage(
          resource.key,
          query,
          page,
          CachedPageStatus.forbidden,
          [],
        );
        return SearchPageResult(results: [], pageCount: 1);
      }

      if (!response.statusCode.toString().startsWith('2')) {
        return SearchPageResult(results: [], pageCount: 1);
      }

      // 尝试从响应头获取编码
      String? charset;
      final contentType = response.headers['content-type'];
      if (contentType != null) {
        final charsetMatch = RegExp(r'charset=([^;]+)').firstMatch(contentType);
        if (charsetMatch != null) {
          charset = charsetMatch.group(1)?.toLowerCase().trim();
        }
      }

      // 根据编码解码响应体
      String responseBody;
      if (charset == 'gbk' || charset == 'gb2312') {
        // GBK/GB2312 编码
        try {
          responseBody = gbk_bytes.decode(response.bodyBytes);
        } catch (e) {
          // 如果 GBK 解码失败，尝试 UTF-8
          responseBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        }
      } else {
        // UTF-8 或其他编码
        try {
          responseBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        } catch (e) {
          // 如果 UTF-8 解码失败，尝试 GBK
          try {
            responseBody = gbk_bytes.decode(response.bodyBytes);
          } catch (e2) {
            // 都失败了，使用默认的 body
            responseBody = response.body;
          }
        }
      }

      final data = json.decode(responseBody);

      if (data == null ||
          data['list'] == null ||
          data['list'] is! List ||
          (data['list'] as List).isEmpty) {
        return SearchPageResult(results: [], pageCount: 1);
      }

      final list = data['list'] as List;

      final allResults = list.map((item) {
        List<String> episodes = [];
        List<String> titles = [];

        if (item['vod_play_url'] != null) {
          final vodPlayUrlArray =
              (item['vod_play_url'] as String).split('\$\$\$');

          for (final url in vodPlayUrlArray) {
            List<String> matchEpisodes = [];
            List<String> matchTitles = [];

            final titleUrlArray = url.split('#');

            for (final titleUrl in titleUrlArray) {
              final episodeTitleUrl = titleUrl.split('\$');
              if (episodeTitleUrl.length == 2 &&
                  episodeTitleUrl[1].endsWith('.m3u8')) {
                matchTitles.add(episodeTitleUrl[0]);
                matchEpisodes.add(episodeTitleUrl[1]);
              }
            }

            if (matchEpisodes.length > episodes.length) {
              episodes = matchEpisodes;
              titles = matchTitles;
            }
          }
        }

        String year = 'unknown';
        if (item['vod_year'] != null && item['vod_year'] != '') {
          final yearMatch =
              RegExp(r'\d{4}').firstMatch(item['vod_year'] as String);
          if (yearMatch != null) {
            year = yearMatch.group(0)!;
          }
        }

        return {
          'id': item['vod_id'].toString(),
          'title': (item['vod_name'] as String)
              .trim()
              .replaceAll(RegExp(r'\s+'), ' '),
          'poster': item['vod_pic'],
          'episodes': episodes,
          'episodes_titles': titles,
          'source': resource.key,
          'source_name': resource.name,
          'class': item['vod_class'],
          'year': year,
          'desc': _cleanHtmlTags(item['vod_content'] ?? ''),
          'type_name': item['type_name'],
          'douban_id': item['vod_douban_id'],
        };
      }).toList();

      final results = allResults
          .where((result) => (result['episodes'] as List).isNotEmpty)
          .map((result) => SearchResult.fromJson(result))
          .toList();

      final pageCount = page == 1 ? (data['pagecount'] as int? ?? 1) : 1;

      // 缓存成功的搜索结果
      cache.setCachedSearchPage(
        resource.key,
        query,
        page,
        CachedPageStatus.ok,
        results,
        pageCount: page == 1 ? pageCount : null,
      );

      return SearchPageResult(results: results, pageCount: pageCount);
    } on TimeoutException {
      // 只有超时才缓存 timeout 状态
      cache.setCachedSearchPage(
        resource.key,
        query,
        page,
        CachedPageStatus.timeout,
        [],
      );

      return SearchPageResult(results: [], pageCount: 1);
    } catch (e) {
      // 其他异常不缓存，直接返回空结果
      return SearchPageResult(results: [], pageCount: 1);
    }
  }
}
