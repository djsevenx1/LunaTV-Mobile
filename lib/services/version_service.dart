import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

class VersionService {
  // v2.1.46: 不再 static const — 改成在 [checkForUpdate] 里动态读
  //   UserDataService.getTmdbProxyDomainSync() (v2.1.49 改: 复用
  //   TMDB 代理 URL 字段, 删了 v2.1.46 的独立 github_proxy_domain
  //   字段), 配了 worker URL 就走 worker (国内 GFW 可达), 没配走
  //   直连 api.github.com (用户自己负责 VPN / GFW). 保留 const
  //   写法给 [getReleaseUrl] 当 fallback URL 用 (release 详情页
  //   URL 跟 API URL 是不同的, release 页国内也 GFW 但用户可以
  //   浏览器开 VPN 看).
  static const String githubRepoUrl = 'https://github.com/djsevenx1/LunaTV-Mobile';
  static const String githubApiUrl = 'https://api.github.com/repos/djsevenx1/LunaTV-Mobile/releases/latest';

  // ★ v2.6.55: 硬编码当前版本号 (对齐 shiheng_oa_flutter)
  //   不用 PackageInfo.fromPlatform() 读 (会带 +build 后缀导致解析崩溃)
  //   每次发版同步更新此值即可
  static const String _currentVersion = '2.6.55';

  // ★ v2.6.55: 去掉 24h 节流 + dismissed 机制
  //   每次启动都检查, 有更新就弹窗 (跟 shiheng_oa_flutter 一致)
  //   用户关闭弹窗不会记录 dismissed, 下次启动仍会提示

  /// 检查是否有新版本
  ///
  /// v2.1.46 改: 走 [UserDataService.buildGithubApiUrl] 拼 URL —
  ///   配了 GitHub 代理 URL 走 worker 的 /github/repos/.../releases/latest
  ///   (国内 GFW 可达), 没配走直连 (跟 v2.1.45 之前行为一致).
  ///   拿到的 APK 直链用 [UserDataService.buildGithubReleaseAssetUrl]
  ///   改写成 worker 路径, app 内建下载器 (UpdateDialog) 直接拿来下.
  ///
  /// v2.1.47 改: 已被用户「忽略 / 关掉 / 稍后 / 按 back」dismiss 的版本
  ///   直接返回 null, 不弹 dialog. 下次 latest 升到 > dismissed 时再弹.
  ///   之前 [_dismissedVersionKey] 只在 user_menu.dart 主动调
  ///   [dismissVersion] 时写, 关掉 dialog 不算, 导致每次开 app 都弹.
  ///
  /// v2.1.50 改: 修复 v2.1.47 改过头导致的死锁 — 之前 dismissed 写入后
  ///   永远不重置, 但用户可能 dismiss 完没装 (装失败 / 取消 / 没流量
  ///   等), currentVersion 还是老版本, 下次启动 dismissed == latest
  ///   仍 return null → 永远看不到新版本 dialog, 除非 user 主动去
  ///   user_menu 重置 (没有这个按钮, 等于没救).
  ///   修: dismissed == latest 但 currentVersion < latest 时
  ///   (说明用户没装上), 自动清除 dismissed, 继续弹 dialog. dismissed
  ///   == latest 且 current == latest 时才真正 return null (用户
  ///   装了或 user 真的就是这个版本).
  static Future<VersionInfo?> checkForUpdate() async {
    // ★ v2.6.55: 简化 — 无节流, 无 dismissed, 每次启动都检查
    try {
      // 硬编码当前版本 (避免 PackageInfo 的 +build 后缀)
      final currentVersion = _currentVersion;

      // v2.1.46: GitHub API URL 走 worker 代理 (配了的话)
      // ★ v2.6.55: 多域名重试 (主域名被墙/超时 → 试 GitHub 直连)
      final apiUrl = UserDataService.buildGithubApiUrl(githubApiUrl);

      http.Response? response;
      for (final url in {apiUrl, githubApiUrl}) {
        try {
          response = await http.get(
            Uri.parse(url),
            headers: {
              'Accept': 'application/vnd.github.v3+json',
              'User-Agent': 'LunaTV-Mobile',
            },
          ).timeout(const Duration(seconds: 10));
          if (response.statusCode == 200) break;
        } catch (_) {
          continue; // 主域名失败 → 试下一个
        }
      }
      if (response == null || response.statusCode != 200) {
        DiaryService.add('[Version] GitHub API 全部域名失败');
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String? ?? '';
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
              apkDownloadUrl = UserDataService.buildGithubReleaseAssetUrl(url);
              break;
            }
          }
        }
      }
      final releasePageUrl = data['html_url'] as String?;

      // ★ v2.6.55: 比较版本号 (硬编码当前版本, 无 PackageInfo +build 后缀问题)
      if (_isNewerVersion(currentVersion, latestVersion)) {
        return VersionInfo(
          currentVersion: currentVersion,
          latestVersion: latestVersion,
          releaseNotes: releaseNotes,
          apkDownloadUrl: apkDownloadUrl,
          releasePageUrl: releasePageUrl,
        );
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
  
  // ★ v2.6.55: 去掉所有废弃方法 (dismissVersion/clearDismissedVersion/
  //   shouldShowUpdatePrompt/_shouldThrottleAutoCheck/_markAutoCheckDone).
  //   新流程: 无节流, 无 dismissed, 每次启动都检查, 有更新就弹窗.
  //   用户关闭弹窗不影响下次启动检查.
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
