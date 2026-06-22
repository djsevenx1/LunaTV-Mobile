// 通用图片地址处理工具
import 'package:luna_tv/services/user_data_service.dart';

/// 升级豆瓣图片 URL 到更高分辨率（用于大图展示场景如 Hero Banner）。
///
/// 豆瓣 `/view/photo/...` 路径里 `s_` / `m_` / `l_` 决定返回尺寸：
/// - s_ratio_poster  → 约 200×300（小）
/// - m_ratio_poster  → 约 400×600（中）
/// - l_ratio_poster  → 约 600×900（大）
/// 默认源数据一般只给 `s_`，直接用于轮播大图会模糊。
String _upgradeDoubanPosterUrl(String url) {
  // 把 ratio_poster 前的小/中尺寸升级到大尺寸
  return url
      .replaceFirst('s_ratio_poster', 'l_ratio_poster')
      .replaceFirst('m_ratio_poster', 'l_ratio_poster')
      .replaceFirst('photo/s', 'photo/l')
      .replaceFirst('photo/m', 'photo/l');
}

/// 根据来源处理图片 URL（例如豆瓣域名替换）。
/// - [originalUrl]: 原始图片地址
/// - [source]: 数据来源（如 'douban'、'bangumi' 等）
/// - [upgradeDouban]: 是否升级豆瓣图为高分辨率（默认 false，用于小卡片）；
///   设为 true 适用于 Hero Banner 等大图展示场景。
/// 返回可直接用于加载的图片地址。
Future<String> getImageUrl(
  String originalUrl,
  String? source, {
  bool upgradeDouban = false,
}) async {
  if (source == 'douban' && originalUrl.isNotEmpty) {
    final imageSourceKey = await UserDataService.getDoubanImageSourceKey();

    String processed = originalUrl;
    if (upgradeDouban) {
      processed = _upgradeDoubanPosterUrl(processed);
    }

    switch (imageSourceKey) {
      case 'official_cdn':
        return processed.replaceAll(
          RegExp(r'img\d+\.doubanio\.com'),
          'img3.doubanio.com',
        );
      case 'cdn_tencent':
        return processed.replaceAll(
          RegExp(r'img\d+\.doubanio\.com'),
          'img.doubanio.cmliussss.net',
        );
      case 'cdn_aliyun':
        return processed.replaceAll(
          RegExp(r'img\d+\.doubanio\.com'),
          'img.doubanio.cmliussss.com',
        );
      case 'direct':
      default:
        return processed;
    }
  }
  // Bangumi 图片 URL 统一使用 HTTPS,优先走 CF Worker 加速
  if (source == 'bangumi' && originalUrl.isNotEmpty) {
    String processed = originalUrl;
    if (processed.startsWith('//')) {
      processed = 'https:$processed';
    } else {
      processed = processed.replaceFirst('http://', 'https://');
    }
    // CF Worker 加速:开关+域名就生效,否则按用户选择走直连
    return UserDataService.buildBangumiImageUrl(processed);
  }
  return originalUrl;
}

/// 返回加载网络图片所需的 HTTP 头（主要用于绕过特定站点的反盗链）。
/// 注意：只有当 [source] 为 'douban' 或 URL 指向 douban 域名时才添加 Referer/UA。
/// bangumi 源（lain.bgm.tv）需要 UA + Referer，否则图片请求会被拒绝。
///
/// 重要：原始 URL 可能是被 CF Worker / ciao-cors 代理过的
/// (形如 https://xx.workers.dev/?url=https%3A%2F%2Flain.bgm.tv%2F...),
/// 所以判断 bgm.tv 时要全 URL 搜,不能只匹配域名段。
Map<String, String>? getImageRequestHeaders(String imageUrl, String? source) {
  final bool isDoubanSource = (source == 'douban') ||
      RegExp(r'https?://([^/]+\.)?douban(io|)\.com', caseSensitive: false)
          .hasMatch(imageUrl);

  if (isDoubanSource) {
    // 常见可用的 Referer 和 UA，避免 403 或 Android 解码失败
    return <String, String>{
      'Referer': 'https://movie.douban.com/',
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    };
  }

  // Bangumi 图片服务器 lain.bgm.tv 需要 User-Agent + Referer
  // 全 URL 搜 bgm.tv,避免被代理后 URL 域名变成 workers.dev 而漏检
  final bool isBangumiSource = (source == 'bangumi') ||
      imageUrl.toLowerCase().contains('bgm.tv');
  if (isBangumiSource) {
    return <String, String>{
      // lain.bgm.tv 和 api.bgm.tv 都吃 bgm.tv v0 API 同款
      // "App/Version (URL)" UA 格式,Chrome UA 反而会 403
      'User-Agent':
          'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
      'Referer': 'https://bgm.tv/',
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    };
  }

  return null;
}


