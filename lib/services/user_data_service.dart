import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/preferred_ip.dart';

class UserDataService {
  static const String _serverUrlKey = 'server_url';
  static const String _usernameKey = 'username';
  static const String _passwordKey = 'password';
  static const String _cookiesKey = 'cookies';
  static const String _doubanDataSourceKey = 'douban_data_source';
  static const String _doubanImageSourceKey = 'douban_image_source';
  static const String _m3u8ProxyUrlKey = 'm3u8_proxy_url';
  static const String _cfWorkerEnabledKey = 'cf_worker_enabled';
  static const String _cfWorkerUrlKey = 'cf_worker_url';
  static const String _localSearchKey = 'local_search';
  static const String _isLocalModeKey = 'is_local_mode';
  
  // 内存缓存
  static bool? _isLocalModeCache;

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

  // 保存 CF Worker 代理开关
  static Future<void> saveCfWorkerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cfWorkerEnabledKey, enabled);
  }

  // 获取 CF Worker 代理开关（默认为 false）
  static Future<bool> getCfWorkerEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_cfWorkerEnabledKey) ?? false;
  }

  // 保存 CF Worker 代理 URL
  static Future<void> saveCfWorkerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cfWorkerUrlKey, url);
  }

  // 获取 CF Worker 代理 URL
  static Future<String> getCfWorkerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cfWorkerUrlKey) ?? '';
  }

  // 通用工具：根据目标 URL 构造代理后的 URL（仅当启用且配置了 URL 时）
  // - 普通 URL:  {CF_Worker_URL}/{URL编码后的目标URL}  (走 /?url= 通用代理)
  // - m3u8 URL: {CF_Worker_URL}/m3u8?url={URL编码后的目标URL}  (走专用 m3u8 端点,
  //             Worker 会解析 m3u8 并把所有 .ts 分片也重写为走 Worker, 实现端到端加速)
  // 优选 IP 加速: 如果有缓存的最优 IP, 域名替换为 IP 直连, 强制 SNI = 原域名
  //              (SNI 由调用方在底层 socket / media_kit 上强制)
  static Future<String> buildProxiedUrl(String targetUrl) async {
    final enabled = await getCfWorkerEnabled();
    final workerUrl = await getCfWorkerUrl();
    if (!enabled || workerUrl.isEmpty) return targetUrl;

    final isM3u8 = _isM3u8Url(targetUrl);
    final endpoint = isM3u8 ? '/m3u8?url=' : '/?url=';

    // 如果有优选 IP 缓存, 用 IP 替换域名
    // 配套强制 SNI 由调用方处理 (Dart http 包用 badCertificate 放行, libmpv 用 demuxer-lavf-o)
    if (await _isPreferredIpAvailable(workerUrl)) {
      final bestIp = await PreferredIp.getBestIp();
      if (bestIp != null) {
        return 'https://$bestIp$endpoint${Uri.encodeComponent(targetUrl)}';
      }
    }

    final clean = workerUrl.endsWith('/')
        ? workerUrl.substring(0, workerUrl.length - 1)
        : workerUrl;
    return '$clean$endpoint${Uri.encodeComponent(targetUrl)}';
  }

  // 判断优选 IP 缓存是否可用 (开关开 + 域名匹配)
  static Future<bool> _isPreferredIpAvailable(String workerUrl) async {
    final bestIp = await PreferredIp.getBestIp();
    if (bestIp == null) return false;
    final cachedDomain = await PreferredIp.getTestDomain();
    if (cachedDomain == null) return false;
    final currentDomain = Uri.tryParse(workerUrl)?.host;
    return currentDomain == cachedDomain;
  }

  // 给 libmpv / Dart http 用的: 获取当前应使用的 worker 域名 (用于强制 SNI)
  static Future<String?> getEffectiveWorkerDomain() async {
    final enabled = await getCfWorkerEnabled();
    if (!enabled) return null;
    final workerUrl = await getCfWorkerUrl();
    if (workerUrl.isEmpty) return null;
    return Uri.tryParse(workerUrl)?.host;
  }

  // 判断 URL 是否为 m3u8 播放列表 (兼容 ?type=m3u8 或 .m3u8 后缀)
  static bool _isM3u8Url(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) return true;
    if (lower.contains('type=m3u8')) return true;
    if (lower.contains('format=m3u8')) return true;
    return false;
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
}
