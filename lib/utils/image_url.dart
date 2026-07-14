// 通用图片地址处理工具
import 'package:luna_tv/services/user_data_service.dart';

/// 升级豆瓣图片 URL 到更高分辨率（用于大图展示场景如 Hero Banner）。
///
/// 豆瓣 `/view/photo/...` 路径里尺寸标识决定返回尺寸：
/// - `s_ratio_poster` → 约 200×300（小）
/// - `m_ratio_poster` → 约 400×600（中）
/// - `l_ratio_poster` → 约 600×900（大，公开图最大）
///
/// ⚠️ `raw` 是私有原图, 仅登录用户可访问, 公开图请求会 404/403,
///    导致轮播图整张不显示。**不要用 raw**。
///
/// 默认源数据一般给的是 `s_/m_`, 用于轮播大图 (2K 宽 × 500) 会糊,
/// 但 l_ratio_poster 是公开图最大尺寸, 没得选。
String _upgradeDoubanPosterUrl(String url) {
  // 把 ratio_poster 前的小/中尺寸升级到大尺寸
  return url
      .replaceFirst('s_ratio_poster', 'l_ratio_poster')
      .replaceFirst('m_ratio_poster', 'l_ratio_poster')
      .replaceFirst('photo/s', 'photo/l')
      .replaceFirst('photo/m', 'photo/l');
}

/// v2.0.84: 升级豆瓣 16:9 横版 cover (剧照/预告片) URL 到 l_cover (1280x720)
///
/// 豆瓣 `/view/photo/...` 路径里 cover 尺寸标识:
/// - `s_cover` → 约 320×180 (小横版)
/// - `m_cover` → 约 640×360 (中横版)
/// - `l_cover` → 约 1280×720 (大横版, 公开图最大)
///
/// 默认 rexxar API 给的 `cover_url` 一般是 `m_cover`, 平板/详情页大头部
/// 缩到 1024+ 宽就糊了. 升级到 `l_cover` 后 1280x720 平板 2K 屏都不糊.
///
/// 参考: 豆瓣 iPad app "剧照" 区 / 详情页 banner / Web 端 hero 用的就是这个
///   l_cover 尺寸 (公开图最大, 无需登录)
String _upgradeDoubanCoverUrl(String url) {
  return url
      .replaceFirst('s_cover', 'l_cover')
      .replaceFirst('m_cover', 'l_cover');
}

/// 根据来源处理图片 URL（例如豆瓣域名替换）。
/// - [originalUrl]: 原始图片地址
/// - [source]: 数据来源（如 'douban'、'bangumi' 等）
/// - [upgradeDouban]: 是否升级豆瓣图为高分辨率（默认 false，用于小卡片）；
///   设为 true 适用于 Hero Banner 等大图展示场景。
///   **v2.0.77**：用户登录豆瓣后(cookie 有效),自动按 `upgradeDouban: true` 处理,
///   即把 `s_/m_ratio_poster` 升级到 `l_ratio_poster` (公开图最大尺寸, 约 600×900)。
///   未登录则保持调用方传入的默认行为,不影响现有体验。
/// 返回可直接用于加载的图片地址。
Future<String> getImageUrl(
  String originalUrl,
  String? source, {
  bool upgradeDouban = false,
}) async {
  if (source == 'douban' && originalUrl.isNotEmpty) {
    final imageSourceKey = await UserDataService.getDoubanImageSourceKey();

    // v2.0.77: 登录豆瓣后, 任何位置都自动升级到高清 l_ratio_poster
    final bool shouldUpgrade =
        upgradeDouban || UserDataService.isDoubanLoggedIn();
    String processed = originalUrl;
    if (shouldUpgrade) {
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
  // v2.1.25: TMDB 图片 URL 走 CF Worker 加速 (跟 Bangumi 平行).
  // 之前 v2.0.94 ~ v2.1.24 是 [TmdbService.fetchArt] 内部 wrap 的,
  // v2.1.25 改回返原始 image.tmdb.org URL, 消费者 (这里 + douban_detail_header)
  // 统一调 [UserDataService.buildTmdbImageUrl] 走包装.
  // 跟 Bangumi 区别: TMDB 没有 'cors_proxy' 选项, 只有 'cf_worker' / 'direct' / 'off'.
  if (source == 'tmdb' && originalUrl.isNotEmpty) {
    return UserDataService.buildTmdbImageUrl(originalUrl);
  }
  return originalUrl;
}

/// v2.0.84: 豆瓣 16:9 横版 cover_url 处理器 (跟 [getImageUrl] 类似, 但升级到
///   l_cover 1280x720 横版, 平板/详情页大头部用). 返回可直接加载的 URL.
///
/// 升级策略: **永远升级** 到 l_cover (公开图最大, 320x180/640x360 -> 1280x720),
///   不需要登录. 默认 rexxar API 给的 `cover_url` 是 m_cover (640x360),
///   平板缩到 1024+ 宽会糊, l_cover 1280x720 平板 2K 屏不糊.
///
/// CDN 切换跟 [getImageUrl] 一致 (official_cdn / cdn_tencent / cdn_aliyun / direct).
Future<String> getDoubanCoverUrl(String coverUrl) async {
  if (coverUrl.isEmpty) return coverUrl;
  final imageSourceKey = await UserDataService.getDoubanImageSourceKey();
  String processed = _upgradeDoubanCoverUrl(coverUrl);
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
    final Map<String, String> headers = <String, String>{
      'Referer': 'https://movie.douban.com/',
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    };
    // v2.0.77: 已登录豆瓣时携带 cookie, 拉 l_ratio_poster 公开图(无需 cookie)
    // 也带上, 部分高分辨率/防盗链场景会用到登录态
    final String? cookie = UserDataService.getDoubanCookieSync();
    if (cookie != null && cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }

  // Bangumi 图片服务器 lain.bgm.tv 需要 User-Agent + Referer
  // 全 URL 搜 bgm.tv,避免被代理后 URL 域名变成 workers.dev 而漏检
  final bool isBangumiSource = (source == 'bangumi') ||
      imageUrl.toLowerCase().contains('bgm.tv');
  if (isBangumiSource) {
    final Map<String, String> headers = {
      // lain.bgm.tv 和 api.bgm.tv 都吃 bgm.tv v0 API 同款
      // "App/Version (URL)" UA 格式,Chrome UA 反而会 403
      'User-Agent':
          'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
      'Referer': 'https://bgm.tv/',
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    };
    // v2.0.12: ciao-cors 代理 Bangumi 图片时必须带 X-Requested-With,
    // 否则新 API (path 拼接) 会 403
    if (imageUrl.contains(UserDataService.publicCorsProxyBase)) {
      headers['X-Requested-With'] = 'XMLHttpRequest';
    }
    return headers;
  }

  return null;
}


