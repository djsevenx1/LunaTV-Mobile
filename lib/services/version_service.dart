import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/user_data_service.dart';

class VersionService {
  // v2.1.46: 不再 static const — 改成在 [checkForUpdate] 里动态读
  //   UserDataService.getGithubProxyDomainSync(), 配了 worker URL
  //   就走 worker (国内 GFW 可达), 没配走直连 api.github.com (用户
  //   自己负责 VPN / GFW). 保留 const 写法给 [getReleaseUrl] 当
  //   fallback URL 用 (release 详情页 URL 跟 API URL 是不同的,
  //   release 页国内也 GFW 但用户可以浏览器开 VPN 看).
  static const String githubRepoUrl = 'https://github.com/djsevenx1/LunaTV-Mobile';
  static const String githubApiUrl = 'https://api.github.com/repos/djsevenx1/LunaTV-Mobile/releases/latest';
  static const String _lastCheckKey = 'last_version_check';
  static const String _dismissedVersionKey = 'dismissed_version';
  
  /// 检查是否有新版本
  ///
  /// v2.1.46 改: 走 [UserDataService.buildGithubApiUrl] 拼 URL —
  ///   配了 GitHub 代理 URL 走 worker 的 /github/repos/.../releases/latest
  ///   (国内 GFW 可达), 没配走直连 (跟 v2.1.45 之前行为一致).
  ///   拿到的 APK 直链用 [UserDataService.buildGithubReleaseAssetUrl]
  ///   改写成 worker 路径, app 内建下载器 (UpdateDialog) 直接拿来下.
  static Future<VersionInfo?> checkForUpdate() async {
    try {
      // 获取当前版本
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      
      // v2.1.46: GitHub API URL 走 worker 代理 (配了的话)
      final apiUrl = UserDataService.buildGithubApiUrl(githubApiUrl);

      // 从 GitHub API 获取最新 Release 信息
      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
        },
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final tagName = data['tag_name'] as String;
        final latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;
        final releaseNotes = data['body'] as String? ?? '';

        // 从 assets 数组里找第一个 .apk 资源,拿 browser_download_url
        String? apkDownloadUrl;
        final assets = data['assets'] as List<dynamic>?;
        if (assets != null) {
          for (final asset in assets) {
            if (asset is Map<String, dynamic>) {
              final name = (asset['name'] as String?) ?? '';
              final url = (asset['browser_download_url'] as String?) ?? '';
              if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
                // v2.1.46: APK 直链也走 worker 代理 (配了的话)
                apkDownloadUrl =
                    UserDataService.buildGithubReleaseAssetUrl(url);
                break;
              }
            }
          }
        }
        // release 详情页 URL(html_url),作为兜底
        // v2.1.46: html_url 指向 github.com 详情页, 不走 worker
        //   (worker 路由不代理这个 — 用户点开用浏览器访问, 让用户
        //    自己决定是否走 VPN). buildGithubApiUrl 不会改这个 URL.
        final releasePageUrl = data['html_url'] as String?;

        // 比较版本号
        if (_isNewerVersion(currentVersion, latestVersion)) {
          return VersionInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes,
            apkDownloadUrl: apkDownloadUrl,
            releasePageUrl: releasePageUrl,
          );
        }
      }
      
      return null;
    } catch (e) {
      print('检查版本更新失败: $e');
      return null;
    }
  }
  
  /// 获取 GitHub Release 页面 URL
  static String getReleaseUrl(String version) {
    return '$githubRepoUrl/releases/tag/v$version';
  }
  
  /// 比较版本号，判断是否有新版本
  static bool _isNewerVersion(String current, String latest) {
    final currentParts = current.split('.').map(int.parse).toList();
    final latestParts = latest.split('.').map(int.parse).toList();
    
    for (int i = 0; i < 3; i++) {
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      final latestPart = i < latestParts.length ? latestParts[i] : 0;
      
      if (latestPart > currentPart) return true;
      if (latestPart < currentPart) return false;
    }
    
    return false;
  }
  
  /// 检查是否应该显示更新提示（避免频繁提示）
  static Future<bool> shouldShowUpdatePrompt(String version) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 检查用户是否已忽略此版本
    final dismissedVersion = prefs.getString(_dismissedVersionKey);
    if (dismissedVersion == version) {
      return false;
    }
    
    // 检查上次检查时间（每天最多提示一次）
    final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final dayInMs = 24 * 60 * 60 * 1000;
    
    if (now - lastCheck < dayInMs) {
      return false;
    }
    
    // 更新最后检查时间
    await prefs.setInt(_lastCheckKey, now);
    return true;
  }
  
  /// 标记用户已忽略某个版本
  static Future<void> dismissVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedVersionKey, version);
  }
  
  /// 清除忽略记录（用于测试或重置）
  static Future<void> clearDismissedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dismissedVersionKey);
  }
}

class VersionInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  /// .apk 资源直链(从 release assets 里挑的)
  /// 没拿到时为 null,UI 应 fallback 到 releasePageUrl
  final String? apkDownloadUrl;
  /// Release 详情页 URL(GitHub html_url)
  final String? releasePageUrl;

  VersionInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    this.apkDownloadUrl,
    this.releasePageUrl,
  });
}
