import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/search_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/utils/text_context_menu.dart';
import 'package:luna_tv/widgets/user_menu.dart';

class MainLayout extends StatefulWidget {
  final Widget content;
  final int currentBottomNavIndex;
  final Function(int) onBottomNavChanged;
  final String selectedTopTab;
  final Function(String) onTopTabChanged;
  final bool isSearchMode;
  final VoidCallback? onSearchTap;
  final VoidCallback? onHomeTap;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final String? searchQuery;
  final Function(String)? onSearchQueryChanged;
  final Function(String)? onSearchSubmitted;
  final VoidCallback? onClearSearch;
  final bool showBottomNav;

  const MainLayout({
    super.key,
    required this.content,
    required this.currentBottomNavIndex,
    required this.onBottomNavChanged,
    required this.selectedTopTab,
    required this.onTopTabChanged,
    this.isSearchMode = false,
    this.onSearchTap,
    this.onHomeTap,
    this.searchController,
    this.searchFocusNode,
    this.searchQuery,
    this.onSearchQueryChanged,
    this.onSearchSubmitted,
    this.onClearSearch,
    this.showBottomNav = true,
  });

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  bool _isSearchButtonPressed = false;

  // 用于跟踪底部导航栏按钮的 hover 状态
  int? _hoveredNavIndex;

  // 用于跟踪搜索按钮的 hover 状态
  bool _isSearchButtonHovered = false;

  // 用于跟踪主题切换按钮的 hover 状态
  bool _isThemeButtonHovered = false;

  // 用于跟踪用户按钮的 hover 状态
  bool _isUserButtonHovered = false;

  // 用于跟踪返回按钮的 hover 状态
  bool _isBackButtonHovered = false;

  // 用于跟踪搜索框内清除按钮的 hover 状态
  bool _isClearButtonHovered = false;

  // 用于跟踪搜索框内搜索按钮的 hover 状态
  bool _isSearchSubmitButtonHovered = false;

