import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/diary_service.dart';

class UserDataService {
  static const String _serverUrlKey = 'server_url';
  static const String _usernameKey = 'username';
  static const String _passwordKey = 'password';
  static const String _cookiesKey = 'cookies';
  static const String _doubanDataSourceKey = 'douban_data_source';
  static const String _doubanImageSourceKey = 'douban_image_source';
  static const String _bangumiDataSourceKey = 'bangumi_data_source';
  static const String _bangumiImageSourceKey = 'bangumi_image_source';
  static const String _preferSpeedTestKey = 'prefer_speed_test';
  static const String _localSearchKey = 'local_search';
  static const String _isLocalModeKey = 'is_local_mode';
  static const String _cfWorkerEnabledKey = 'cf_worker_enabled';
  static const String _cfWorkerDomainKey = 'cf_worker_domain';
  static const String _videoProxyEnabledKey = 'video_proxy_enabled';
  // v2.0.31: 用户手动填的优选 IP, 优先级高于测速结果
  static const String _cfBestIpKey = 'cf_best_ip';
  // v2.0.77: 豆瓣登录 cookie — 登录后给豆瓣图升到 l_ratio_poster (高清),
  //   没登录 = 现有图片不变化.
  //   用户从浏览器 DevTools 复制 cookie 字符串粘进来, 存这里.
  //   申请的 cookie 失效了再粘一次就行.
  static const String _doubanCookieKey = 'douban_cookie';
  // v2.0.93: TMDB API Key (v3) — 从 themoviedb.org/settings/api 申请.
  //   配了 = 详情页大头部走 TMDB search/multi 拿精准 backdrop (w1280) +
  //   logo (w500), 替代豆瓣 coverUrl (v2.0.84 之前). 留空 = 走豆瓣
  //   coverUrl, 行为完全不变 (跟「豆瓣登录」「优选 IP」同 UX: 字段本身
  //   就是开关, 不另加 toggle).
  static const String _tmdbApiKeyKey = 'tmdb_api_key';
  // v2.0.97: TMDB 数据源 — 跟 Bangumi 数据源一样 UX, 2 选 1.
  //   - 'tmdb_proxy' (v2.1.41 新): 走用户自部署 CF Worker 加速 (如
  //     https://tmdb-8d1.pages.dev/), path-based API + 图片代理. 用户
  //     在「数据源」section 配 worker URL, App 调 TMDB 时拼成
  //     `${workerUrl}/movie/xxx?api_key=...` (api_key 透传, Worker 不需要
  //     配 env). 配了 worker URL 但没配 API key → 跟 v2.1.40 一样 skip.
  //   - 'direct' (默认): 强制直连 api.themoviedb.org / image.tmdb.org.
  //     国内直连 100% 不可用 (GFW), 配了 CF Worker 域名也没用, 想用 TMDB
  //     必须走 VPN. 切 tmdb_proxy 才能用国内 Worker 加速.
  // v2.1.41 改: 删 'off' / 'cf_worker' / 'cors_proxy'. 'off' 删 (用户反馈
  //   "这个关闭不要"). 'cf_worker' / 'cors_proxy' 在 v2.1.40 已删, 老值
  //   自动 migrate.
  static const String _tmdbDataSourceKey = 'tmdb_data_source';
  // v2.1.41: TMDB 代理 URL — 用户自部署的 CF Worker (e.g.
  //   https://tmdb-8d1.pages.dev/), 走 path-based 加速. 跟 v2.0.77
  //   _cfWorkerDomainKey 区分: _cfWorkerDomainKey 是视频加速 (CORSAPI
  //   套娃), _tmdbProxyDomainKey 是 TMDB API + 图片 (独立 worker, 部署
  //   在 [djsevenx1/tmdb-proxy]). 不共用, 互不影响.
  static const String _tmdbProxyDomainKey = 'tmdb_proxy_domain';

  // 内存缓存
  static bool? _isLocalModeCache;
  // v2.0.76: 字段重命名 — 原本 "CF Worker 加速总开关", 现在是 "优选 IP 启用"
  static bool? _cfWorkerEnabledCache;
  static String? _cfWorkerDomainCache;
  // v2.0.76: 新加 — "视频代理" 开关
  static bool? _videoProxyEnabledCache;
  static String? _bangumiDataSourceCache;
  static String? _bangumiImageSourceCache;
  static String? _cfBestIpCache;
  // v2.0.77
  static String? _doubanCookieCache;
  // v2.0.93
  static String? _tmdbApiKeyCache;
  // v2.0.97
  static String? _tmdbDataSourceCache;
  // v2.1.41
  static String? _tmdbProxyDomainCache;

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

  // 兼容旧接口:设置优选测速
  static Future<void> setPreferSpeedTest(bool enabled) async {
    await savePreferSpeedTest(enabled);
  }

  // ===== CF Worker 加速配置 =====

