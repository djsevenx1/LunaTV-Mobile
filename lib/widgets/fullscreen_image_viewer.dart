import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gal/gal.dart';
import 'package:app_settings/app_settings.dart';
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
          return FadeTransition(
            opacity: animation,
            child: child,
          );
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
              ? const Color(0xFF1e1e1e).withValues(alpha: 0.95)
              : const Color(0xFFffffff).withValues(alpha: 0.95);
          final textColor = isDark ? Colors.white : const Color(0xFF2c3e50);
          final secondaryTextColor = isDark 
              ? Colors.white.withValues(alpha: 0.7)
              : const Color(0xFF2c3e50).withValues(alpha: 0.7);
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

  /// 检查并请求存储权限
  Future<bool> _checkStoragePermission() async {
    try {
      // 使用 gal 包检查权限
      final hasAccess = await Gal.hasAccess();
      
      if (hasAccess) {
        return true;
      }
      
      // 请求权限
      final granted = await Gal.requestAccess();
      
      if (!granted && mounted) {
        // 权限被拒绝，引导用户到设置页面
        showDialog(
          context: context,
          builder: (context) => Consumer<ThemeService>(
            builder: (context, themeService, child) {
              final isDark = themeService.isDarkMode;
              final textColor = isDark ? Colors.white : const Color(0xFF2c3e50);
              
              return AlertDialog(
                backgroundColor: isDark ? const Color(0xFF1e1e1e) : Colors.white,
                title: Text(
                  '需要存储权限',
                  style: FontUtils.poppins(color: textColor),
                ),
                content: Text(
                  '保存图片到相册需要存储权限，请在设置中允许此权限。',
                  style: FontUtils.poppins(color: textColor),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '取消',
                      style: FontUtils.poppins(color: textColor),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await AppSettings.openAppSettings();
                    },
                    child: Text(
                      '去设置',
                      style: FontUtils.poppins(color: textColor),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      }
      
      return granted;
    } catch (e) {
      print('权限检查失败: $e');
      return false;
    }
  }

  /// 保存图片到相册
  Future<void> _saveImageToGallery() async {
    if (_isSaving) return;
    
    setState(() {
      _isSaving = true;
    });

    try {
      // 检查权限
      final hasPermission = await _checkStoragePermission();
      if (!hasPermission) {
        setState(() {
          _isSaving = false;
        });
        return;
      }

      // 显示保存提示
      if (mounted) {
        final themeService = Provider.of<ThemeService>(context, listen: false);
        final isDark = themeService.isDarkMode;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '正在保存图片...',
              style: FontUtils.poppins(
                color: isDark ? Colors.white : Colors.white,
              ),
            ),
            backgroundColor: isDark 
                ? const Color(0xFF1e1e1e).withValues(alpha: 0.9)
                : const Color(0xFF2c3e50).withValues(alpha: 0.9),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // 获取缓存的图片数据
      final imageBytes = await _getCachedImageBytes();
      
      if (imageBytes == null) {
        throw Exception('无法获取图片数据');
      }

      // 保存到相册
      await Gal.putImageBytes(
        imageBytes,
        name: widget.title.replaceAll(RegExp(r'[^\w\s-]'), ''), // 清理文件名
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '图片已保存到相册',
              style: FontUtils.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.green.withValues(alpha: 0.8),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '保存失败: ${e.toString()}',
              style: FontUtils.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.red.withValues(alpha: 0.8),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
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
      listener = ImageStreamListener((ImageInfo imageInfo, bool synchronousCall) {
        final image = imageInfo.image;
        image.toByteData(format: ui.ImageByteFormat.png).then((byteData) {
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          } else {
            completer.completeError('无法获取图片数据');
          }
        }).catchError((error) {
          completer.completeError(error);
        });
        imageStream.removeListener(listener);
      }, onError: (exception, stackTrace) {
        completer.completeError(exception);
        imageStream.removeListener(listener);
      });
      
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
                  onTap: () => Navigator.of(context).pop(), // 点击背景区域关闭
                  child: Container(color: Colors.transparent),
                ),
              ),
              
              // 图片区域
              Center(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(), // 点击图片也关闭
                  onLongPress: _showSaveImageMenu, // 长按显示保存菜单
                  child: FutureBuilder<String>(
                    future: getImageUrl(widget.imageUrl, widget.source),
                    builder: (context, snapshot) {
                      final String imageUrl = snapshot.data ?? widget.imageUrl;
                      final headers = getImageRequestHeaders(imageUrl, widget.source);
                      
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