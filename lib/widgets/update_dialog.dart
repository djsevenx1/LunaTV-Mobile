import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/version_service.dart';
import 'package:luna_tv/utils/font_utils.dart';

class UpdateDialog extends StatefulWidget {
  final VersionInfo versionInfo;

  const UpdateDialog({
    super.key,
    required this.versionInfo,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();

  /// 显示更新对话框
  static Future<void> show(
      BuildContext context, VersionInfo versionInfo) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(versionInfo: versionInfo),
    );
  }
}

class _UpdateDialogState extends State<UpdateDialog> {
  // v2.1.46: 内建下载器状态机
  //   - idle: 初始, 显示「下载并安装」按钮
  //   - downloading: 正在下, 显示进度条 + 取消
  //   - installing: 下完了, 调起安装器, 显示「正在启动安装器...」
  //   - error: 失败, 显示错误 + 重试
  //   - installed: 安装器已调起, dialog 即将关闭
  _DownloadPhase _phase = _DownloadPhase.idle;
  double _progress = 0.0;
  int _downloaded = 0;
  int _total = 0;
  String? _errorMessage;
  CancelToken? _cancelToken;
  String? _apkPath;

  // v2.1.46: 调 Android 端 [ApkInstallChannel] — FileProvider +
  //   Intent.ACTION_VIEW 调起系统 APK 安装器. 跟 AndroidManifest
  //   <provider> 段和 ApkInstallChannel.kt 对应.
  static const MethodChannel _apkInstallChannel =
      MethodChannel('org.moontechlab.lunatv/apk_install');

  @override
  void dispose() {
    // 关闭 dialog 时取消正在跑的下载, 避免内存泄漏
    _cancelToken?.cancel('dialog_disposed');
    super.dispose();
  }