  // v2.0.76: CF Worker 加速开关 语义重定义
  //   旧 (v2.0.70~v2.0.75): "代理总开关" — 控制是否启代理 (CF Worker)
  //   新 (v2.0.76+):        "优选 IP 启用" — 控制所有资源 (视频 / 图片 / Bangumi 等)
  //                          是否走优选 IP. CF Worker 代理本身不再有总开关,
  //                          只要域名配了默认就生效.
  // 保存
  static Future<void> saveCfWorkerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cfWorkerEnabledKey, enabled);
    _cfWorkerEnabledCache = enabled;
  }

  // 获取 (默认 true — 用户期望默认走优选 IP, 跟 v2.0.34 反过来)
  static Future<bool> getCfWorkerEnabled() async {
    if (_cfWorkerEnabledCache != null) return _cfWorkerEnabledCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_cfWorkerEnabledKey) ?? true;
    _cfWorkerEnabledCache = v;
    return v;
  }

  // 同步获取
  static bool getCfWorkerEnabledSync() {
    return _cfWorkerEnabledCache ?? true;
  }

  // v2.0.76: 视频代理开关 语义重定义
  //   旧 (v2.0.70~v2.0.75): "优选 IP 启用（视频流）" — 只控制视频是否走优选 IP
  //   新 (v2.0.76+):        "视频代理" — 控制视频是否走 CF Worker 代理
  //                          (关 = 视频直连原源, 开 = 视频走 VideoProxyServer)
  static Future<void> saveVideoProxyEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_videoProxyEnabledKey, enabled);
    _videoProxyEnabledCache = enabled;
  }

  static Future<bool> getVideoProxyEnabled() async {
    if (_videoProxyEnabledCache != null) return _videoProxyEnabledCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_videoProxyEnabledKey) ?? true;
    _videoProxyEnabledCache = v;
    return v;
  }

  /// 同步版 (buildProxiedUrl 等热路径用, 避免 await)
  /// v2.0.76: 默认 true — 用户期望默认走视频代理
  static bool getVideoProxyEnabledSync() {
    return _videoProxyEnabledCache ?? true;
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

  // ===== 豆瓣登录 cookie (v2.0.77) =====
  //
  // 用户从浏览器 DevTools → Application → Cookies → movie.douban.com
  //   复制整串 cookie 粘进来, 存这里. 登录后:
  //   - getImageUrl 拿到豆瓣 URL 时自动把 s_ratio_poster / m_ratio_poster
  //     升到 l_ratio_poster (600x900, 公开图最大尺寸) — 详情页大头部 / 轮播
  //   - 详情页请求豆瓣 API 时带 cookie, 拿到原图尺寸的 raw_url (需登录)
  //   - 用户登出 / cookie 失效 → 删 key, 行为退回到没登录 = 当前不变化
  //
  // 不做主动 cookie 校验 (没法在 Flutter 里跑 JS / 跑 OAuth), 失效
  // 用户自己再粘一次. 想主动校验就看图加载 403 没.

  /// 异步读豆瓣 cookie, 没存 = null.
  static Future<String?> getDoubanCookie() async {
    if (_doubanCookieCache != null) return _doubanCookieCache;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_doubanCookieKey);
    if (v == null || v.isEmpty) {
      _doubanCookieCache = null;
      return null;
    }
    _doubanCookieCache = v;
    return v;
  }

  /// 同步读豆瓣 cookie (build 时用). null = 未配.
  static String? getDoubanCookieSync() => _doubanCookieCache;

  /// 同步判断是否登录 (build 时用).
  static bool isDoubanLoggedIn() {
    final c = _doubanCookieCache;
    return c != null && c.isNotEmpty;
  }

  /// 保存豆瓣 cookie. trim + 非空校验. 传 null / 空 = 清除.
  static Future<void> saveDoubanCookie(String? input) async {
    final cleaned = (input ?? '').trim();
    final prefs = await SharedPreferences.getInstance();
    if (cleaned.isEmpty) {
      await prefs.remove(_doubanCookieKey);
      _doubanCookieCache = null;
    } else {
      await prefs.setString(_doubanCookieKey, cleaned);
      _doubanCookieCache = cleaned;
    }
  }

  /// 清除豆瓣 cookie (登出).
  static Future<void> clearDoubanCookie() async {
    await saveDoubanCookie(null);
  }

  // ===== v2.0.93: TMDB API Key (v3) =====

  /// 异步读 TMDB API key (v3). null = 未配.
  /// 配了 = 详情页大头部走 TMDB search/multi 拿精准 backdrop 替代豆瓣
  /// coverUrl; 留空 = 走原 DoubanDetailHeader (v2.0.84 行为).
  static Future<String?> getTmdbApiKey() async {
    if (_tmdbApiKeyCache != null) return _tmdbApiKeyCache;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_tmdbApiKeyKey);
    if (v == null || v.isEmpty) {
      _tmdbApiKeyCache = null;
      return null;
    }
    _tmdbApiKeyCache = v;
    return v;
  }

  /// 同步读 TMDB API key (build 时用). null = 未配.
  static String? getTmdbApiKeySync() => _tmdbApiKeyCache;

  /// 同步判断是否配了 TMDB API key (build 时用).
  static bool isTmdbConfigured() {
    final k = _tmdbApiKeyCache;
    return k != null && k.isNotEmpty;
  }

  /// 保存 TMDB API key. trim + 非空校验. 传 null / 空 = 清除.
  /// TMDB v3 API key 长度 32 字符 (hex), 形如 "1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p",
  /// 不强制格式校验 — 留给 TMDB 服务端验 (用户可能输错, 但不会崩 app).
  static Future<void> saveTmdbApiKey(String? input) async {
    final cleaned = (input ?? '').trim();
    final prefs = await SharedPreferences.getInstance();
    if (cleaned.isEmpty) {
      await prefs.remove(_tmdbApiKeyKey);
      _tmdbApiKeyCache = null;
    } else {
      await prefs.setString(_tmdbApiKeyKey, cleaned);
      _tmdbApiKeyCache = cleaned;
    }
  }

  /// 清除 TMDB API key.
  static Future<void> clearTmdbApiKey() async {
    await saveTmdbApiKey(null);
  }

  // ===== v2.1.41: TMDB 数据源 (v2.1.40 删 cf_worker / cors_proxy, v2.1.41 删 off, 加 tmdb_proxy) =====

  /// 保存 TMDB 数据源 (key 值: 'tmdb_proxy' / 'direct')
  ///
  /// v2.1.41 改: 加 'tmdb_proxy' (用户自部署 CF Worker 加速, 见
  ///   [_tmdbProxyDomainKey]). 删 'off' (用户反馈「这个关闭不要」).
  ///   'tmdb_proxy' 但 worker URL 没配 → 自动回落到 'direct' (不报错,
  ///   跟老 cf_worker 行为一致: 配 worker 域名才生效).
  /// v2.1.40 改: 删 'cf_worker' / 'cors_proxy'. 删 TMDB 加速代码后
  ///   只剩 2 选 1. 老用户存的 'cf_worker' / 'cors_proxy' 自动
  ///   migrate 到 'direct'.
  static Future<void> saveTmdbDataSource(String key) async {
    String cleaned;
    if (key == 'tmdb_proxy') {
      // v2.1.41: tmdb_proxy 但 URL 没配 → 直接落 'direct', 不污染 store.
      final proxy = getTmdbProxyDomainSync();
      cleaned = proxy.isNotEmpty ? 'tmdb_proxy' : 'direct';
    } else if (key == 'direct') {
      cleaned = 'direct';
    } else {
      // 兜底: 老值 'off' / 'cf_worker' / 'cors_proxy' / 任何脏数据 → 'direct'
      cleaned = 'direct';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tmdbDataSourceKey, cleaned);
    _tmdbDataSourceCache = cleaned;
  }

  /// 异步读 TMDB 数据源 key, 默认值看 worker URL 是否配了
  ///
  /// v2.1.41 改: 默认值不再是死写 'direct'. 配了 worker URL 默认
  ///   'tmdb_proxy' (用户大概率是知道这个功能才配的, 默认开启),
  ///   没配默认 'direct' (worker URL 都没配, tmdb_proxy 选了也走
  ///   不通). 老用户存的值保持不变 (尊重用户选择).
  static Future<String> getTmdbDataSourceKey() async {
    if (_tmdbDataSourceCache != null) return _tmdbDataSourceCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_tmdbDataSourceKey);
    if (v != null && (v == 'tmdb_proxy' || v == 'direct')) {
      _tmdbDataSourceCache = v;
      return v;
    }
    // 老值 / 没存 → 按 worker URL 推断默认
    final proxy = getTmdbProxyDomainSync();
    final def = proxy.isNotEmpty ? 'tmdb_proxy' : 'direct';
    _tmdbDataSourceCache = def;
    return def;
  }

  /// 同步读 TMDB 数据源 key (build 时用, 比如 TmdbService._buildTmdbApiUrl)
  static String getTmdbDataSourceSync() {
    if (_tmdbDataSourceCache != null) return _tmdbDataSourceCache!;
    // 缓存没 warmup (老路径), 兜底走 default — 配了 worker URL 用 tmdb_proxy
    final proxy = getTmdbProxyDomainSync();
    return proxy.isNotEmpty ? 'tmdb_proxy' : 'direct';
  }

  /// key 值 → 显示名
  ///
  /// v2.1.41 改: 'tmdb_proxy' → 'TMDB Worker 加速', 删 'off' → '已关闭'.
  ///   跟视频加速「CF Worker 加速」section 区分 (那是 CORSAPI 套娃,
  ///   这里是 [djsevenx1/tmdb-proxy] path-based, 部署在 tmdb-8d1.pages.dev).
  static String getTmdbDataSourceDisplayName(String key) {
    switch (key) {
      case 'tmdb_proxy':
        return 'TMDB Worker 加速';
      case 'direct':
      default:
        return '直连';
    }
  }

  /// 显示名 → key 值
  static String getTmdbDataSourceKeyFromDisplayName(String name) {
    switch (name) {
      case 'TMDB Worker 加速':
        return 'tmdb_proxy';
      case '直连':
      default:
        return 'direct';
    }
  }

  // ===== v2.1.41: TMDB 代理 URL (用户自部署 CF Worker 加速) =====
  //
  // 用户场景: 部署 [djsevenx1/tmdb-proxy] (fork HuntzzZ/tmdb-proxy 加
  //   Bangumi 路由) 到 Cloudflare Pages, 拿到一个 https://xxx.pages.dev
  //   地址, 粘到这. App 调 TMDB API / 加载 TMDB 图时拼成
  //   `${workerUrl}/movie/xxx?api_key=${userKey}` / `${workerUrl}/image/...`,
  //   path-based 走 worker, 解决国内直连 GFW 问题. 跟 _cfWorkerDomainKey
  //   (视频加速 CORSAPI) 完全独立, 互不干扰.

  /// 保存 TMDB 代理 URL. 空串 = 清空. 返回清理后的字符串, null 表示输入无效.
  ///
  /// 接受格式 (大小写不敏感):
  ///   - "tmdb-8d1.pages.dev"            → "https://tmdb-8d1.pages.dev"
  ///   - "https://tmdb-8d1.pages.dev"    → "https://tmdb-8d1.pages.dev"
  ///   - "https://tmdb-8d1.pages.dev/"   → "https://tmdb-8d1.pages.dev"  (去尾斜杠)
  ///   - "http://tmdb-8d1.pages.dev"     → "https://tmdb-8d1.pages.dev"  (强转 https)
  ///   - "  https://tmdb-8d1.pages.dev  "→ "https://tmdb-8d1.pages.dev"  (去空白)
  ///
  /// 无效输入 (空 / 解析失败 / 无 host) → 返回 null, prefs 不写.
  static Future<String?> saveTmdbProxyDomain(String input) async {
    final cleaned = _cleanWorkerBaseUrl(input);
    final prefs = await SharedPreferences.getInstance();
    if (cleaned == null) {
      await prefs.remove(_tmdbProxyDomainKey);
      _tmdbProxyDomainCache = '';
    } else {
      await prefs.setString(_tmdbProxyDomainKey, cleaned);
      _tmdbProxyDomainCache = cleaned;
    }
    return cleaned;
  }

  /// 同步读 TMDB 代理 URL (build 时用, 比如 TmdbService._buildTmdbApiUrl).
  /// 空串 = 没配.
  static String getTmdbProxyDomainSync() {
    return _tmdbProxyDomainCache ?? '';
  }

  /// 异步读 TMDB 代理 URL. 空串 = 没配.
  static Future<String> getTmdbProxyDomain() async {
    if (_tmdbProxyDomainCache != null) return _tmdbProxyDomainCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_tmdbProxyDomainKey) ?? '';
    _tmdbProxyDomainCache = v;
    return v;
  }

  /// 校验/清理 TMDB 代理 URL. 返回 null = 无效 (清空).
  /// 强转 https://, 去尾斜杠 / 空白 / 协议, 保留 host:port.
  static String? _cleanWorkerBaseUrl(String input) {
    final s = input.trim().replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;
    // 强转 https (Cloudflare Pages 只发 https, http 上去也会 301)
    String withScheme = s;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(withScheme)) {
      withScheme = 'https://$withScheme';
    }
    withScheme = withScheme.replaceFirst(
        RegExp(r'^http://', caseSensitive: false), 'https://');
    final u = Uri.tryParse(withScheme);
    if (u == null || u.host.isEmpty) return null;
    return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
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
  /// 2) 「视频代理」开关关 (v2.0.76 起: 视频是否走代理看的是视频代理开关, 不是
  ///    优选 IP 开关; 优选 IP 只决定 HTTP 层解析到哪个 IP, 跟 URL 无关)
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
    // v2.0.76: 同时缓存 优选 IP 开关 + 视频代理开关 两个独立值
    if (_cfWorkerEnabledCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _cfWorkerEnabledCache = prefs.getBool(_cfWorkerEnabledKey) ?? true;
    }
    if (_videoProxyEnabledCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _videoProxyEnabledCache = prefs.getBool(_videoProxyEnabledKey) ?? true;
    }
    if (_cfWorkerDomainCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _cfWorkerDomainCache = prefs.getString(_cfWorkerDomainKey) ?? '';
    }
  }

  // 同步判断：buildProxiedUrl 是否能包 worker.
  // v2.0.76: 改成看「视频代理」开关 (不是优选 IP 开关).
  //   优选 IP 开关只影响 CfOptimizerHttpOverrides 的 DNS override,
  //   不影响 URL 是否被包 worker.
  static bool _isCfWorkerUsableSync() {
    // 视频代理关 → 不包 worker
    if (_videoProxyEnabledCache != true) return false;
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

  // ===== v2.1.42: Bangumi 数据源 (v2.1.40 删, v2.1.42 跟 TMDB 一起加回 'bangumi_proxy') =====

  /// 保存 Bangumi 数据源 (key 值: 'bangumi_proxy' / 'direct')
  ///
  /// v2.1.42 改: 重新加 'bangumi_proxy' (跟 v2.1.41 TMDB 的 tmdb_proxy
  ///   一样的设计, 共用 _tmdbProxyDomain worker URL). 删 'off' /
  ///   'cf_worker' / 'cors_proxy' 任何老值 → 'direct'.
  ///   'bangumi_proxy' 但 worker URL 没配 → 自动回落到 'direct'.
  /// v2.1.40 改: 删 'cf_worker' / 'cors_proxy'. 删 Bangumi 加速代码
  ///   后只剩 'direct' 一档. 老值 migrate 到 'direct'.
  static Future<void> saveBangumiDataSource(String key) async {
    String cleaned;
    if (key == 'bangumi_proxy') {
      // v2.1.42: bangumi_proxy 但 worker URL 没配 → 直接落 'direct'.
      final proxy = getTmdbProxyDomainSync();
      cleaned = proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
    } else if (key == 'direct') {
      cleaned = 'direct';
    } else {
      // 兜底: 老值 / 任何脏数据 → 'direct'
      cleaned = 'direct';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bangumiDataSourceKey, cleaned);
    _bangumiDataSourceCache = cleaned;
  }

  /// 异步读 Bangumi 数据源 key, 默认值看 worker URL 是否配了
  ///
  /// v2.1.42 改: 跟 v2.1.41 TMDB 一样, 默认值按 worker URL 推断.
  ///   配了 worker URL 默认 'bangumi_proxy', 没配默认 'direct'.
  ///   老用户存的值保持不变.
  static Future<String> getBangumiDataSourceKey() async {
    if (_bangumiDataSourceCache != null) return _bangumiDataSourceCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_bangumiDataSourceKey);
    if (v != null && (v == 'bangumi_proxy' || v == 'direct')) {
      _bangumiDataSourceCache = v;
      return v;
    }
    // 老值 / 没存 → 按 worker URL 推断默认
    final proxy = getTmdbProxyDomainSync();
    final def = proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
    _bangumiDataSourceCache = def;
    return def;
  }

  /// 同步读 Bangumi 数据源 key (build 时用, 比如 BangumiService
  /// 拼 api.bgm.tv URL 时)
  static String getBangumiDataSourceKeySync() {
    if (_bangumiDataSourceCache != null) return _bangumiDataSourceCache!;
    // 缓存没 warmup (老路径), 兜底走 default
    final proxy = getTmdbProxyDomainSync();
    return proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
  }

  // 获取 Bangumi 数据源显示名（异步, 跟老 UX 兼容, 默认 'direct'）
  static Future<String> getBangumiDataSourceDisplayNameAsync() async {
    return getBangumiDataSourceDisplayName(
        await getBangumiDataSourceKey());
  }

  // 获取 Bangumi 图片源显示名（异步, 跟老 UX 兼容, 默认 'direct'）
  static Future<String> getBangumiImageSourceDisplayNameAsync() async {
    return getBangumiImageSourceDisplayName(
        await getBangumiImageSourceKey());
  }

  /// key 值 → 显示名
  ///
  /// v2.1.42 改: 'bangumi_proxy' → 'Bangumi Worker 加速'.
  ///   跟 TMDB Worker 加速区分 (worker 是同一个, 路径前缀不同).
  static String getBangumiDataSourceDisplayName(String key) {
    switch (key) {
      case 'bangumi_proxy':
        return 'Bangumi Worker 加速';
      case 'direct':
      default:
        return '直连';
    }
  }

  /// 显示名 → key 值
  static String getBangumiDataSourceKeyFromDisplayName(String name) {
    switch (name) {
      case 'Bangumi Worker 加速':
        return 'bangumi_proxy';
      case '直连':
      default:
        return 'direct';
    }
  }

  /// key 值 → 显示名 (Bangumi 图片源)
  static String getBangumiImageSourceDisplayName(String key) {
    switch (key) {
      case 'bangumi_proxy':
        return 'Bangumi Worker 加速';
      case 'direct':
      default:
        return '直连';
    }
  }

  /// 显示名 → key 值 (Bangumi 图片源)
  static String getBangumiImageSourceKeyFromDisplayName(String name) {
    switch (name) {
      case 'Bangumi Worker 加速':
        return 'bangumi_proxy';
      case '直连':
      default:
        return 'direct';
    }
  }

  /// v2.1.42: 保存 Bangumi 图片源 (跟数据源一样 2 选 1)
  ///
  /// 跟数据源是 2 个独立开关: 用户可以数据走 worker 加速, 图片直连
  /// (e.g. lain.bgm.tv 在某运营商可达, 走 worker 反而绕). 或者
  /// 反过来. 默认 2 个都看 worker URL 配没配推断.
  static Future<void> saveBangumiImageSource(String key) async {
    String cleaned;
    if (key == 'bangumi_proxy') {
      final proxy = getTmdbProxyDomainSync();
      cleaned = proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
    } else if (key == 'direct') {
      cleaned = 'direct';
    } else {
      cleaned = 'direct';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bangumiImageSourceKey, cleaned);
    _bangumiImageSourceCache = cleaned;
  }

  /// 异步读 Bangumi 图片源 key, 默认值看 worker URL
  static Future<String> getBangumiImageSourceKey() async {
    if (_bangumiImageSourceCache != null) return _bangumiImageSourceCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_bangumiImageSourceKey);
    if (v != null && (v == 'bangumi_proxy' || v == 'direct')) {
      _bangumiImageSourceCache = v;
      return v;
    }
    // 老值 / 没存 → 按 worker URL 推断默认
    final proxy = getTmdbProxyDomainSync();
    final def = proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
    _bangumiImageSourceCache = def;
    return def;
  }

  /// 同步读 Bangumi 图片源 key
  static String getBangumiImageSourceKeySync() {
    if (_bangumiImageSourceCache != null) return _bangumiImageSourceCache!;
    final proxy = getTmdbProxyDomainSync();
    return proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
  }

  // v2.1.40: 删 hasCfWorkerDomain — Bangumi 数据 fetch 改直连后, 没人调了.
  //   CF Worker 域名本身保留 (video 加速还在用).

  /// 构造 Bangumi 数据请求 URL
  ///
  /// v2.1.42 改: 加 'bangumi_proxy' 分支 — Bangumi 数据源选 worker
  ///   加速且配了 worker URL 时, 走 path-based: 剥 `api.bgm.tv` 前缀,
  ///   拼 `${workerUrl}/bangumi`, 例:
  ///     https://api.bgm.tv/calendar
  ///     → https://tmdb-8d1.pages.dev/bangumi/calendar
  ///     https://api.bgm.tv/v0/subjects/123
  ///     → https://tmdb-8d1.pages.dev/bangumi/v0/subjects/123
  ///   worker 端 ([djsevenx1/tmdb-proxy] fork HuntzzZ) 拿 `/bangumi/...`
  ///   path 转给 api.bgm.tv, Authorization 透传. 跟 v2.0.77 之前
  ///   cf_worker 套娃 (`?url=`) 不一样: path-based worker 不需要
  ///   URL encode, 日志 / 日记 / Cache-Control 都干净.
  /// v2.1.40 改: 删 cf_worker / ciao-cors 加速, 1:1 返原 URL.
  /// v2.1.42: 加 'bangumi_proxy' 分支, 其他仍 1:1 返 (老用户 + 未配
  ///   worker URL 的).
  /// v2.1.43 改: 加详细 DiaryService 日记 (source / worker URL / 转换前
  ///   URL / 转换后 URL), 用户在日记里直接看到 wrap 走没走, 不需要
  ///   查代码. 之前 v2.1.42 没日记, 反馈「bangumi 加速不行」时只能
  ///   翻 _bangumiDataSourceCache 状态, 排查不动.
  static String buildBangumiDataUrl(String originalUrl) {
    if (originalUrl.isEmpty) return originalUrl;
    final source = getBangumiDataSourceKeySync();
    if (source == 'bangumi_proxy') {
      final proxy = getTmdbProxyDomainSync();
      if (proxy.isNotEmpty && originalUrl.startsWith('https://api.bgm.tv')) {
        final wrapped = originalUrl.replaceFirst(
          'https://api.bgm.tv',
          '$proxy/bangumi',
        );
        // v2.1.43: 转换成功 (source=bangumi_proxy + worker URL 配了 + URL 是
        //   api.bgm.tv 开头) 写一行日记, 用户看日记能确认 wrap 真发生了.
        //   记 wrap 前/后完整 URL, 排查 "worker URL 拼错了" 之类问题方便.
        DiaryService.add(
            '[Bangumi] buildDataUrl: source=bangumi_proxy, worker=$proxy');
        DiaryService.add(
            '[Bangumi] buildDataUrl wrap: in=$originalUrl out=$wrapped');
        return wrapped;
      } else {
        // v2.1.43: source=bangumi_proxy 但没配 worker URL 或 URL 不是
        //   api.bgm.tv 开头 — 走 1:1 passthrough 但写日记告知, 用户
        //   在日记里看到这条就能知道 "加速没生效" 是这个原因.
        final reason = proxy.isEmpty
            ? 'worker URL 未配 (在「数据源 / TMDB / Bangumi 代理 URL」填)'
            : 'URL 不是 api.bgm.tv 开头 (不起作用)';
        DiaryService.add(
            '[Bangumi] buildDataUrl: source=bangumi_proxy 但 passthrough, reason="$reason", in=$originalUrl');
      }
    } else {
      // v2.1.43: source=direct (默认) 也写一行, 用户选 worker 加速
      //   但日记里写 direct, 看到这一行就能定位 (通常是数据源选 direct).
      //   注意: 这个函数是热路径, 详情页 / 列表都会调, 一次会话可能
      //   调几十次, 日记会爆. 改成只记 "source 跟用户预期不一致"
      //   的情况: source=direct 但有 worker URL 配了 (说明用户想加速
      //   但数据源没切) — 这种情况提示一次; 选 direct + 没 worker URL
      //   完全不记.
      final proxy = getTmdbProxyDomainSync();
      if (proxy.isNotEmpty) {
        // v2.1.43: 配了 worker URL 但数据源选 direct, 提示一下
        //   (只提示一次, 后续都跳过避免日记爆)
        if (!_bangumiDataSourceNoProxyHinted) {
          _bangumiDataSourceNoProxyHinted = true;
          DiaryService.add(
              '[Bangumi] buildDataUrl hint: 配了 worker URL ($proxy) 但 Bangumi 数据源选 direct, 加速不生效, 切到「Bangumi Worker 加速」');
        }
      }
    }
    return originalUrl;
  }

  // v2.1.43: 「配 worker URL 但 data source=direct」的一次性提示 flag,
  //   避免 buildBangumiDataUrl 在详情页/列表里被调几十次, 日记满屏
  //   重复 hint.
  static bool _bangumiDataSourceNoProxyHinted = false;

  /// 构造 Bangumi 图片请求 URL
  ///
  /// v2.1.42 改: 加 'bangumi_proxy' 分支 — Bangumi 图片源选 worker
  ///   加速且配了 worker URL 时, 走 path-based: 剥 `lain.bgm.tv` 前缀,
  ///   拼 `${workerUrl}/bgm-img`, 例:
  ///     https://lain.bgm.tv/img/.../abc.jpg
  ///     → https://tmdb-8d1.pages.dev/bgm-img/img/.../abc.jpg
  ///   worker 端 ([djsevenx1/tmdb-proxy] fork HuntzzZ) 拿 `/bgm-img/...`
  ///   path 转给 lain.bgm.tv, 自动加 Referer: https://bgm.tv/ 绕过反盗链.
  ///   国内反盗链偶尔 403, 走 worker 反而成功率高. 跟 v2.0.74 之前
  ///   cf_worker 套娃 (用 `?url=` 转) 不一样: path-based worker 不需要
  ///   URL encode, 日志 / 日记 / Cache-Control 都干净.
  /// v2.1.40 改: 删 cf_worker / ciao-cors 加速, 1:1 返原 URL.
  /// v2.1.42: 加 'bangumi_proxy' 分支, 其他仍 1:1 返 (老用户 + 未配
  ///   worker URL 的).
  /// v2.1.43 改: 加详细 DiaryService 日记, 跟 buildBangumiDataUrl 平行.
  ///   image URL 是热路径 (一个详情页 / 轮播可能调几十次), 跟数据源
  ///   一样用一次性 hint flag 避免日记爆.
  static String buildBangumiImageUrl(String originalUrl) {
    if (originalUrl.isEmpty) return originalUrl;
    final source = getBangumiImageSourceKeySync();
    if (source == 'bangumi_proxy') {
      final proxy = getTmdbProxyDomainSync();
      if (proxy.isNotEmpty && originalUrl.startsWith('https://lain.bgm.tv')) {
        final wrapped = originalUrl.replaceFirst(
          'https://lain.bgm.tv',
          '$proxy/bgm-img',
        );
        DiaryService.add(
            '[Bangumi] buildImageUrl: source=bangumi_proxy, worker=$proxy');
        DiaryService.add(
            '[Bangumi] buildImageUrl wrap: in=$originalUrl out=$wrapped');
        return wrapped;
      } else {
        final reason = proxy.isEmpty
            ? 'worker URL 未配'
            : 'URL 不是 lain.bgm.tv 开头 (不起作用)';
        DiaryService.add(
            '[Bangumi] buildImageUrl: source=bangumi_proxy 但 passthrough, reason="$reason", in=$originalUrl');
      }
    } else {
      // v2.1.43: 配了 worker URL 但图片源选 direct, 一次性 hint
      final proxy = getTmdbProxyDomainSync();
      if (proxy.isNotEmpty) {
        if (!_bangumiImageSourceNoProxyHinted) {
          _bangumiImageSourceNoProxyHinted = true;
          DiaryService.add(
              '[Bangumi] buildImageUrl hint: 配了 worker URL ($proxy) 但 Bangumi 图片源选 direct, 加速不生效, 切到「Bangumi Worker 加速」');
        }
      }
    }
    return originalUrl;
  }

  // v2.1.43: 一次性 hint flag (跟 data source hint 平行)
  static bool _bangumiImageSourceNoProxyHinted = false;

  /// 构造 TMDB 图片请求 URL
  ///
  /// v2.1.41 改: 加 'tmdb_proxy' 分支 — TMDB 数据源选 worker 加速且
  ///   配了 worker URL 时, 走 path-based: 把 `https://image.tmdb.org`
  ///   前缀换成 `${workerUrl}/image`, 例:
  ///     https://image.tmdb.org/t/p/w1280/abc.jpg
  ///     → https://tmdb-8d1.pages.dev/image/t/p/w1280/abc.jpg
  ///   worker 端 ([djsevenx1/tmdb-proxy] fork HuntzzZ) 拿 `/image/...`
  ///   path 转给 image.tmdb.org, 顺带做 1 天 Cache-Control. 跟
  ///   v2.0.74 之前 cf_worker 套娃 (用 `?url=` 转) 不一样: path-based
  ///   worker 不需要 URL encode, 日志 / 日记 / Cache-Control 都干净.
  ///
  /// v2.1.40 改: 删 cf_worker / ciao-cors 加速, 1:1 返原 URL.
  /// v2.1.41: 仍然 1:1 返 (老用户 + 未配 worker URL 的). 新分支
  ///   只在 source='tmdb_proxy' 且 worker URL 已配时触发.
  /// v2.1.43 改: 加详细 DiaryService 日记, 跟 Bangumi 平行.
  static String buildTmdbImageUrl(String originalUrl) {
    if (originalUrl.isEmpty) return originalUrl;
    final source = getTmdbDataSourceSync();
    if (source == 'tmdb_proxy') {
      final proxy = getTmdbProxyDomainSync();
      if (proxy.isNotEmpty && originalUrl.startsWith('https://image.tmdb.org')) {
        final wrapped = originalUrl.replaceFirst(
          'https://image.tmdb.org',
          '$proxy/image',
        );
        DiaryService.add(
            '[TMDB] buildImageUrl: source=tmdb_proxy, worker=$proxy');
        DiaryService.add(
            '[TMDB] buildImageUrl wrap: in=$originalUrl out=$wrapped');
        return wrapped;
      } else {
        final reason = proxy.isEmpty
            ? 'worker URL 未配'
            : 'URL 不是 image.tmdb.org 开头 (不起作用)';
        DiaryService.add(
            '[TMDB] buildImageUrl: source=tmdb_proxy 但 passthrough, reason="$reason", in=$originalUrl');
      }
    } else {
      // v2.1.43: 配了 worker URL 但 TMDB 数据源选 direct, 一次性 hint
      final proxy = getTmdbProxyDomainSync();
      if (proxy.isNotEmpty) {
        if (!_tmdbDataSourceNoProxyHinted) {
          _tmdbDataSourceNoProxyHinted = true;
          DiaryService.add(
              '[TMDB] buildImageUrl hint: 配了 worker URL ($proxy) 但 TMDB 数据源选 direct, 加速不生效, 切到「TMDB Worker 加速」');
        }
      }
    }
    return originalUrl;
  }

  // v2.1.43: 一次性 hint flag
  static bool _tmdbDataSourceNoProxyHinted = false;

  // Bangumi 数据源 key 同步初始化（main.dart 启动时调用）
  //
  // v2.1.42 改: 跟 v2.1.41 TMDB warmup 一样, 读 prefs 后按 worker URL
  //   推断默认. 老值 (cf_worker / cors_proxy) → 'direct'.
  static Future<void> warmupBangumiConfig() async {
    if (_bangumiDataSourceCache == null) {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_bangumiDataSourceKey);
      if (stored == 'bangumi_proxy' || stored == 'direct') {
        _bangumiDataSourceCache = stored;
      } else {
        // 老值 / 没存 → 按 worker URL 推断默认
        final proxy = prefs.getString(_tmdbProxyDomainKey) ?? '';
        _bangumiDataSourceCache = proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
      }
    }
    if (_bangumiImageSourceCache == null) {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_bangumiImageSourceKey);
      if (stored == 'bangumi_proxy' || stored == 'direct') {
        _bangumiImageSourceCache = stored;
      } else {
        // 老值 / 没存 → 按 worker URL 推断默认
        final proxy = prefs.getString(_tmdbProxyDomainKey) ?? '';
        _bangumiImageSourceCache = proxy.isNotEmpty ? 'bangumi_proxy' : 'direct';
      }
    }
  }

  // 应用启动时调用一次，缓存到内存，后续 buildProxiedUrl 不再 await
  static Future<void> warmupCfWorkerConfig() async {
    await _ensureCfWorkerCache();
    await warmupBangumiConfig();
    // v2.0.77: 缓存豆瓣 cookie, 给 getImageUrl 高画质升级用
    if (_doubanCookieCache == null) {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_doubanCookieKey);
      _doubanCookieCache = (v == null || v.isEmpty) ? null : v;
    }
    // v2.0.93: 缓存 TMDB API key, 给详情页大头部用 (build 时同步判断)
    if (_tmdbApiKeyCache == null) {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_tmdbApiKeyKey);
      _tmdbApiKeyCache = (v == null || v.isEmpty) ? null : v;
    }
    // v2.0.97: 缓存 TMDB 数据源, 给 TmdbService._buildTmdbApiUrl 同步读
    if (_tmdbDataSourceCache == null) {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_tmdbDataSourceKey);
      if (stored == 'tmdb_proxy' || stored == 'direct') {
        _tmdbDataSourceCache = stored;
      } else {
        // 老值 / 没存 → 按 worker URL 推断默认
        final proxy = prefs.getString(_tmdbProxyDomainKey) ?? '';
        _tmdbDataSourceCache = proxy.isNotEmpty ? 'tmdb_proxy' : 'direct';
      }
    }
    // v2.1.41: 缓存 TMDB 代理 URL, 给 TmdbService._buildTmdbApiUrl /
    //   buildTmdbImageUrl 同步读
    if (_tmdbProxyDomainCache == null) {
      final prefs = await SharedPreferences.getInstance();
      _tmdbProxyDomainCache = prefs.getString(_tmdbProxyDomainKey) ?? '';
    }
  }
}
