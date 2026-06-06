import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../utils/image_url.dart';
import '../utils/font_utils.dart';
import '../services/theme_service.dart';

/// 全屏图片查看器
class FullscreenImageViewer extends StatefulWidget {
  final String imageUrl;
  final String source;
  final String title;
  const FullscreenImageViewer({
    super.key,
    required this.imageUrl,
    required this.source,
    required this.title,
  });

  /// 显示全屏图片查看器
  static void show(
    BuildContext context, {
    required String imageUrl,
    required String source,
    required String title,
  }) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) => FullscreenImageViewer(
          imageUrl: imageUrl,
          source: source,
          title: title,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  State<FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<FullscreenImageViewer> {
  bool _isSaving = false;

  /// 显示保存图片选择菜单
  void _showSaveImageMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Consumer<ThemeService>(
        builder: (context, themeService, child) {
          final isDark = themeService.isDarkMode;
          final backgroundColor = isDark
              ? const Color(0xFF1e1e1e).withOpacity(0.95)
              : const Color(0xFFffffff).withOpacity(0.95);
          final textColor = isDark
              ? Colors.white
              : const Color(0xFF2c3e50);
          final secondaryTextColor = isDark
              ? Colors.white.withOpacity(0.7)
              : const Color(0xFF2c3e50).withOpacity(0.7);
          return Container(
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Text(
                      '保存图片',
                      style: FontUtils.poppins(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 选项列表
                  ListTile(
                    leading: Icon(
                      Icons.download,
                      color: textColor,
                    ),
                    title: Text(
                      '保存到相册',
                      style: FontUtils.poppins(
                        color: textColor,
                        fontSize: 16,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _saveImageToGallery();
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.close,
                      color: secondaryTextColor,
                    ),
                    title: Text(
                      '取消',
                      style: FontUtils.poppins(
                        color: secondaryTextColor,
                        fontSize: 16,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  // 底部安全区域
                  SizedBox(height: MediaQuery.of(context).padding.bottom),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 检查并请求存储权限（当前最小兼容实现）
  Future<bool> _checkStoragePermission() async {
    return true;
  }

  /// 保存图片到相册（当前最小兼容实现）
  Future<void> _saveImageToGallery() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('保存功能后续补全'),
        backgroundColor: Colors.grey.withOpacity(0.8),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 获取缓存的图片数据
  Future<Uint8List?> _getCachedImageBytes() async {
    try {
      // 使用 CachedNetworkImage 的缓存机制获取图片数据
      final imageProvider = CachedNetworkImageProvider(
        widget.imageUrl,
        headers: getImageRequestHeaders(widget.imageUrl, widget.source),
      );

      // 获取图片数据
      final imageStream = imageProvider.resolve(ImageConfiguration.empty);
      final completer = Completer<Uint8List>();
      late ImageStreamListener listener;

      listener = ImageStreamListener(
        (ImageInfo imageInfo, bool synchronousCall) {
          final image = imageInfo.image;
          image
              .toByteData(format: ui.ImageByteFormat.png)
              .then((byteData) {
            if (byteData != null) {
              completer.complete(byteData.buffer.asUint8List());
            } else {
              completer.completeError('无法获取图片数据');
            }
          }).catchError((error) {
            completer.completeError(error);
          });
          imageStream.removeListener(listener);
        },
        onError: (exception, stackTrace) {
          completer.completeError(exception);
          imageStream.removeListener(listener);
        },
      );
      imageStream.addListener(listener);

      return await completer.future;
    } catch (e) {
      print('获取缓存图片数据失败: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;
        final backgroundColor = isDark ? Colors.black : Colors.white;
        final textColor = isDark ? Colors.white : const Color(0xFF2c3e50);
        final progressIndicatorColor = isDark ? Colors.white : const Color(0xFF2c3e50);

        return Scaffold(
          backgroundColor: backgroundColor,
          body: Stack(
            children: [
              // 背景点击区域
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  // 点击背景区域关闭
                  child: Container(color: Colors.transparent),
                ),
              ),
              // 图片区域
              Center(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  // 点击图片也关闭
                  onLongPress: _showSaveImageMenu, // 长按显示保存菜单
                  child: FutureBuilder<String>(
                    future: getImageUrl(widget.imageUrl, widget.source),
                    builder: (context, snapshot) {
                      final String imageUrl = snapshot.data ?? widget.imageUrl;
                      final headers = getImageRequestHeaders(
                        imageUrl,
                        widget.source,
                      );

                      return CachedNetworkImage(
                        imageUrl: imageUrl,
                        httpHeaders: headers,
                        fit: BoxFit.fitWidth,
                        width: MediaQuery.of(context).size.width,
                        placeholder: (context, url) => Container(
                          color: backgroundColor,
                          width: MediaQuery.of(context).size.width,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(
                                  color: progressIndicatorColor,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '加载中...',
                                  style: FontUtils.poppins(
                                    color: textColor,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: backgroundColor,
                          width: MediaQuery.of(context).size.width,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: textColor,
                                  size: 48,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '图片加载失败',
                                  style: FontUtils.poppins(
                                    color: textColor,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