  // v2.1.46: 内建下载 + 安装
  //   1. dio.download APK 到 path_provider.getTemporaryDirectory() 下的
  //      luna-tv-update-v{version}.apk (cache 目录, app 私有, 系统
  //      清理 cache 时会自动删)
  //   2. onReceiveProgress 实时回调, setState 更新进度条
  //   3. 下载完调 _apkInstallChannel installApk → ApkInstallChannel.kt
  //      → FileProvider → Intent.ACTION_VIEW → 系统 APK 安装器
  //   4. 失败/取消/没 APK 走兜底 (启动 release page URL)
  Future<void> _startDownload() async {
    final apkUrl = widget.versionInfo.apkDownloadUrl;
    if (apkUrl == null || apkUrl.isEmpty) {
      // 没 APK 直链 (release 没传 .apk) → 兜底跳 release 详情页
      await _openReleasePage();
      return;
    }

    setState(() {
      _phase = _DownloadPhase.downloading;
      _progress = 0.0;
      _downloaded = 0;
      _total = 0;
      _errorMessage = null;
      _cancelToken = CancelToken();
    });

    try {
      final dir = await getTemporaryDirectory();
      final fileName = 'luna-tv-update-v${widget.versionInfo.latestVersion}.apk';
      final filePath = '${dir.path}/$fileName';

      // 老 APK 残留先清掉, 避免「下载了 5MB 失败再重试, 文件被截断」
      final oldFile = File(filePath);
      if (await oldFile.exists()) {
        try {
          await oldFile.delete();
        } catch (_) {/* 忽略, 删不掉就走覆盖 */}
      }

      final dio = Dio();
      await dio.download(
        apkUrl,
        filePath,
        cancelToken: _cancelToken,
        options: Options(
          // github.com/objects.githubusercontent.com 不需要特殊头
          // worker 代理 (配了的话) 也不需要
          responseType: ResponseType.bytes,
          followRedirects: true,
          // 流式 body, 大 APK 不爆内存
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _downloaded = received;
            _total = total <= 0 ? 0 : total;
            _progress =
                _total > 0 ? (_downloaded / _total).clamp(0.0, 1.0) : 0.0;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.installing;
        _apkPath = filePath;
      });

      // v2.1.46: 调 Android 端 ApkInstallChannel
      //   - 成功: 调起系统 APK 安装器, 用户在安装器里点「安装」
      //   - 失败: catch exception, 进 error phase
      try {
        await _apkInstallChannel.invokeMethod<void>(
          'installApk',
          <String, dynamic>{'path': filePath},
        );
        DiaryService.add(
            '[Update] APK 下载完成, 调起安装器: path=$filePath, size=${_total}B');
        if (!mounted) return;
        setState(() {
          _phase = _DownloadPhase.installed;
        });
        // 留 1.5s 让用户看到「已调起安装器」提示, 再关 dialog
        await Future.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      } on PlatformException catch (e) {
        // v2.1.46: ApkInstallChannel 返的错误 (e.code 是
        //   INSTALL_FAILED / FILE_NOT_FOUND / NO_INSTALLER /
        //   PROVIDER_PATH_MISSING / INVALID_ARG)
        DiaryService.add(
            '[Update] 调起 APK 安装器失败: code=${e.code}, message=${e.message}');
        if (!mounted) return;
        setState(() {
          _phase = _DownloadPhase.error;
          _errorMessage = e.message ?? e.code;
        });
      } catch (e) {
        DiaryService.add('[Update] 调起 APK 安装器失败: $e');
        if (!mounted) return;
        setState(() {
          _phase = _DownloadPhase.error;
          _errorMessage = e.toString();
        });
      }
    } on DioException catch (e) {
      // 用户主动取消
      if (e.type == DioExceptionType.cancel) {
        DiaryService.add('[Update] 用户取消下载');
        if (!mounted) return;
        setState(() {
          _phase = _DownloadPhase.idle;
          _progress = 0.0;
        });
        return;
      }
      // 其他 dio 错误
      DiaryService.add(
          '[Update] 下载失败: type=${e.type}, code=${e.response?.statusCode}, message=${e.message}');
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.error;
        _errorMessage = _humanizeDioError(e);
      });
    } catch (e) {
      DiaryService.add('[Update] 下载异常: $e');
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.error;
        _errorMessage = e.toString();
      });
    }
  }

  // v2.1.47: 兜底 — 没 APK 直链 / 下载失败, 跳 release 详情页
  //   + dismiss (用户决定不下载, 下次不重复弹)
  Future<void> _openReleasePage() async {
    final url = widget.versionInfo.releasePageUrl ??
        VersionService.getReleaseUrl(widget.versionInfo.latestVersion);
    final uri = Uri.parse(url);
    // v2.1.47: 兜底跳浏览器也算 dismiss, 避免用户重复被问
    await VersionService.dismissVersion(widget.versionInfo.latestVersion);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // v2.1.46: 取消正在下载
  void _cancelDownload() {
    _cancelToken?.cancel('user_cancelled');
  }

  // v2.1.46: 重试
  void _retryDownload() {
    _startDownload();
  }

  // v2.1.47: 统一 dismiss + close — 所有用户主动关掉 dialog 的路径
  //   (忽略 / 稍后 / 关闭按钮 / 去 GitHub 看 / 按 back) 都调这个方法,
  //   写入 [_dismissedVersionKey] = latestVersion, 下次 [checkForUpdate]
  //   时 dismissed == latest → return null, 不重复弹窗.
  //   装机完成路径 (_phase == installed) **不**调这个 — 用户已升级,
  //   currentVersion 已经是 latest, 下次 checkForUpdate 不会弹.
  Future<void> _dismissAndClose() async {
    if (_phase == _DownloadPhase.installed) {
      // 装机成功, 直接关, 不写入 dismissed
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    await VersionService.dismissVersion(widget.versionInfo.latestVersion);
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // v2.1.46: 把 dio 错误转成人话
  String _humanizeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '网络超时, 检查网络后重试';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 404) return '服务器找不到文件 (404), release 可能已下架';
        if (code == 403) return '无权限下载 (403), 检查「GitHub 代理 URL」配置';
        if (code != null && code >= 500) return '服务器错误 ($code), 稍后重试';
        return '下载失败 ($code)';
      case DioExceptionType.cancel:
        return '已取消';
      case DioExceptionType.connectionError:
        return '网络连接失败, 检查网络';
      case DioExceptionType.badCertificate:
        return 'SSL 证书错误, 检查代理配置';
      case DioExceptionType.unknown:
        return e.message ?? '下载失败';
    }
  }

  // v2.1.46: 格式化字节数 (1024 → KB/MB)
  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return PopScope(
          // 下载中禁止 back 关闭 dialog (避免「下到一半 dialog 没了但 dio 还在跑」)
          canPop: _phase != _DownloadPhase.downloading,
          // v2.1.47: 按 back 关闭 dialog 也算 dismiss — 写入最新版本号,
          //   下次 [checkForUpdate] dismissed == latest → 不弹.
          //   装机成功 (_phase == installed) 时 current == latest,
          //   不写 dismissed 也无副作用, 但仍走统一逻辑.
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              VersionService.dismissVersion(widget.versionInfo.latestVersion);
            }
          },
          child: Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 0,
            backgroundColor: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              decoration: BoxDecoration(
                color: themeService.isDarkMode
                    ? const Color(0xFF2C2C2C)
                    : Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部装饰区域
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: themeService.isDarkMode
                          ? const Color(0xFF333333)
                          : const Color(0xFFF5F5F5),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF27AE60).withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _phase == _DownloadPhase.installing ||
                                    _phase == _DownloadPhase.installed
                                ? Icons.install_mobile_rounded
                                : _phase == _DownloadPhase.error
                                    ? Icons.error_outline_rounded
                                    : Icons.rocket_launch_rounded,
                            size: 40,
                            color: _phase == _DownloadPhase.error
                                ? const Color(0xFFef4444)
                                : const Color(0xFF27AE60),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _phase == _DownloadPhase.downloading
                              ? '正在下载 v${widget.versionInfo.latestVersion}'
                              : _phase == _DownloadPhase.installing
                                  ? '正在启动安装器'
                                  : _phase == _DownloadPhase.installed
                                      ? '已启动系统安装器'
                                      : _phase == _DownloadPhase.error
                                          ? '更新失败'
                                          : '发现新版本',
                          style: FontUtils.poppins(
                            context,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: themeService.isDarkMode
                                ? const Color(0xFFFFFFFF)
                                : const Color(0xFF2C2C2C),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 内容区域
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 版本信息卡片 (downloading 状态下也保留, 让用户知道下的是哪个版本)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: themeService.isDarkMode
                                ? const Color(0xFF333333)
                                : const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _buildVersionChip(
                                context,
                                themeService,
                                '当前版本',
                                widget.versionInfo.currentVersion,
                                Icons.info_outline_rounded,
                                themeService.isDarkMode
                                    ? const Color(0xFF999999)
                                    : const Color(0xFF666666),
                              ),
                              Container(
                                width: 1,
                                height: 40,
                                color: themeService.isDarkMode
                                    ? const Color(0xFF444444)
                                    : const Color(0xFFDDDDDD),
                              ),
                              _buildVersionChip(
                                context,
                                themeService,
                                '最新版本',
                                widget.versionInfo.latestVersion,
                                Icons.new_releases_rounded,
                                const Color(0xFF27AE60),
                              ),
                            ],
                          ),
                        ),

                        // v2.1.46: 进度条 (downloading / installing 状态下显示)
                        if (_phase == _DownloadPhase.downloading ||
                            _phase == _DownloadPhase.installing ||
                            _phase == _DownloadPhase.installed) ...[
                          const SizedBox(height: 20),
                          _buildProgressSection(themeService),
                        ],

                        // v2.1.46: 错误信息 (error 状态下显示)
                        if (_phase == _DownloadPhase.error) ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFef4444)
                                  .withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  size: 18,
                                  color: Color(0xFFef4444),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _errorMessage ?? '未知错误',
                                    style: FontUtils.poppins(
                                      context,
                                      fontSize: 13,
                                      color: const Color(0xFFef4444),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        // 更新说明 (idle 状态下显示, 其他状态隐藏, 避免挤)
                        if (_phase == _DownloadPhase.idle &&
                            widget.versionInfo.releaseNotes.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Icon(
                                Icons.article_outlined,
                                size: 18,
                                color: Color(0xFF27AE60),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '更新内容',
                                style: FontUtils.poppins(
                                  context,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: themeService.isDarkMode
                                      ? const Color(0xFFFFFFFF)
                                      : const Color(0xFF2C2C2C),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 200),
                            decoration: BoxDecoration(
                              color: themeService.isDarkMode
                                  ? const Color(0xFF333333)
                                  : const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SingleChildScrollView(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  widget.versionInfo.releaseNotes,
                                  style: FontUtils.poppins(
                                    context,
                                    fontSize: 14,
                                    color: themeService.isDarkMode
                                        ? const Color(0xFFCCCCCC)
                                        : const Color(0xFF666666),
                                  ).copyWith(height: 1.6),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // 底部按钮区域
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      children: [
                        _buildBottomButton(themeService),
                        const SizedBox(height: 8),
                        _buildSecondaryRow(themeService),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // v2.1.46: 进度条 + 已下/总大小 section
  Widget _buildProgressSection(ThemeService themeService) {
    final isIndeterminate = _total <= 0 && _phase == _DownloadPhase.downloading;
    final percentText = _phase == _DownloadPhase.downloading
        ? (isIndeterminate ? '下载中...' : '${(_progress * 100).toStringAsFixed(0)}%')
        : _phase == _DownloadPhase.installing
            ? '启动中...'
            : '已调起安装器, 在安装器里点「安装」';
    final sizeText = _phase == _DownloadPhase.downloading && _total > 0
        ? '${_formatBytes(_downloaded)} / ${_formatBytes(_total)}'
        : _phase == _DownloadPhase.downloading
            ? '已下载 ${_formatBytes(_downloaded)}'
            : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: isIndeterminate ? null : _progress,
            minHeight: 8,
            backgroundColor: themeService.isDarkMode
                ? const Color(0xFF444444)
                : const Color(0xFFE0E0E0),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF27AE60)),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              percentText,
              style: FontUtils.poppins(
                context,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: themeService.isDarkMode
                    ? const Color(0xFFCCCCCC)
                    : const Color(0xFF666666),
              ),
            ),
            if (sizeText.isNotEmpty)
              Text(
                sizeText,
                style: FontUtils.poppins(
                  context,
                  fontSize: 12,
                  color: themeService.isDarkMode
                      ? const Color(0xFF999999)
                      : const Color(0xFF999999),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // v2.1.46: 主按钮 (按 phase 切换行为)
  Widget _buildBottomButton(ThemeService themeService) {
    switch (_phase) {
      case _DownloadPhase.idle:
        // v2.1.47: 初始态 — 「下载并安装 vX.X.X」(主) + 「浏览器下载」(并列备选)
        //   - 有 APK: 内建下载是主路径, 浏览器下载是备选 (用户机器没装
        //     系统安装器 / 想看 release notes 完再下 / 内建下载器失败想换方式)
        //   - 没 APK (release 没传 .apk asset): 主按钮变成「查看新版本」
        //     (内部调 _openReleasePage 跳浏览器), 「浏览器下载」按钮隐藏
        //     避免冗余 (两个按钮都是跳浏览器)
        final hasApk = widget.versionInfo.apkDownloadUrl != null;
        return Row(
          children: [
            Expanded(
              flex: hasApk ? 2 : 1,
              child: SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: _startDownload,
                  icon: Icon(
                    hasApk
                        ? Icons.download_rounded
                        : Icons.open_in_new_rounded,
                    size: 18,
                  ),
                  label: Text(
                    hasApk
                        ? '下载并安装 v${widget.versionInfo.latestVersion}'
                        : '查看新版本',
                    style: FontUtils.poppins(
                      context,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF27AE60),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
            if (hasApk) ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: _openReleasePage,
                    icon: const Icon(Icons.public_rounded, size: 16),
                    label: Text(
                      '浏览器',
                      style: FontUtils.poppins(
                        context,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF3B82F6),
                      side: const BorderSide(
                          color: Color(0xFF3B82F6), width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );

      case _DownloadPhase.downloading:
        // 下载中: 「取消下载」
        return SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _cancelDownload,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: Text(
              '取消下载',
              style: FontUtils.poppins(
                context,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFef4444),
              side: const BorderSide(color: Color(0xFFef4444), width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );

      case _DownloadPhase.installing:
      case _DownloadPhase.installed:
        // 安装器已调起: 灰按钮 「启动中...」 / 「已启动」
        return SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            onPressed: null, // 禁用
            icon: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor:
                    AlwaysStoppedAnimation<Color>(Color(0xFF27AE60)),
              ),
            ),
            label: Text(
              _phase == _DownloadPhase.installing
                  ? '启动安装器...'
                  : '已启动, 1.5s 后关闭',
              style: FontUtils.poppins(
                context,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF27AE60).withOpacity(0.5),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );

      case _DownloadPhase.error:
        // 失败: 「重试下载」主按钮 + 「查看 release 详情」次按钮
        return SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            onPressed: _retryDownload,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(
              '重试下载',
              style: FontUtils.poppins(
                context,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF27AE60),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );
    }
  }

  // v2.1.46: 次要按钮行 (忽略 / 稍后 / 查看 release)
  Widget _buildSecondaryRow(ThemeService themeService) {
    if (_phase == _DownloadPhase.installing ||
        _phase == _DownloadPhase.installed) {
      // 调起安装器后次要按钮只显示「关闭」 — 装机成功直接关, 不 dismiss
      return SizedBox(
        width: double.infinity,
        child: TextButton(
          onPressed: _dismissAndClose,
          style: TextButton.styleFrom(
            foregroundColor: themeService.isDarkMode
                ? const Color(0xFF999999)
                : const Color(0xFF666666),
          ),
          child: Text(
            '关闭',
            style: FontUtils.poppins(context, fontSize: 14),
          ),
        ),
      );
    }
    if (_phase == _DownloadPhase.error) {
      // 失败: 左边「看 release 详情」右边「关闭」— 都 dismiss
      return Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () async {
                // v2.1.47: 跳 GitHub 也算 dismiss, 避免重复弹
                await VersionService.dismissVersion(
                    widget.versionInfo.latestVersion);
                if (!mounted) return;
                await _openReleasePage();
              },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF27AE60),
              ),
              child: Text(
                '去 GitHub 看',
                style: FontUtils.poppins(context, fontSize: 14),
              ),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: _dismissAndClose,
              style: TextButton.styleFrom(
                foregroundColor: themeService.isDarkMode
                    ? const Color(0xFF999999)
                    : const Color(0xFF666666),
              ),
              child: Text(
                '关闭',
                style: FontUtils.poppins(context, fontSize: 14),
              ),
            ),
          ),
        ],
      );
    }
    // idle / downloading: 「忽略」 + 「稍后」— v2.1.47 统一用 _dismissAndClose
    return Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: _phase == _DownloadPhase.downloading
                ? null
                : _dismissAndClose,
            style: TextButton.styleFrom(
              foregroundColor: themeService.isDarkMode
                  ? const Color(0xFF999999)
                  : const Color(0xFF666666),
            ),
            child: Text(
              '忽略',
              style: FontUtils.poppins(context, fontSize: 14),
            ),
          ),
        ),
        Expanded(
          child: TextButton(
            onPressed: _phase == _DownloadPhase.downloading
                ? null
                : _dismissAndClose,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF27AE60),
            ),
            child: Text(
              '稍后',
              style: FontUtils.poppins(context, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVersionChip(
    BuildContext context,
    ThemeService themeService,
    String label,
    String version,
    IconData icon,
    Color color,
  ) {
    return Column(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 4),
        Text(
          label,
          style: FontUtils.poppins(
            context,
            fontSize: 12,
            color: themeService.isDarkMode
                ? const Color(0xFF999999)
                : const Color(0xFF666666),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          version,
          style: FontUtils.poppins(
            context,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  /// 显示更新对话框
  static Future<void> show(
      BuildContext context, VersionInfo versionInfo) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(versionInfo: versionInfo),
    );
  }
}

// v2.1.46: 内建下载器状态机
enum _DownloadPhase {
  idle,
  downloading,
  installing,
  installed,
  error,
}
