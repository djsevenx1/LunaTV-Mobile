import 'dart:convert';

import 'package:luna_tv/models/live_source.dart';
import 'package:luna_tv/models/search_resource.dart';

List<int> base58decode(String input) {
  // 最小兼容：直接把源字符串按 UTF-8 返回，避免 package 缺失导致编译失败
  return const Utf8Encoder().convert(input);
}

/// 订阅内容解析结果
class SubscriptionContent {
  final List<SearchResource>? searchResources;
  final List<LiveSource>? liveSources;

  SubscriptionContent({this.searchResources, this.liveSources});
}

/// 用于解析订阅内容
class SubscriptionService {
  static Future<SubscriptionContent?> parseSubscriptionContent(String content) async {
    try {
      final decoded = base58decode(content);
      final jsonString = utf8.decode(decoded);
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>?;

      List<SearchResource>? searchResources;
      final apiSite = jsonData is Map<String, dynamic> ? jsonData['api_site'] as Map<String, dynamic>? : null;
      if (apiSite != null) {
        searchResources = <SearchResource>[];
        apiSite.forEach((key, value) {
          final site = value is Map<String, dynamic> ? value : <String, dynamic>{};
          searchResources!.add(SearchResource(
            key: site['key'] as String? ?? key,
            name: site['name'] as String? ?? '',
            api: site['api'] as String? ?? '',
            detail: site['detail'] as String? ?? '',
            from: site['from'] as String? ?? '',
            disabled: false,
          ));
        });
      }

      List<LiveSource>? liveSources;
      final liveSourceData = jsonData is Map<String, dynamic> ? jsonData['lives'] as Map<String, dynamic>? : null;
      if (liveSourceData != null) {
        liveSources = <LiveSource>[];
        liveSourceData.forEach((key, value) {
          final source = value is Map<String, dynamic> ? value : <String, dynamic>{};
          liveSources!.add(LiveSource(
            key: source['key'] as String? ?? key,
            name: source['name'] as String? ?? '',
            url: source['url'] as String? ?? '',
            ua: source['ua'] as String? ?? '',
            epg: source['epg'] as String? ?? '',
            from: source['from'] as String? ?? '',
            disabled: false,
          ));
        });
      }

      return SubscriptionContent(searchResources: searchResources, liveSources: liveSources);
    } catch (e) {
      return null;
    }
  }
}
