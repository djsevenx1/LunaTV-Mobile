import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';

class TopTabSwitcher extends StatefulWidget {
  final String selectedTab;
  final Function(String) onTabChanged;

  const TopTabSwitcher({
    super.key,
    required this.selectedTab,
    required this.onTabChanged,
  });

  @override
  State<TopTabSwitcher> createState() => _TopTabSwitcherState();
}

class _TopTabSwitcherState extends State<TopTabSwitcher>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;

  // 用于跟踪鼠标悬停状态
  bool _isHoveringHome = false;
  bool _isHoveringHistory = false;
  bool _isHoveringFavorites = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _animation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    // 根据初始选中状态设置动画
    if (widget.selectedTab == '首页') {
      _animationController.value = 0.0;
    } else if (widget.selectedTab == '播放历史') {
      _animationController.value = 0.5;
    } else {
      _animationController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(TopTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTab != widget.selectedTab) {
      _animateToTab(widget.selectedTab);
    }
  }

  void _animateToTab(String tab) {
    // 防止动画进行中的重复调用
    if (_animationController.isAnimating) {
      return;
    }

    if (tab == '首页') {
      _animationController.animateTo(0.0);
    } else if (tab == '播放历史') {
      _animationController.animateTo(0.5);
    } else {
      _animationController.animateTo(1.0);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Center(
          child: Container(
            margin: const EdgeInsets.only(top: 20, bottom: 8),
            width: 240, // 增加宽度以容纳三个选项
            height: 32,
            decoration: BoxDecoration(
              color: themeService.isDarkMode
                  ? const Color(0xFF333333)
                  : const Color(0xFFe0e0e0),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              children: [
                // 动画背景胶囊
                AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) {
                    // 计算背景位置：0 = 首页(0), 0.5 = 播放历史(80), 1.0 = 收藏夹(160)
                    final double leftPosition = _animation.value * 160;
                    return Positioned(
                      left: leftPosition,
                      top: 0,
                      child: Container(
                        width: 80,
                        height: 32,
                        decoration: BoxDecoration(
                          color: themeService.isDarkMode
                              ? const Color(0xFF1e1e1e)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: themeService.isDarkMode
                                  ? Colors.black.withValues(alpha: 0.3)
                                  : Colors.black.withValues(alpha: 0.1),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                // 标签按钮
                Row(
                  children: [
                    // 首页按钮
                    Expanded(
                      child: _buildTabButton(
                          '首页', widget.selectedTab == '首页', 0, themeService),
                    ),
                    // 播放历史按钮
                    Expanded(
                      child: _buildTabButton('播放历史',
                          widget.selectedTab == '播放历史', 1, themeService),
                    ),
                    // 收藏夹按钮
                    Expanded(
                      child: _buildTabButton(
                          '收藏夹', widget.selectedTab == '收藏夹', 2, themeService),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建标签按钮
  Widget _buildTabButton(
      String label, bool isSelected, int index, ThemeService themeService) {
    final bool isPC = DeviceUtils.isPC();
    final bool isHovering = label == '首页'
        ? _isHoveringHome
        : label == '播放历史'
            ? _isHoveringHistory
            : _isHoveringFavorites;

    return SizedBox(
      height: 32,
      child: MouseRegion(
        cursor: isPC ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: isPC
            ? (_) {
                setState(() {
                  if (label == '首页') {
                    _isHoveringHome = true;
                  } else if (label == '播放历史') {
                    _isHoveringHistory = true;
                  } else {
                    _isHoveringFavorites = true;
                  }
                });
              }
            : null,
        onExit: isPC
            ? (_) {
                setState(() {
                  if (label == '首页') {
                    _isHoveringHome = false;
                  } else if (label == '播放历史') {
                    _isHoveringHistory = false;
                  } else {
                    _isHoveringFavorites = false;
                  }
                });
              }
            : null,
        child: GestureDetector(
          onTap: () {
            // 防止动画进行中的重复点击
            if (!_animationController.isAnimating) {
              widget.onTabChanged(label);
            }
          },
          behavior: HitTestBehavior.opaque,
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              // 计算当前按钮的文字颜色
              Color textColor;
              FontWeight fontWeight;

              if (label == '首页') {
                // 首页按钮：动画值为0时选中
                double progress = 1.0 - (_animation.value * 2).clamp(0.0, 1.0);
                textColor = Color.lerp(
                  themeService.isDarkMode
                      ? const Color(0xFFb0b0b0)
                      : const Color(0xFF7f8c8d),
                  themeService.isDarkMode
                      ? const Color(0xFFffffff)
                      : const Color(0xFF2c3e50),
                  progress,
                )!;
                fontWeight = progress > 0.5 ? FontWeight.w600 : FontWeight.w400;
              } else if (label == '播放历史') {
                // 播放历史按钮：动画值为0.5时选中
                double progress = 1.0 - ((_animation.value - 0.5).abs() * 2);
                progress = progress.clamp(0.0, 1.0);
                textColor = Color.lerp(
                  themeService.isDarkMode
                      ? const Color(0xFFb0b0b0)
                      : const Color(0xFF7f8c8d),
                  themeService.isDarkMode
                      ? const Color(0xFFffffff)
                      : const Color(0xFF2c3e50),
                  progress,
                )!;
                fontWeight = progress > 0.5 ? FontWeight.w600 : FontWeight.w400;
              } else {
                // 收藏夹按钮：动画值为1时选中
                double progress =
                    ((_animation.value - 0.5) * 2).clamp(0.0, 1.0);
                textColor = Color.lerp(
                  themeService.isDarkMode
                      ? const Color(0xFFb0b0b0)
                      : const Color(0xFF7f8c8d),
                  themeService.isDarkMode
                      ? const Color(0xFFffffff)
                      : const Color(0xFF2c3e50),
                  progress,
                )!;
                fontWeight = progress > 0.5 ? FontWeight.w600 : FontWeight.w400;
              }

              // PC端悬停时文字变绿色
              if (isPC && isHovering) {
                textColor = const Color(0xFF27AE60);
              }

              return Center(
                child: Text(
                  label,
                  style: FontUtils.poppins(
                    fontSize: 11,
                    fontWeight: fontWeight,
                    color: textColor,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
