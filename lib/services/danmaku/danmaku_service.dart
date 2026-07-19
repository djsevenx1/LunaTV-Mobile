// v2.3.12: 弹幕 facade — UI 层唯一入口.
//   跟 Selene-TV `defpackage.ph0` (抽象类) + 各 provider 注册机制 1:1 对齐.
//   UI 层 (player_screen.dart) 只跟 [DanmakuService] 打交道, 不直接跟
//   provider 打交道. Service 内部按 provider 顺序 fallback, 拿到非空结果
//   就返, 全空再返空 list.
//
//   跟 Selene-TV 行为一致:
//     - fetchByRange: 并发跑所有 provider, 第一个非空就用 (跟 Selene-TV
//       "lru cache hit → direct return" 等价, 我们的实现是 "first non-empty
//       wins", 用户感知一样)
//     - searchMedia: 串行跑所有 provider, 合并去重
//     - getEpisodes: 按 provider name 路由

import 'dart:async';

import 'package:luna_tv/models/danmaku_models.dart';
import 'package:luna_tv/services/danmaku/danmaku_provider.dart';
import 'package:luna_tv/services/danmaku/providers/bilibili_provider.dart';
import 'package:luna_tv/services/danmaku/providers/stub_providers.dart';

class DanmakuService {
  /// 单例 — 全 app 共用一个 service, 跟 Selene-TV `ph0.a` 单例对齐.
  static final DanmakuService instance = DanmakuService._();

  DanmakuService._();

  /// 6 个 provider, 注册顺序就是 fallback 顺序. B站排第一因为它 API 最稳定.
  /// v2.3.12: B站用真实现, 其它 5 个用 stub. 后续补全时改这里.
  final List<DanmakuProvider> _providers = [
    BilibiliDanmakuProvider(),
    TencentDanmakuProvider(),
    YoukuDanmakuProvider(),
    IqiyiDanmakuProvider(),
    MgtvDanmakuProvider(),
    LetvDanmakuProvider(),
  ];

  /// 取 [startSec]..[endSec] 之间的弹幕, 跨所有 provider 并发拉, 合并结果.
  ///
  /// v2.3.12 跟 Selene-TV `ph0.a` 行为一致: 单 provider 拿到非空就用,
  /// 不并发合并 (避免弹幕重复). 第一个能用的 provider 决定结果.
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
    String? preferredProvider,
  }) async {
    // v2.3.12: 如果用户指定了 provider, 走指定的; 否则按注册顺序挨个试.
    final order = preferredProvider != null
        ? [
            ..._providers.where((p) => p.name == preferredProvider),
            ..._providers.where((p) => p.name != preferredProvider),
          ]
        : _providers;

    for (final p in order) {
      try {
        final list = await p.fetchByRange(
          startSec: startSec,
          endSec: endSec,
          oid: oid,
        );
        if (list.isNotEmpty) return list;
      } catch (_) {
        // 单个 provider 抛异常不算致命, 继续试下一个.
        continue;
      }
    }
    return const [];
  }

  /// 按 provider 路由拿剧集列表.
  Future<List<DanmakuEpisode>> getEpisodes({
    required String provider,
    required String mediaId,
  }) async {
    final p = _providers.firstWhere(
      (p) => p.name == provider,
      orElse: () => _BilibiliFallback(),
    );
    try {
      return await p.getEpisodes(mediaId);
    } catch (_) {
      return const [];
    }
  }

  /// 跨 provider 搜, 合并去重 (按 title).
  Future<List<DanmakuMedia>> searchMedia(String title) async {
    final out = <DanmakuMedia>[];
    final seen = <String>{};
    for (final p in _providers) {
      try {
        final results = await p.searchMedia(title);
        for (final m in results) {
          if (seen.add('${m.provider}:${m.mediaId}')) out.add(m);
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// 已注册的 provider 列表 (UI 给"选择弹幕源" 下拉框用).
  List<String> get availableProviders => _providers.map((p) => p.name).toList();
}

/// 内部兜底 — 当 provider name 找不到时不抛, 走 B站 (默认).
class _BilibiliFallback implements DanmakuProvider {
  @override
  String get name => 'bilibili';
  @override
  Future<List<DanmakuComment>> fetchByRange({
    required int startSec,
    required int endSec,
    required String oid,
  }) async => const [];
  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId) async => const [];
  @override
  Future<List<DanmakuMedia>> searchMedia(String title) async => const [];
}
