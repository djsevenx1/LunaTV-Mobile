import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserDataService {
  static const String _serverUrlKey = 'server_url';
  static const String _usernameKey = 'username';
  static const String _passwordKey = 'password';
  static const String _cookiesKey = 'cookies';
  static const String _doubanDataSourceKey = 'douban_data_source';
  static const String _doubanImageSourceKey = 'douban_image_source';
  static const String _bangumiDataSourceKey = 'bangumi_data_source';
  static const String _bangumiImageSourceKey = 'bangumi_image_source';
  static const String _m3u8ProxyUrlKey = 'm3u8_proxy_url';
  static const String _preferSpeedTestKey = 'prefer_speed_test';
  static const String _localSearchKey = 'local_search';
  static const String _isLocalModeKey = 'is_local_mode';
  static const String _cfWorkerEnabledKey = 'cf_worker_enabled';
  static const String _cfWorkerDomainKey = 'cf_worker_domain';
  static const String _videoProxyEnabledKey = 'video_proxy_enabled';
  // v2.0.31: 用户手动填的优选 IP, 优先级高于测速结果
  static const String _cfBestIpKey = 'cf_best_ip';
  // v2.0.35: TMDB API Key (v3 auth), 留空 = 关闭 TMDB 海报墙, 有 = 首页 2 个
  //   section (热门电影 / 热门剧集) 自动切 TMDB 横滚海报墙 + 评分
  //   申请地址 https://www.themoviedb.org/settings/api (免费, 立即审核)
  static const String _tmdbApiKeyKey = 'tmdb_api_key';

  // 内存缓存
  static bool? _isLocalModeCache;
  static bool? _cfWorkerEnabledCache;
  static String? _cfWorkerDomainCache;
  static bool? _videoProxyEnabledCache;
  static String? _bangumiDataSourceCache;
  static String? _bangumiImageSourceCache;
  static String? _cfBestIpCache;
  // v2.0.35
  static String? _tmdbApiKeyCache;
  // v2.0.41: TMDB key 变化通知器, 配 / 清 key 时 .value = cleaned 通知所有监听 widget rebuild
  //
  // 背景: 之前只有 static String? _tmdbApiKeyCache, home_screen build 时调
  //   isTmdbPosterWallEnabled() 拿一次快照. 配 / 清 key 时 cache 被 saveTmdbApiKey
  //   同步更新, 但 HomeScreen 在 user_menu 之下, 不会感知 cache 变化, rebuild
  //   不触发, 仍显示原 HotMoviesSection / HotTvSection, 用户看不到海报墙.
  //
  // 修法: ValueNotifier<String?> 替代裸 String? 字段. saveTmdbApiKey 时
  //   notifier.value = cleaned, 监听它的 ValueListenableBuilder 自动 rebuild.
  //   home_screen _buildHomeTabContent 用 ValueListenableBuilder<String?>(valueListenable:
  //   UserDataService.tmdbApiKeyNotifier) 包住 2 个 TMDB section, 配 key 立即看到海报墙.
  static final ValueNotifier<String?> tmdbApiKeyNotifier =
      ValueNotifier<String?>(_tmdbApiKeyCache);

  // 保存用户登录信息
  static Future<void> saveUserData({
    required String serverUrl,
    required String username,
    required String password,
    required String cookies,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, serverUrl);
    await prefs.setString(_usernameKey, username);
    await prefs.setString(_passwordKey, password);
    await prefs.setString(_cookiesKey, cookies);
  }

  // 获取服务器地址
  static Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrlKey);
  }

  // 获取用户名
  static Future<String?> getUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  // 获取密码
  static Future<String?> getPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_passwordKey);
  }

  // 获取cookies
  static Future<String?> getCookies() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cookiesKey);
  }

  // 检查是否已登录
  static Future<bool> isLoggedIn() async {
    final cookies = await getCookies();
    return cookies != null && cookies.isNotEmpty;
  }

  // 清除用户数据
  static Future<void> clearUserData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrlKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);
    await prefs.remove(_cookiesKey);
  }

  // 只清除密码和cookies，保留服务器地址和用户名
  static Future<void> clearPasswordAndCookies() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_passwordKey);
    await prefs.remove(_cookiesKey);
  }

  // 获取所有用户数据
  static Future<Map<String, String?>> getAllUserData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'serverUrl': prefs.getString(_serverUrlKey),
      'username': prefs.getString(_usernameKey),
      'password': prefs.getString(_passwordKey),
      'cookies': prefs.getString(_cookiesKey),
    };
  }

  // 检查是否具有自动登录所需的所有字段
  static Future<bool> hasAutoLoginData() async {
    final serverUrl = await getServerUrl();
    final username = await getUsername();
    final password = await getPassword();
    
    return serverUrl != null && 
           serverUrl.isNotEmpty && 
           username != null && 
           username.isNotEmpty && 
           password != null && 
           password.isNotEmpty;
  }

  // 保存豆瓣数据源设置（存储key值）
  static Future<void> saveDoubanDataSource(String dataSourceDisplayName) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDoubanDataSourceKeyFromDisplayName(dataSourceDisplayName);
    await prefs.setString(_doubanDataSourceKey, key);
  }

  // 获取豆瓣数据源设置（返回key值）
  static Future<String> getDoubanDataSourceKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_doubanDataSourceKey) ?? 'direct';
  }

  // 获取豆瓣数据源显示名称
  static Future<String> getDoubanDataSourceDisplayName() async {
    final key = await getDoubanDataSourceKey();
    return _getDoubanDataSourceDisplayNameFromKey(key);
  }

  // 保存豆瓣图片源设置（存储key值）
  static Future<void> saveDoubanImageSource(String imageSourceDisplayName) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDoubanImageSourceKeyFromDisplayName(imageSourceDisplayName);
    await prefs.setString(_doubanImageSourceKey, key);
  }

  // 获取豆瓣图片源设置（返回key值）
  static Future<String> getDoubanImageSourceKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_doubanImageSourceKey) ?? 'direct';
  }

  // 获取豆瓣图片源显示名称
  static Future<String> getDoubanImageSourceDisplayName() async {
    final key = await getDoubanImageSourceKey();
    return _getDoubanImageSourceDisplayNameFromKey(key);
  }

  // 根据显示名称获取豆瓣数据源的key值（私有方法）
  static String _getDoubanDataSourceKeyFromDisplayName(String dataSource) {
    switch (dataSource) {
      case '直连':
        return 'direct';
      case 'Cors Proxy By Zwei':
        return 'cors_proxy';
      case '豆瓣 CDN By CMLiussss（腾讯云）':
        return 'cdn_tencent';
      case '豆瓣 CDN By CMLiussss（阿里云）':
        return 'cdn_aliyun';
      default:
        return 'direct';
    }
  }

  // 根据显示名称获取豆瓣图片源的key值（私有方法）
  static String _getDoubanImageSourceKeyFromDisplayName(String imageSource) {
    switch (imageSource) {
      case '直连':
        return 'direct';
      case '豆瓣官方精品 CDN':
        return 'official_cdn';
      case '豆瓣 CDN By CMLiussss（腾讯云）':
        return 'cdn_tencent';
      case '豆瓣 CDN By CMLiussss（阿里云）':
        return 'cdn_aliyun';
      default:
        return 'direct';
    }
  }

  // 根据key值获取豆瓣数据源显示名称（私有方法）
  static String _getDoubanDataSourceDisplayNameFromKey(String key) {
    switch (key) {
      case 'direct':
        return '直连';
      case 'cors_proxy':
        return 'Cors Proxy By Zwei';
      case 'cdn_tencent':
        return '豆瓣 CDN By CMLiussss（腾讯云）';
      case 'cdn_aliyun':
        return '豆瓣 CDN By CMLiussss（阿里云）';
      default:
        return '直连';
    }
  }

  // 根据key值获取豆瓣图片源显示名称（私有方法）
  static String _getDoubanImageSourceDisplayNameFromKey(String key) {
    switch (key) {
      case 'direct':
        return '直连';
      case 'official_cdn':
        return '豆瓣官方精品 CDN';
      case 'cdn_tencent':
        return '豆瓣 CDN By CMLiussss（腾讯云）';
      case 'cdn_aliyun':
        return '豆瓣 CDN By CMLiussss（阿里云）';
      default:
        return '直连';
    }
  }

  // 保存 M3U8 代理 URL
  static Future<void> saveM3u8ProxyUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_m3u8ProxyUrlKey, url);
  }

  // 获取 M3U8 代理 URL
  static Future<String> getM3u8ProxyUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_m3u8ProxyUrlKey) ?? '';
  }

  // 保存优选测速设置
  static Future<void> savePreferSpeedTest(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preferSpeedTestKey, enabled);
  }

  // 获取优选测速设置（默认为 true）
  static Future<bool> getPreferSpeedTest() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_preferSpeedTestKey) ?? true;
  }

  // 保存本地搜索设置
  static Future<void> saveLocalSearch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_localSearchKey, enabled);
  }

  // 获取本地搜索设置（默认为 false）
  static Future<bool> getLocalSearch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_localSearchKey) ?? false;
  }

  // 保存本地模式设置
  static Future<void> saveIsLocalMode(bool isLocalMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isLocalModeKey, isLocalMode);
    _isLocalModeCache = isLocalMode; // 同步更新内存缓存
  }

  // 获取本地模式设置（默认为 false）
  static Future<bool> getIsLocalMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_isLocalModeKey) ?? false;
    _isLocalModeCache = value; // 缓存到内存
    return value;
  }
  
  // 同步获取本地模式设置（从内存缓存读取）
  static bool getIsLocalModeSync() {
    return _isLocalModeCache ?? false;
  }

  // 兼容旧接口:保存服务器地址
  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
  }

  // 兼容旧接口:获取豆瓣数据源
  static Future<String?> getDoubanDataSource() async {
    return getDoubanDataSourceKey();
  }

  // 兼容旧接口:设置豆瓣数据源
  static Future<void> setDoubanDataSource(String source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_doubanDataSourceKey, source);
  }

  // 兼容旧接口:获取豆瓣图片源
  static Future<String?> getDoubanImageSource() async {
    return getDoubanImageSourceKey();
  }

  // 兼容旧接口:设置豆瓣图片源
  static Future<void> setDoubanImageSource(String source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_doubanImageSourceKey, source);
  }

  // 兼容旧接口:设置 M3U8 代理 URL
  static Future<void> setM3u8ProxyUrl(String url) async {
    await saveM3u8ProxyUrl(url);
  }

  // 兼容旧接口:设置优选测速
  static Future<void> setPreferSpeedTest(bool enabled) async {
    await savePreferSpeedTest(enabled);
  }

  // ===== CF Worker 加速配置 =====

  // 保存 CF Worker 加速开关
  static Future<void> saveCfWorkerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cfWorkerEnabledKey, enabled);
    _cfWorkerEnabledCache = enabled;
  }

  // 获取 CF Worker 加速开关（默认 false）
  static Future<bool> getCfWorkerEnabled() async {
    if (_cfWorkerEnabledCache != null) return _cfWorkerEnabledCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_cfWorkerEnabledKey) ?? false;
    _cfWorkerEnabledCache = v;
    return v;
  }

  // 同步获取 CF Worker 开关
  static bool getCfWorkerEnabledSync() {
    return _cfWorkerEnabledCache ?? false;
  }

  // v2.0.27: 视频代理开关 (默认 false — 视频直连, 不走 Dart Socket 代理)
  // 用户想通过优选 IP 加速视频时手动开, 开了之后视频走 VideoProxyServer
  static Future<void> saveVideoProxyEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_videoProxyEnabledKey, enabled);
  }

  static Future<bool> getVideoProxyEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_videoProxyEnabledKey) ?? false;
  }

  // 保存 CF Worker 域名（不含 https:// 前缀）
  static Future<void> saveCfWorkerDomain(String domain) async {
    final cleaned = _cleanDomain(domain);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cfWorkerDomainKey, cleaned);
    _cfWorkerDomainCache = cleaned;
  }

  // 获取 CF Worker 域名（同步版，优先内存缓存）
  static String getCfWorkerDomainSync() {
    return _cfWorkerDomainCache ?? '';
  }

  // 获取 CF Worker 域名（异步版）
  static Future<String> getCfWorkerDomain() async {
    if (_cfWorkerDomainCache != null) return _cfWorkerDomainCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_cfWorkerDomainKey) ?? '';
    _cfWorkerDomainCache = v;
    return v;
  }

  // ===== v2.0.32: 手动优选 (支持 IP 或优选域名, 例如 cf.877774.xyz) =====

  /// 保存用户手动填的优选 IP / 域名. 空串 = 清空.
  /// 返回清理后的字符串, null 表示输入无效.
  static Future<String?> saveCfBestIp(String input) async {
    final cleaned = _cleanIpOrDomain(input);
    final prefs = await SharedPreferences.getInstance();
    if (cleaned == null) {
      await prefs.remove(_cfBestIpKey);
    } else {
      await prefs.setString(_cfBestIpKey, cleaned);
    }
    _cfBestIpCache = cleaned;
    return cleaned;
  }

  /// 异步读优选 IP / 域名. 没填 = null.
  static Future<String?> getCfBestIp() async {
    if (_cfBestIpCache != null) return _cfBestIpCache;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_cfBestIpKey);
    if (v == null || v.isEmpty) {
      _cfBestIpCache = null;
      return null;
    }
    _cfBestIpCache = v;
    return v;
  }

  // ===== TMDB API Key (v2.0.35) =====

  /// 异步读 TMDB API key. 没填 = null.
  ///
  /// 配 key 即等价于「启用 TMDB 海报墙」开关. 首页 _buildHomeTabContent 在 build 时
  /// 同步读 [getTmdbApiKeySync], 配了走 TmdbPosterWall, 没配走原 HotMoviesSection / HotTvSection.
  ///
  /// v2.0.41: 同步通知 [tmdbApiKeyNotifier], 让预配 key 的用户第一次进首页就能
  /// 看到海报墙. 修法见字段注释.
  static Future<String?> getTmdbApiKey() async {
    if (_tmdbApiKeyCache != null) return _tmdbApiKeyCache;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_tmdbApiKeyKey);
    String? next;
    if (v == null || v.isEmpty) {
      _tmdbApiKeyCache = null;
      next = null;
    } else {
      _tmdbApiKeyCache = v;
      next = v;
    }
    // v2.0.41: 同步 notifier, 避免预配 key 的用户第一次进首页拿到 null 快照
    // (static final notifier 是在第一次访问时初始化的, 当时 _cache 还没 warmup)
    if (tmdbApiKeyNotifier.value != next) {
      tmdbApiKeyNotifier.value = next;
    }
    return next;
  }

  /// 同步读 TMDB API key (build 时用, 避免 Future). null = 未配 / 未初始化.
  static String? getTmdbApiKeySync() => _tmdbApiKeyCache;

  /// 保存 TMDB API key. trim + 非空校验. 传 null 或空字符串 = 删除.
  ///
  /// 不做严格格式校验 (v3 key 32 字符 hex / v4 JWT 长字符串),
  /// 等调用 TMDB API 失败时再提示用户重填.
  ///
  /// v2.0.41: 同步通知 [tmdbApiKeyNotifier], 触发监听它的 widget rebuild
  /// (e.g. home_screen 配 key 后立即看到 TMDB 海报墙).
  static Future<void> saveTmdbApiKey(String? input) async {
    final cleaned = (input ?? '').trim();
    final prefs = await SharedPreferences.getInstance();
    String? next;
    if (cleaned.isEmpty) {
      await prefs.remove(_tmdbApiKeyKey);
      _tmdbApiKeyCache = null;
      next = null;
    } else {
      await prefs.setString(_tmdbApiKeyKey, cleaned);
      _tmdbApiKeyCache = cleaned;
      next = cleaned;
    }
    // v2.0.41: 通知 home_screen / player_screen / user_menu 等所有监听者
    if (tmdbApiKeyNotifier.value != next) {
      tmdbApiKeyNotifier.value = next;
    }
  }

  /// 同步读 (启动 warmup 后用)
  static String? getCfBestIpSync() {
    return _cfBestIpCache;
  }

  /// 校验/清理 IP 或域名. 返回 null = 无效 (清空).
  /// - IPv4 (1.2.3.4) → 原样返回
  /// - 域名 (cf.877774.xyz) → 原样返回
  /// - 其他 → null
  static String? _cleanIpOrDomain(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    // IPv4
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final m = ipv4.firstMatch(s);
    if (m != null) {
      for (var i = 1; i <= 4; i++) {
        final n = int.parse(m.group(i)!);
        if (n < 0 || n > 255) return null;
      }
      return s;
    }
    // 域名: 简单校验. 至少一个点, 标签 1-63 字符 [a-z0-9-], 总长 ≤ 253
    final domain = RegExp(
      r'^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
    );
    if (domain.hasMatch(s)) return s.toLowerCase();
    return null;
  }

  // 清理域名：去掉尾部斜杠、协议前缀、空白
  static String _cleanDomain(String input) {
    var s = input.trim();
    s = s.replaceAll(RegExp(r'\s+'), '');
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    s = s.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    return s;
  }

  /// 通用代理 URL 构造器
  ///
  /// 在以下任一情况下返回原 URL：
  /// 1) [targetUrl] 为空
  /// 2) 开关未开
  /// 3) Worker 域名未配置
  ///
  /// 否则根据链接类型返回 worker 代理后的 URL：
  /// - m3u8 链接 →  `https://<worker>/m3u8?url=<encoded>`
  /// - 普通链接 →  `https://<worker>/?url=<encoded>`
  ///
  /// [forceM3u8] 强制按 m3u8 端点处理（即使链接不一定是 .m3u8 后缀，比如 master playlist 无后缀）。
  static String buildProxiedUrl(String targetUrl, {bool forceM3u8 = false}) {
    if (targetUrl.isEmpty) return targetUrl;
    if (!_isCfWorkerUsableSync()) return targetUrl;
    final worker = _cfWorkerDomainCache!.trim();
    if (worker.isEmpty) return targetUrl;
    final isM3u8 = forceM3u8 || _looksLikeM3u8(targetUrl);
    final endpoint = isM3u8 ? '/m3u8' : '/';
    return 'https://$worker$endpoint?url=${Uri.encodeComponent(targetUrl)}';
  }

  /// 异步版本：内部用内存缓存避免每次 await prefs
  static Future<String> buildProxiedUrlAsync(String targetUrl,
      {bool forceM3u8 = false}) async {
    if (targetUrl.isEmpty) return targetUrl;
    await _ensureCfWorkerCache();
    return buildProxiedUrl(targetUrl, forceM3u8: forceM3u8);
  }

  static Future<void> _ensureCfWorkerCache() async {
    if (_cfWorkerEnabledCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _cfWorkerEnabledCache = prefs.getBool(_cfWorkerEnabledKey) ?? false;
    }
    if (_cfWorkerDomainCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _cfWorkerDomainCache = prefs.getString(_cfWorkerDomainKey) ?? '';
    }
  }

  // 同步判断：开关 + 域名都齐了
  static bool _isCfWorkerUsableSync() {
    if (_cfWorkerEnabledCache != true) return false;
    final d = _cfWorkerDomainCache;
    if (d == null || d.isEmpty) return false;
    return true;
  }

  // 简单判断是否 m3u8 链接
  static bool _looksLikeM3u8(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) return true;
    if (lower.contains('.m3u')) return true;
    return false;
  }

  // ===== Bangumi 数据/图片源（沿用豆瓣的"直连 / Cors Proxy / CF Worker"模式） =====

  // 公共 CORS 代理（与豆瓣数据源共用同一个）
  // ciao-cors.is-an.org 验证可代理 api.bgm.tv/calendar 和 /v0/subjects/*
  // 但对 lain.bgm.tv 图片仍返回 403（上游拦了 CF 节点），所以图片必须走 CF Worker
  static const String publicCorsProxyBase = 'https://ciao-cors.is-an.org/';

  /// v2.0.12: 构造 ciao-cors 代理 URL
  ///
  /// 老用法 (v2.0.0 ~ v2.0.11):
  ///   `https://ciao-cors.is-an.org/?url=https%3A%2F%2F...`
  ///   → 现在返 400 "Invalid URL format", **100% 失败**
  ///
  /// 新用法 (v2.0.12+):
  ///   `https://ciao-cors.is-an.org/https://...` (path 拼接, **不 encode**)
  ///   + 必须带 `X-Requested-With: XMLHttpRequest` 或 `Origin` 头, 否则 403
  ///
  /// 调用方负责带 header (参考 [bangumi_service.dart] 的请求)
  static String buildCiaoCorsUrl(String targetUrl) {
    // 直接 path 拼接, target URL 必须带 https:// 前缀
    if (targetUrl.startsWith('https://') || targetUrl.startsWith('http://')) {
      return '$publicCorsProxyBase$targetUrl';
    }
    // 兜底: 协议相对或无协议, 强制 https
    return '$publicCorsProxyBase/https://$targetUrl';
  }

  // 保存 Bangumi 数据源设置（key 值：direct / cors_proxy / cf_worker）
  static Future<void> saveBangumiDataSource(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bangumiDataSourceKey, key);
    _bangumiDataSourceCache = key;
  }

  // 获取 Bangumi 数据源 key
  static Future<String> getBangumiDataSourceKey() async {
    if (_bangumiDataSourceCache != null) return _bangumiDataSourceCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_bangumiDataSourceKey) ?? 'direct';
    _bangumiDataSourceCache = v;
    return v;
  }

  // 获取 Bangumi 数据源显示名（异步）
  static Future<String> getBangumiDataSourceDisplayNameAsync() async {
    final key = await getBangumiDataSourceKey();
    return getBangumiDataSourceDisplayName(key);
  }

  // 获取 Bangumi 图片源显示名（异步）
  static Future<String> getBangumiImageSourceDisplayNameAsync() async {
    final key = await getBangumiImageSourceKey();
    return getBangumiImageSourceDisplayName(key);
  }

  // Bangumi 数据源显示名映射
  static String getBangumiDataSourceDisplayName(String key) {
    switch (key) {
      case 'cors_proxy':
        return 'Cors Proxy By Zwei';
      case 'cf_worker':
        return 'CF Worker 加速';
      case 'direct':
      default:
        return '直连';
    }
  }

  static String getBangumiDataSourceKeyFromDisplayName(String name) {
    switch (name) {
      case 'Cors Proxy By Zwei':
        return 'cors_proxy';
      case 'CF Worker 加速':
        return 'cf_worker';
      case '直连':
      default:
        return 'direct';
    }
  }

  // Bangumi 图片源显示名映射
  static String getBangumiImageSourceDisplayName(String key) {
    switch (key) {
      case 'cors_proxy':
        return 'Cors Proxy By Zwei';
      case 'cf_worker':
        return 'CF Worker 加速';
      case 'direct':
      default:
        return '直连';
    }
  }

  static String getBangumiImageSourceKeyFromDisplayName(String name) {
    switch (name) {
      case 'Cors Proxy By Zwei':
        return 'cors_proxy';
      case 'CF Worker 加速':
        return 'cf_worker';
      case '直连':
      default:
        return 'direct';
    }
  }

  // 获取 Bangumi 数据源显示名称（异步）
  static String getBangumiDataSourceKeySync() {
    return _bangumiDataSourceCache ?? 'direct';
  }

  // 保存 Bangumi 图片源设置（key 值：direct / cf_worker）
  static Future<void> saveBangumiImageSource(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bangumiImageSourceKey, key);
    _bangumiImageSourceCache = key;
  }

  // 获取 Bangumi 图片源 key
  static Future<String> getBangumiImageSourceKey() async {
    if (_bangumiImageSourceCache != null) return _bangumiImageSourceCache!;
    final prefs = await SharedPreferences.getInstance();
    // 旧版本没存过这个 key,默认跟 Bangumi 数据源对齐:
    // 0) 没配过 → 默认 'cors_proxy' (和 Bangumi 数据源默认一致,
    //    给老用户一个可用的选择,直连在国内往往访问不到)
    // 1) 配了 → 用用户选的
    final stored = prefs.getString(_bangumiImageSourceKey);
    if (stored != null && stored.isNotEmpty) {
      _bangumiImageSourceCache = stored;
      return stored;
    }
    // 第一次启动,没有这个 key,默认 cors_proxy
    _bangumiImageSourceCache = 'cors_proxy';
    await prefs.setString(_bangumiImageSourceKey, 'cors_proxy');
    return 'cors_proxy';
  }

  // 同步获取 Bangumi 图片源 key
  static String getBangumiImageSourceKeySync() {
    return _bangumiImageSourceCache ?? 'cors_proxy';
  }

  /// 是否配了 CF Worker 域名(给 Bangumi 数据请求做兜底判断用)
  static bool hasCfWorkerDomain() {
    final d = _cfWorkerDomainCache;
    return d != null && d.isNotEmpty;
  }

  /// 构造 Bangumi 数据请求 URL
  ///
  /// 优先级：CF Worker 域名（只要配了就用，不受 CF Worker 加速开关控制）
  /// > 用户选的 cors_proxy > 直连
  ///
  /// 设计：B 站番剧代理是"只要配置了加速源地址就一直生效"，
  /// 不和源加速（player 测速）的开关绑死。
  static String buildBangumiDataUrl(String originalUrl) {
    // 1) CF Worker 域名:只看域名是否配了,不看开关
    final worker = _cfWorkerDomainCache;
    if (worker != null && worker.isNotEmpty) {
      return 'https://$worker/?url=${Uri.encodeComponent(originalUrl)}';
    }

    // 2) 公共 CORS 代理
    final key = getBangumiDataSourceKeySync();
    if (key == 'cors_proxy') {
      // v2.0.12: ciao-cors 改用法 (?url= → path 拼接),
      // 老用法返 400 "Invalid URL format", 见 [buildCiaoCorsUrl]
      return buildCiaoCorsUrl(originalUrl);
    }
    return originalUrl;
  }

  /// 构造 Bangumi 图片请求 URL
  ///
  /// 优先级（和 Bangumi 数据源对齐）：
  /// 1. CF Worker 域名（只要配了就用，不受 CF Worker 加速开关控制）
  /// 2. 用户选的 cors_proxy（公共 CORS 代理）
  /// 3. 用户选的 cf_worker（CF Worker 加速）— v2.0.5 新增
  /// 4. 直连
  ///
  /// 注意：publicCorsProxyBase 对 lain.bgm.tv 返 403，
  /// 所以 cors_proxy 模式下图片依然可能加载失败，但用户自己选了
  /// 就是"已知风险"，给个选择总比没有好。
  static String buildBangumiImageUrl(String originalUrl) {
    // 1) CF Worker 域名:只看域名是否配了,不看开关
    //
    // v2.0.9: 加 worker 域名有效性校验, 避免填错域名导致 404
    //
    // 之前只看 _cfWorkerDomainCache 是否非空, 但用户可能填错:
    //   - 填了 netlify site (api08.netlify.app), 不是 CF Worker, 返 404
    //   - 填了普通自建域名 (example.com), 没有 worker 反代, 返 404
    //   - 填了失效 worker 域名, 返 404 / 502
    //
    // 这些情况下, 之前会直接走 worker URL 返 404, 图片加载不出来
    // 修法: worker 域名必须以 `.workers.dev` 结尾, 或者域名解析指向
    // CF Worker 才认. 这里**简化判断** — 只信 `.workers.dev` 结尾的,
    // 其他域名一概当"没配 worker"处理, 让下面的 fallthrough 走
    // 用户选的图片源 (cors_proxy / cf_worker / direct)
    //
    // ⚠️ 注意: 如果用户自己买域名 CNAME 到 .workers.dev (e.g. cdn.example.com
    // CNAME xxx.workers.dev), 这个简化判断会漏掉. 这种情况请用真正的
    // *.workers.dev 域名, 或后续加自定义域名白名单配置
    final worker = _cfWorkerDomainCache;
    if (worker != null && worker.isNotEmpty && _isValidWorkerDomain(worker)) {
      return 'https://$worker/?url=${Uri.encodeComponent(originalUrl)}';
    }

    // 2) 用户选的图片源
    final key = getBangumiImageSourceKeySync();
    if (key == 'cors_proxy') {
      // v2.0.12: ciao-cors 改用法, 见 [buildCiaoCorsUrl]
      return buildCiaoCorsUrl(originalUrl);
    }
    // v2.0.5: 之前 cf_worker case 缺了, 走 fallthrough 到 return originalUrl
    // 直连 lain.bgm.tv, 国内 403/被墙, 图片加载不出来。
    // 现在加 case: cf_worker 模式 (没配 CF Worker 域名) 退化成 cors_proxy,
    // 至少公共代理能加载, 比直连好
    if (key == 'cf_worker') {
      // v2.0.12: ciao-cors 改用法
      return buildCiaoCorsUrl(originalUrl);
    }
    return originalUrl;
  }

  /// v2.0.9: 判断配置的 worker 域名是不是真正的 CF Worker
  ///
  /// 简化规则: 必须以 `.workers.dev` 结尾才算 CF Worker
  ///
  /// 为什么不用更复杂的判断 (e.g. HTTP HEAD 请求验活):
  ///   - buildBangumiImageUrl 是同步函数, 不能 await
  ///   - 每次图片请求都发 HEAD 太慢, 影响图片加载
  ///   - 简化判断已能覆盖 99% 情况: 用户填错 netlify / 自建域名时
  ///     自动 fallback, 不会卡在 404
  static bool _isValidWorkerDomain(String domain) {
    return domain.endsWith('.workers.dev');
  }

  // Bangumi 数据源 key 同步初始化（main.dart 启动时调用）
  static Future<void> warmupBangumiConfig() async {
    if (_bangumiDataSourceCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _bangumiDataSourceCache = prefs.getString(_bangumiDataSourceKey) ?? 'direct';
    }
    if (_bangumiImageSourceCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _bangumiImageSourceCache = prefs.getString(_bangumiImageSourceKey) ?? 'direct';
    }
  }

  // 应用启动时调用一次，缓存到内存，后续 buildProxiedUrl 不再 await
  static Future<void> warmupCfWorkerConfig() async {
    await _ensureCfWorkerCache();
    await warmupBangumiConfig();
  }
}