  // 搜索建议相关状态
  List<String> _searchSuggestions = [];
  Timer? _debounceTimer;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  // v2.6.23: 弹层加 × 按钮, 用户可手动关掉当前弹层. 行为:
  //   - 输入新 query → 弹层继续弹 (跟改前一样)
  //   - 点 × → 只关掉当前这次弹层, 下次输入继续弹
  //   - 点空白 / 点外部 → 弹层消失 (跟改前一样)
  //   不维护「永久关掉」状态, 候选栏行为完全不变, 只多一个手动 × 入口.

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _fetchSearchSuggestions(String query) async {
    if (query.trim().isEmpty) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _searchSuggestions = [];
            });
            _removeOverlay();
          }
        });
      }
      return;
    }

    final currentQuery = query;
    final isLocalMode = await UserDataService.getIsLocalMode();
    final isLocalSearch = await UserDataService.getLocalSearch();

    List<String> suggestionResults;
    if (isLocalMode || isLocalSearch) {
      suggestionResults = await SearchService.searchRecommand(query.trim());
    } else {
      suggestionResults = await ApiService.getSearchSuggestions(query.trim());
    }

    // 检查搜索框内容是否已变化
    if (!mounted ||
        widget.searchQuery != currentQuery ||
        suggestionResults.isEmpty) {
      return;
    }

    // 使用 post-frame callback 确保在正确的时机更新状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.searchQuery != currentQuery) {
        return;
      }

      if (suggestionResults.isNotEmpty) {
        setState(() {
          _searchSuggestions = suggestionResults.take(8).toList();
        });
        // 再次使用 post-frame callback 显示 overlay
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _searchSuggestions.isNotEmpty) {
            _showSuggestionsOverlay();
          }
        });
      } else {
        setState(() {
          _searchSuggestions = [];
        });
        _removeOverlay();
      }
    });
  }

  void _onSearchQueryChanged(String query) {
    // 使用 post-frame callback 来调用父组件回调，避免在 build 期间触发 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSearchQueryChanged?.call(query);
    });

    // 取消之前的防抖计时器
    _debounceTimer?.cancel();

    if (query.trim().isEmpty) {
      // 使用 post-frame callback 来清除建议
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _searchSuggestions = [];
          });
          _removeOverlay();
        }
      });
      return;
    }

    // 设置新的防抖计时器（500ms）
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && query == widget.searchQuery) {
        _fetchSearchSuggestions(query);
      }
    });
  }

  void _showSuggestionsOverlay() {
    _removeOverlay();

    if (_searchSuggestions.isEmpty) {
      return;
    }

    final themeService = Provider.of<ThemeService>(context, listen: false);
    final isTablet = DeviceUtils.isTablet(context);

    // 计算建议框宽度
    // 平板模式：屏幕宽度的 50%
    // 移动端：屏幕宽度 - 左右padding(32) - 右侧按钮宽度(32*2) - 按钮间距(12) - 按钮与搜索框间距(16)
    final screenWidth = MediaQuery.of(context).size.width;
    final suggestionWidth =
        isTablet ? screenWidth * 0.5 : screenWidth - 32 - 16 - 32 - 12 - 32;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: suggestionWidth,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 42), // 紧贴搜索框
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: themeService.isDarkMode
                ? const Color(0xFF1e1e1e)
                : Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              // v2.6.23: Column 拆 header + ListView, header 显示「搜索建议」+ ×
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: themeService.isDarkMode
                              ? const Color(0xFF2a2a2a)
                              : const Color(0xFFecf0f1),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '搜索建议',
                            style: FontUtils.poppins(
                              context,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: themeService.isDarkMode
                                  ? const Color(0xFF888888)
                                  : const Color(0xFF95a5a6),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () {
                            // v2.6.23: 点 × 只关掉当前这次弹层, 不影响下次输入.
                            //   候选栏行为不变 (每次新 query 仍弹), 只多一个手动 × 入口.
                            _removeOverlay();
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              LucideIcons.x,
                              size: 14,
                              color: themeService.isDarkMode
                                  ? const Color(0xFF888888)
                                  : const Color(0xFF95a5a6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      itemCount: _searchSuggestions.length,
                      itemBuilder: (context, index) {
                        final suggestion = _searchSuggestions[index];
                        return InkWell(
                          onTap: () {
                            widget.searchController?.text = suggestion;
                            widget.onSearchSubmitted?.call(suggestion);
                            _removeOverlay();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.search,
                                  size: 16,
                                  color: themeService.isDarkMode
                                      ? const Color(0xFF666666)
                                      : const Color(0xFF95a5a6),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    suggestion,
                                    style: FontUtils.poppins(
                                      context,
                                      fontSize: 14,
                                      color: themeService.isDarkMode
                                          ? const Color(0xFFffffff)
                                          : const Color(0xFF2c3e50),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Theme(
          data: themeService.isDarkMode
              ? themeService.darkTheme
              : themeService.lightTheme,
          child: Scaffold(
            backgroundColor: themeService.isDarkMode
                ? const Color(0xFF0B0F1A)
                : Colors.transparent,
            resizeToAvoidBottomInset: !widget.isSearchMode,
            body: Container(
              decoration: BoxDecoration(
                color: themeService.isDarkMode
                    ? const Color(0xFF0B0F1A)
                    : null,
                gradient: themeService.isDarkMode
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFF7F8FC),
                          Color(0xFFF0F1FA),
                          Color(0xFFF3F1FA),
                          Color(0xFFEDEEF7),
                        ],
                        stops: [0.0, 0.4, 0.75, 1.0],
                      ),
              ),
              child: Stack(
                children: [
                  Column(
                    children: [
                      // Windows 自定义标题栏
                      _buildHeader(context, themeService),
                      // 主要内容区域
                      Expanded(
                        child: widget.content,
                      ),
                      // 底部导航栏（可选）
                      if (widget.showBottomNav)
                        _buildBottomNavBar(themeService),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, ThemeService themeService) {
    final isTablet = DeviceUtils.isTablet(context);

    // macOS 下需要额外的顶部 padding 来避免与透明标题栏重叠
    // Windows 下不需要额外 padding，因为自定义标题栏已经占据了空间
    final topPadding = DeviceUtils.isMacOS()
        ? MediaQuery.of(context).padding.top + 32
        : Platform.isWindows
            ? 8.0
            : MediaQuery.of(context).padding.top + 8;

    return Container(
      padding: EdgeInsets.only(
        top: topPadding,
        left: 16,
        right: 16,
        bottom: 8,
      ),
      decoration: BoxDecoration(
        color: widget.isSearchMode
            ? themeService.isDarkMode
                ? const Color(0xFF121828)
                : const Color(0xFFF0F1FA)
            : themeService.isDarkMode
                ? const Color(0xFF0B0F1A).withOpacity(0.92)
                : Colors.white.withOpacity(0.8),
      ),
      child: widget.isSearchMode
          ? _buildSearchHeader(context, themeService, isTablet)
          : _buildNormalHeader(context, themeService),
    );
  }

  Widget _buildNormalHeader(BuildContext context, ThemeService themeService) {
    return SizedBox(
      height: 40, // 固定高度，与搜索框高度一致
      child: Stack(
        children: [
          // 左侧 LUMI 渐变字标（点击回首页）
          Positioned(
            left: 0,
            top: 4,
            child: GestureDetector(
              onTap: widget.onHomeTap,
              behavior: HitTestBehavior.opaque,
              child: ShaderMask(
                shaderCallback: (bounds) =>
                    AppColors.primaryGradient.createShader(bounds),
                child: const Text(
                  'LUMI',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          // 右侧按钮组
          Positioned(
            right: 0,
            top: 4,
            child: _buildRightButtons(themeService),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHeader(
      BuildContext context, ThemeService themeService, bool isTablet) {
    final searchBoxWidget = CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        decoration: BoxDecoration(
          color:
              themeService.isDarkMode ? const Color(0xFF1e1e1e) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) {
              // 失焦时关闭建议框
              _removeOverlay();
            }
          },
          child: TextField(
            controller: widget.searchController,
            focusNode: widget.searchFocusNode,
            contextMenuBuilder: chineseTextSelectionToolbarBuilder,
            autofocus: false,
            textInputAction: TextInputAction.search,
            keyboardType: TextInputType.text,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: '搜索电影、剧集、动漫...',
              hintStyle: FontUtils.poppins(context,
                                color: themeService.isDarkMode
                    ? const Color(0xFF666666)
                    : const Color(0xFF95a5a6),
                fontSize: 14,
              ),
              suffixIcon: SizedBox(
                width: isTablet ? 80 : 80, // 固定宽度确保按钮位置一致
                child: Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    // 搜索按钮 - 固定在右侧
                    Positioned(
                      right: isTablet ? 8 : 12,
                      child: MouseRegion(
                        cursor:
                            (widget.searchQuery?.trim().isNotEmpty ?? false) &&
                                    DeviceUtils.isPC()
                                ? SystemMouseCursors.click
                                : MouseCursor.defer,
                        onEnter: DeviceUtils.isPC() &&
                                (widget.searchQuery?.trim().isNotEmpty ?? false)
                            ? (_) {
                                setState(() {
                                  _isSearchSubmitButtonHovered = true;
                                });
                              }
                            : null,
                        onExit: DeviceUtils.isPC() &&
                                (widget.searchQuery?.trim().isNotEmpty ?? false)
                            ? (_) {
                                setState(() {
                                  _isSearchSubmitButtonHovered = false;
                                });
                              }
                            : null,
                        child: GestureDetector(
                          onTap:
                              (widget.searchQuery?.trim().isNotEmpty ?? false)
                                  ? () {
                                      _removeOverlay();
                                      widget.onSearchSubmitted
                                          ?.call(widget.searchQuery!);
                                    }
                                  : null,
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: EdgeInsets.all(isTablet ? 6 : 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: DeviceUtils.isPC() &&
                                      _isSearchSubmitButtonHovered &&
                                      (widget.searchQuery?.trim().isNotEmpty ??
                                          false)
                                  ? (themeService.isDarkMode
                                      ? const Color(0xFF333333)
                                      : const Color(0xFFe0e0e0))
                                  : Colors.transparent,
                            ),
                            child: Icon(
                              LucideIcons.search,
                              color: (widget.searchQuery?.trim().isNotEmpty ??
                                      false)
                                  ? const Color(0xFF7C5CFF)
                                  : themeService.isDarkMode
                                      ? const Color(0xFFb0b0b0)
                                      : const Color(0xFF7f8c8d),
                              size: isTablet ? 18 : 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 清除按钮 - 在搜索按钮左侧（仅在有内容时显示）
                    Positioned(
                      right: isTablet ? 42 : 44,
                      child: Visibility(
                        visible: widget.searchQuery?.isNotEmpty ?? false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: MouseRegion(
                          cursor: DeviceUtils.isPC()
                              ? SystemMouseCursors.click
                              : MouseCursor.defer,
                          onEnter: DeviceUtils.isPC()
                              ? (_) {
                                  setState(() {
                                    _isClearButtonHovered = true;
                                  });
                                }
                              : null,
                          onExit: DeviceUtils.isPC()
                              ? (_) {
                                  setState(() {
                                    _isClearButtonHovered = false;
                                  });
                                }
                              : null,
                          child: GestureDetector(
                            onTap: () {
                              _removeOverlay();
                              widget.onClearSearch?.call();
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: EdgeInsets.all(isTablet ? 6 : 8),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color:
                                    DeviceUtils.isPC() && _isClearButtonHovered
                                        ? (themeService.isDarkMode
                                            ? const Color(0xFF333333)
                                            : const Color(0xFFe0e0e0))
                                        : Colors.transparent,
                              ),
                              child: Icon(
                                LucideIcons.x,
                                color: themeService.isDarkMode
                                    ? const Color(0xFFb0b0b0)
                                    : const Color(0xFF7f8c8d),
                                size: isTablet ? 18 : 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              isDense: true,
            ),
            style: FontUtils.poppins(context,
                            fontSize: 14,
              color: themeService.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF2c3e50),
            ).copyWith(height: 1.2),
            onSubmitted: (value) {
              _removeOverlay();
              widget.onSearchSubmitted?.call(value);
            },
            onChanged: _onSearchQueryChanged,
            onTap: () {
              // 聚焦时如果有内容，显示建议
              if (widget.searchQuery?.trim().isNotEmpty ?? false) {
                _fetchSearchSuggestions(widget.searchQuery!);
              }
            },
          ),
        ),
      ),
    );

    // 平板模式下居中
    if (isTablet) {
      return SizedBox(
        height: 40, // 固定高度
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 左侧返回按钮
            Positioned(
              left: 0,
              child: MouseRegion(
                cursor: DeviceUtils.isPC()
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                onEnter: DeviceUtils.isPC()
                    ? (_) {
                        setState(() {
                          _isBackButtonHovered = true;
                        });
                      }
                    : null,
                onExit: DeviceUtils.isPC()
                    ? (_) {
                        setState(() {
                          _isBackButtonHovered = false;
                        });
                      }
                    : null,
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: DeviceUtils.isPC() && _isBackButtonHovered
                          ? (themeService.isDarkMode
                              ? const Color(0xFF333333)
                              : const Color(0xFFe0e0e0))
                          : Colors.transparent,
                    ),
                    child: Center(
                      child: Icon(
                        LucideIcons.arrowLeft,
                        color: themeService.isDarkMode
                            ? const Color(0xFFffffff)
                            : const Color(0xFF2c3e50),
                        size: 24,
                        weight: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 搜索框在整个屏幕水平居中
            Center(
              child: SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                child: searchBoxWidget,
              ),
            ),
            // 右侧按钮 - 垂直居中
            Positioned(
              right: 0,
              child: _buildRightButtons(themeService),
            ),
          ],
        ),
      );
    }

    // 非平板模式下，搜索框居左，右侧留出按钮空间
    return SizedBox(
      height: 40, // 固定高度
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: searchBoxWidget),
          const SizedBox(width: 16),
          _buildRightButtons(themeService),
        ],
      ),
    );
  }

  Widget _buildRightButtons(ThemeService themeService) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 搜索按钮
        MouseRegion(
          cursor:
              DeviceUtils.isPC() ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isSearchButtonHovered = true;
                  });
                }
              : null,
          onExit: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isSearchButtonHovered = false;
                  });
                }
              : null,
          child: GestureDetector(
            onTap: () {
              // 防止重复点击
              if (_isSearchButtonPressed) return;

              setState(() {
                _isSearchButtonPressed = true;
              });

              widget.onSearchTap?.call();

              // 延迟重置按钮状态，防止快速重复点击
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted) {
                  setState(() {
                    _isSearchButtonPressed = false;
                  });
                }
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: DeviceUtils.isPC() && _isSearchButtonHovered
                    ? (themeService.isDarkMode
                        ? const Color(0xFF1A2133)
                        : const Color(0xFFE5E8F2))
                    : (themeService.isDarkMode
                        ? const Color(0xFF121828)
                        : const Color(0xFFEEF0F8)),
              ),
              child: Center(
                child: Icon(
                  LucideIcons.search,
                  color: themeService.isDarkMode
                      ? const Color(0xFFEDF0F7)
                      : const Color(0xFF1A2133),
                  size: 20,
                  weight: 1.0,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 深浅模式切换按钮
        MouseRegion(
          cursor:
              DeviceUtils.isPC() ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isThemeButtonHovered = true;
                  });
                }
              : null,
          onExit: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isThemeButtonHovered = false;
                  });
                }
              : null,
          child: GestureDetector(
            onTap: () {
              themeService.toggleTheme();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: DeviceUtils.isPC() && _isThemeButtonHovered
                    ? (themeService.isDarkMode
                        ? const Color(0xFF1A2133)
                        : const Color(0xFFE5E8F2))
                    : (themeService.isDarkMode
                        ? const Color(0xFF121828)
                        : const Color(0xFFEEF0F8)),
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: child,
                    );
                  },
                  child: Icon(
                    themeService.isDarkMode
                        ? LucideIcons.sun
                        : LucideIcons.moon,
                    key: ValueKey(themeService.isDarkMode),
                    color: themeService.isDarkMode
                        ? const Color(0xFFEDF0F7)
                        : const Color(0xFF1A2133),
                    size: 20,
                    weight: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 用户按钮
        MouseRegion(
          cursor:
              DeviceUtils.isPC() ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isUserButtonHovered = true;
                  });
                }
              : null,
          onExit: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isUserButtonHovered = false;
                  });
                }
              : null,
          child: GestureDetector(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => UserMenu(
                    isDarkMode: themeService.isDarkMode,
                  ),
                ),
              );
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: DeviceUtils.isPC() && _isUserButtonHovered
                    ? (themeService.isDarkMode
                        ? const Color(0xFF1A2133)
                        : const Color(0xFFE5E8F2))
                    : (themeService.isDarkMode
                        ? const Color(0xFF121828)
                        : const Color(0xFFEEF0F8)),
              ),
              child: Center(
                child: Icon(
                  LucideIcons.user,
                  color: themeService.isDarkMode
                      ? const Color(0xFFEDF0F7)
                      : const Color(0xFF1A2133),
                  size: 20,
                  weight: 1.0,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNavBar(ThemeService themeService) {
    final List<Map<String, dynamic>> navItems = [
      {'icon': LucideIcons.house, 'label': '首页'},
      {'icon': LucideIcons.video, 'label': '电影'},
      {'icon': LucideIcons.tv, 'label': '剧集'},
      {'icon': LucideIcons.cat, 'label': '动漫'},
      {'icon': LucideIcons.clapperboard, 'label': '短剧'},
      {'icon': LucideIcons.clover, 'label': '综艺'},
    ];

    final isPC = DeviceUtils.isPC();
    final bottomPad = MediaQuery.of(context).padding.bottom + 6;

    // 简洁底部条：半透明深色 + 顶部细边框（无毛玻璃药丸）
    return Container(
      decoration: BoxDecoration(
        color: themeService.isDarkMode
            ? const Color(0xFF0B0F1A).withOpacity(0.94)
            : Colors.white.withOpacity(0.88),
        border: Border(
          top: BorderSide(
            color: themeService.isDarkMode
                ? const Color(0xFF1A2133)
                : const Color(0xFFE5E8F2),
            width: 0.5,
          ),
        ),
      ),
      padding: EdgeInsets.only(bottom: bottomPad),
      child: Row(
        children: List.generate(navItems.length, (index) {
          final item = navItems[index];
          final isSelected =
              !widget.isSearchMode && widget.currentBottomNavIndex == index;
          return _buildNavItem(
            item: item,
            index: index,
            isSelected: isSelected,
            isPC: isPC,
            themeService: themeService,
          );
        }),
      ),
    );
  }

  /// 单个底部导航项：图标 + 文字 + 激活渐变下划线
  Widget _buildNavItem({
    required Map<String, dynamic> item,
    required int index,
    required bool isSelected,
    required bool isPC,
    required ThemeService themeService,
  }) {
    final Color color = isSelected
        ? (themeService.isDarkMode
            ? const Color(0xFFEDF0F7)
            : const Color(0xFF1A2133))
        : (themeService.isDarkMode
            ? const Color(0xFF6B7280)
            : const Color(0xFF9BA3B5));

    return Expanded(
      child: MouseRegion(
        cursor: isPC ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: isPC
            ? (_) => setState(() => _hoveredNavIndex = index)
            : null,
        onExit: isPC
            ? (_) => setState(() => _hoveredNavIndex = null)
            : null,
        child: GestureDetector(
          onTap: () => widget.onBottomNavChanged(index),
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              // 图标（激活加渐变辉光）
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: isSelected ? 40 : 36,
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: isSelected
                      ? AppColors.primaryGradient.withOpacity(0.18)
                      : null,
                ),
                child: Icon(
                  item['icon'],
                  size: 21,
                  color: isSelected
                      ? (themeService.isDarkMode
                          ? const Color(0xFFEDF0F7)
                          : AppColors.primary)
                      : color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item['label'],
                style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  color: isSelected
                      ? (themeService.isDarkMode
                          ? const Color(0xFFEDF0F7)
                          : AppColors.primary)
                      : color,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 6),
              // 激活渐变下划线
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: isSelected ? 24 : 0,
                height: 2,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  gradient: isSelected ? AppColors.primaryGradient : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}