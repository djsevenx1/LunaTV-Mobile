// 通用图片地址处理工具
//
// v2.1.42 改: Bangumi 分支调 [UserDataService.buildBangumiImageUrl], 内部
//   按 Bangumi 图片源是不是 'bangumi_proxy' + 配 worker URL, 是的话
//   wrap 成 path-based worker URL (例: https://lain.bgm.tv/img/.../abc.jpg
//   → https://your-worker.example.com/bgm-img/img/.../abc.jpg).
// v2.1.41 改: TMDB 分支调 [UserDataService.buildTmdbImageUrl], 内部
//   看 TMDB 数据源是不是 'tmdb_proxy' + 配 worker URL, 是的话 wrap
//   成 path-based worker URL. 没配/没选 → 1:1 返原 URL.
// v2.1.40 改: 删 TMDB / Bangumi 加速代码 (CF Worker 探测 / ciao-cors 包装
//   / worker 健康检查) 整段, 一律直连. Douban 加速保留 (CDN 切换 / 高清升级
//   不是 TMDB/Bangumi 加速, 用户没让删, 也不属于本次任务范围).
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
///
/// v2.1.40 改: TMDB / Bangumi 分支只做 http→https 升级, 不再 wrap 加速 URL.
///   [UserDataService.buildBangumiImageUrl] / [buildTmdbImageUrl] 现在是
///   1:1 返原 URL 的 passthrough (加速删了). 这里手动走 https 升级跟
///   v2.0.74 之前的行为对齐. 删了 CF Worker 健康探测 / 30s 缓存整段.
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
  // v2.1.42: Bangumi 图片 URL 调 [UserDataService.buildBangumiImageUrl],
  //   内部按当前 Bangumi 图片源选择 + worker URL 配置决定是否走
  //   path-based worker 加速 (例: https://lain.bgm.tv/img/.../abc.jpg →
  //   https://your-worker.example.com/bgm-img/img/.../abc.jpg). 老 v2.1.40
  //   直连逻辑保留 (没选 bangumi_proxy 或没配 worker URL 时 1:1 返).
  if (source == 'bangumi' && originalUrl.isNotEmpty) {
    return UserDataService.buildBangumiImageUrl(originalUrl);
  }
  // v2.1.41: TMDB 图片 URL 调 [UserDataService.buildTmdbImageUrl], 内部
  //   按当前 TMDB 数据源选择 + worker URL 配置决定是否走 path-based
  //   worker 加速 (例: https://image.tmdb.org/t/p/w1280/abc.jpg →
  //   https://your-worker.example.com/image/t/p/w1280/abc.jpg). 老 v2.1.40
  //   直连逻辑保留 (没选 tmdb_proxy 或没配 worker URL 时 1:1 返).
  if (source == 'tmdb' && originalUrl.isNotEmpty) {
    return UserDataService.buildTmdbImageUrl(originalUrl);
  }
  // v2.5.28: 短剧图片走 worker /sd-img?url= 代理 (复用 TMDB proxy worker URL).
  //   没配 worker URL → 1:1 返原 URL (直连 TVBox 源图床).
  if (source == 'shortdrama' && originalUrl.isNotEmpty) {
    return UserDataService.buildShortDramaImageUrl(originalUrl);
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
/// v2.1.40 改: 删 ciao-cors 代理的 X-Requested-With 注入分支 (加速删了
///   ciao-cors 不会再出现). 保留 douban cookie 注入 / bgm.tv Referer+UA
///   等反盗链处理.
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
  // v2.1.40: 删 ciao-cors X-Requested-With 分支 (加速没了, 不会再走代理 URL).
  final bool isBangumiSource = (source == 'bangumi') ||
      imageUrl.toLowerCase().contains('bgm.tv');
  if (isBangumiSource) {
    return {
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
