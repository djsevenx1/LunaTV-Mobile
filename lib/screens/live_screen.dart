import 'package:flutter/material.dart';
import '../services/live_service.dart';
import '../models/live_channel.dart';
import '../models/live_source.dart';
import '../utils/font_utils.dart';
import '../utils/device_utils.dart';
import '../services/theme_service.dart';
import 'package:provider/provider.dart';
import 'live_player_screen.dart';
import '../widgets/filter_pill_hover.dart';
import '../widgets/filter_options_selector.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen>
    with SingleTickerProviderStateMixin {
  List<LiveChannelGroup> _channelGroups = [];
  List<LiveSource> _liveSources = [];
  LiveSource? _currentSource;
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isInitialLoad = true; // 标记是否是首次加载
  String? _errorMessage;
  String _selectedGroup = '全部';
  final ScrollController _scrollController = ScrollController();
  late AnimationController _refreshIconController;
  bool _isRefreshButtonHovered = false;

  @override
  void initState() {
    super.initState();
    _refreshIconController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _loadChannels();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _refreshIconController.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    if (!mounted) return;

    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _loadChannels({LiveSource? source}) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. 获取所有直播源
      final liveSources = await LiveService.getLiveSources();
      if (!mounted) return;

      if (liveSources.isEmpty) {
        setState(() {
          _errorMessage = '暂无直播源';
          _isLoading = false;
          _isInitialLoad = false;
          _liveSources = [];
          _currentSource = null;
        });
        return;
      }

      // 2. 确定要使用的直播源
      final targetSource = source ?? _currentSource ?? liveSources.first;

      // 在确定加载源后立即展示源筛选（更新状态）
      if (mounted) {
        setState(() {
          _liveSources = liveSources;
          _currentSource = targetSource;
          _isInitialLoad = false;
        });
      }

      // 3. 获取该直播源的频道列表
      final channels = await LiveService.getLiveChannels(targetSource.key);
      if (!mounted) return;

      if (channels.isEmpty) {
        setState(() {
          _errorMessage = '该直播源暂无频道';
          _isLoading = false;
        });
        return;
      }

      // 4. 按 group 进行聚类
      final Map<String, List<LiveChannel>> groupedChannels = {};
      for (var channel in channels) {
        final groupName = channel.group.isEmpty ? '未分组' : channel.group;
        if (!groupedChannels.containsKey(groupName)) {
          groupedChannels[groupName] = [];
        }
        groupedChannels[groupName]!.add(channel);
      }

      // 5. 转换为 LiveChannelGroup 列表
      final groups = groupedChannels.entries
          .map((entry) => LiveChannelGroup(
                name: entry.key,
                channels: entry.value,
              ))
          .toList();

      if (mounted) {
        setState(() {
          _channelGroups = groups;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '加载失败: $e';
          _isLoading = false;
          _isInitialLoad = false;
        });
      }
    }
  }

  Future<void> refreshChannels() async {
    if (!mounted) return;

    setState(() {
      _isRefreshButtonHovered = false;
      _isRefreshing = true;
      _errorMessage = null;
    });

    // 开始旋转动画
    _refreshIconController.repeat();

    try {
      LiveService.clearAllChannelsAndEpgCache();
      // 1. 重新获取所有直播源
      final liveSources = await LiveService.getLiveSources(forceRefresh: true);
      if (!mounted) return;

      if (liveSources.isEmpty) {
        setState(() {
          _errorMessage = '暂无直播源';
          _liveSources = [];
          _currentSource = null;
        });
        return;
      }

      // 2. 检查当前源是否还存在
      LiveSource? targetSource;
      if (_currentSource != null) {
        // 尝试在新的源列表中找到当前源
        try {
          targetSource = liveSources.firstWhere(
            (source) => source.key == _currentSource!.key,
          );
        } catch (e) {
          // 当前源不存在，使用第一个源
          targetSource = liveSources.first;
          if (mounted) {
            _showMessage('当前源已不存在，已切换到 ${targetSource.name}');
          }
        }
      } else {
        // 没有当前源，使用第一个源
        targetSource = liveSources.first;
      }

      // 3. 获取目标源的频道列表
      final channels = await LiveService.getLiveChannels(targetSource.key);
      if (!mounted) return;

      if (channels.isEmpty) {
        setState(() {
          _errorMessage = '该直播源暂无频道';
          _liveSources = liveSources;
          _currentSource = targetSource;
        });
        return;
      }

      // 4. 按 group 进行聚类
      final Map<String, List<LiveChannel>> groupedChannels = {};
      for (var channel in channels) {
        final groupName = channel.group.isEmpty ? '未分组' : channel.group;
        if (!groupedChannels.containsKey(groupName)) {
          groupedChannels[groupName] = [];
        }
        groupedChannels[groupName]!.add(channel);
      }

      // 5. 转换为 LiveChannelGroup 列表
      final groups = groupedChannels.entries
          .map((entry) => LiveChannelGroup(
                name: entry.key,
                channels: entry.value,
              ))
          .toList();

      if (mounted) {
        setState(() {
          _channelGroups = groups;
          _liveSources = liveSources;
          _currentSource = targetSource;
        });
        // _showMessage('刷新成功');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '刷新失败: $e';
        });
        _showMessage('刷新失败: $e');
      }
    } finally {
      // 停止旋转动画
      if (mounted) {
        _refreshIconController.stop();
        _refreshIconController.reset();
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: FontUtils.poppins(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF3498DB),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  List<LiveChannel> _getFilteredChannels() {
    if (_selectedGroup == '全部') {
      return _channelGroups.expand((g) => g.channels).toList();
    } else {
      return _channelGroups
          .firstWhere((g) => g.name == _selectedGroup,
              orElse: () => LiveChannelGroup(name: '', channels: []))
          .channels;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Column(
          children: [
            _buildTopBar(themeService),
            Expanded(
              child: _isRefreshing
                  ? _buildRefreshingView(themeService)
                  : _isLoading
                      ? _buildLoadingView(themeService)
                      : _errorMessage != null
                          ? _buildErrorView(themeService)
                          : _buildChannelList(themeService),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTopBar(ThemeService themeService) {
    final allGroups = ['全部', ..._channelGroups.map((g) => g.name)];

    // 构建分组选项
    final groupOptions =
        allGroups.map((g) => SelectorOption(label: g, value: g)).toList();

    // 构建直播源选项
    final sourceOptions = _liveSources
        .map((s) => SelectorOption(label: s.name, value: s.key))
        .toList();

    // 判断是否只有一个直播源
    final showSourceFilter = _liveSources.length > 1;

    // 首次加载时隐藏分组筛选
    final showGroupFilter = !_isInitialLoad && _channelGroups.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      decoration: BoxDecoration(
        color: themeService.isDarkMode
            ? const Color(0xFF1e1e1e).withOpacity( 0.9)
            : Colors.white.withOpacity( 0.8),
      ),
      child: Row(
        children: [
          // 直播源筛选（只有多个源时显示）
          if (showSourceFilter) ...[
            _buildFilterPill(
              '直播源',
              sourceOptions,
              _currentSource?.key ?? '',
              (value) {
                final source = _liveSources.firstWhere((s) => s.key == value);
                // 立即更新选中的源
                setState(() {
                  _currentSource = source;
                  _selectedGroup = '全部';
                });
                _loadChannels(source: source);
                _scrollToTop();
              },
              themeService,
            ),
            const SizedBox(width: 8),
          ],
          // 分组筛选（首次加载完成后才显示）
          if (showGroupFilter)
            _buildFilterPill(
              '分组',
              groupOptions,
              _selectedGroup,
              (value) {
                setState(() {
                  _selectedGroup = value;
                });
                _scrollToTop();
              },
              themeService,
            ),
          const Spacer(),
          // 刷新按钮
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: MouseRegion(
              cursor: DeviceUtils.isPC() && !_isRefreshing
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              onEnter: DeviceUtils.isPC() && !_isRefreshing
                  ? (_) {
                      setState(() {
                        _isRefreshButtonHovered = true;
                      });
                    }
                  : null,
              onExit: DeviceUtils.isPC() && !_isRefreshing
                  ? (_) {
                      setState(() {
                        _isRefreshButtonHovered = false;
                      });
                    }
                  : null,
              child: GestureDetector(
                onTap: _isRefreshing ? null : refreshChannels,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(
                    child: RotationTransition(
                      turns: _refreshIconController,
                      child: Icon(
                        Icons.refresh,
                        size: 20,
                        color: _isRefreshing
                            ? const Color(0xFF27ae60)
                            : (DeviceUtils.isPC() && _isRefreshButtonHovered
                                ? const Color(0xFF27ae60)
                                : (themeService.isDarkMode
                                    ? Colors.grey[600]
                                    : Colors.grey[500])),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPill(
    String title,
    List<SelectorOption> options,
    String selectedValue,
    ValueChanged<String> onSelected,
    ThemeService themeService,
  ) {
    final selectedOption = options.firstWhere(
      (e) => e.value == selectedValue,
      orElse: () => options.first,
    );
    final isDefault = selectedValue == '全部' || selectedValue.isEmpty;

    return FilterPillHover(
      isPC: DeviceUtils.isPC(),
      isDefault: isDefault,
      title: title,
      selectedOption: selectedOption,
      onTap: () {
        _showFilterOptions(context, title, options, selectedValue, onSelected);
      },
    );
  }

  void _showFilterOptions(
      BuildContext context,
      String title,
      List<SelectorOption> options,
      String selectedValue,
      ValueChanged<String> onSelected) {
    if (DeviceUtils.isPC()) {
      // PC端使用 filter_options_selector.dart 中的 PC 组件
      showFilterOptionsSelector(
        context: context,
        title: title,
        options: options,
        selectedValue: selectedValue,
        onSelected: onSelected,
        useCompactLayout: title == '分组', // 只有标题筛选使用紧凑布局
      );
    } else {
      // 移动端显示底部弹出
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) {
          final screenWidth = MediaQuery.of(context).size.width;
          final modalWidth =
              DeviceUtils.isTablet(context) ? screenWidth * 0.5 : screenWidth;
          const horizontalPadding = 16.0;
          const spacing = 10.0;
          final itemWidth =
              (modalWidth - horizontalPadding * 2 - spacing * 2) / 3;

          return Container(
            width: DeviceUtils.isTablet(context)
                ? modalWidth
                : double.infinity, // 设置宽度为100%
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, // 左对齐
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.6,
                    minHeight: 200.0,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: horizontalPadding, vertical: 8),
                      child: Wrap(
                        alignment: WrapAlignment.start, // 左对齐
                        spacing: spacing,
                        runSpacing: spacing,
                        children: options.map((option) {
                          final isSelected = option.value == selectedValue;
                          return SizedBox(
                            width: itemWidth,
                            child: InkWell(
                              onTap: () {
                                onSelected(option.value);
                                Navigator.pop(context);
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                alignment: Alignment.centerLeft, // 内容左对齐
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF27AE60)
                                      : Theme.of(context)
                                          .chipTheme
                                          .backgroundColor,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  option.label,
                                  textAlign: TextAlign.left, // 文字左对齐
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : null,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      );
    }
  }

  Widget _buildLoadingView(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF27ae60)),
          ),
          const SizedBox(height: 16),
          Text(
            '加载中...',
            style: FontUtils.poppins(
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRefreshingView(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF27ae60)),
          ),
          const SizedBox(height: 16),
          Text(
            '刷新中...',
            style: FontUtils.poppins(
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: themeService.isDarkMode
                ? const Color(0xFF666666)
                : const Color(0xFF95a5a6),
          ),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? '加载失败',
            style: FontUtils.poppins(
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: refreshChannels,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF27ae60),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              '刷新',
              style: FontUtils.poppins(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelList(ThemeService themeService) {
    final channels = _getFilteredChannels();

    if (channels.isEmpty) {
      return Center(
        child: Text(
          '暂无频道',
          style: FontUtils.poppins(
            color: themeService.isDarkMode
                ? const Color(0xFFb0b0b0)
                : const Color(0xFF7f8c8d),
          ),
        ),
      );
    }

    // 非 PC 平台直接使用 2 列，PC 平台根据宽度计算列数
    final int crossAxisCount = DeviceUtils.getLiveChannelColumnCount(context);
    const double childAspectRatio = 1.5;

    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        return _buildChannelCard(channels[index], themeService);
      },
    );
  }

  Widget _buildChannelCard(LiveChannel channel, ThemeService themeService) {
    return _LiveChannelCard(
      channel: channel,
      themeService: themeService,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => LivePlayerScreen(
              channel: channel,
              source: _currentSource!,
            ),
          ),
        ).then((_) {
          if (mounted) {
            _loadChannels();
          }
        });
      },
      buildChannelLogo: _buildChannelLogo,
    );
  }

  Widget _buildChannelLogo(LiveChannel channel, ThemeService themeService) {
    // 如果有台标，显示台标
    if (channel.logo.isNotEmpty) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: themeService.isDarkMode
              ? const Color(0xFF2a2a2a)
              : const Color(0xFFc0c0c0),
        ),
        child: Image.network(
          channel.logo,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return _buildDefaultPreview(themeService);
          },
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return _buildDefaultPreview(themeService);
          },
        ),
      );
    }
    // 没有台标，显示默认图标
    return _buildDefaultPreview(themeService);
  }

  Widget _buildDefaultPreview(ThemeService themeService) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: themeService.isDarkMode
            ? const Color(0xFF2a2a2a)
            : const Color(0xFFc0c0c0),
      ),
      child: Center(
        child: Icon(
          Icons.tv,
          size: 48,
          color: themeService.isDarkMode
              ? const Color(0xFF666666)
              : const Color(0xFF95a5b0),
        ),
      ),
    );
  }
}

class _LiveChannelCard extends StatefulWidget {
  final LiveChannel channel;
  final ThemeService themeService;
  final VoidCallback onTap;
  final Widget Function(LiveChannel, ThemeService) buildChannelLogo;

  const _LiveChannelCard({
    required this.channel,
    required this.themeService,
    required this.onTap,
    required this.buildChannelLogo,
  });

  @override
  State<_LiveChannelCard> createState() => _LiveChannelCardState();
}

class _LiveChannelCardState extends State<_LiveChannelCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isPC = DeviceUtils.isPC();

    return MouseRegion(
      cursor: isPC ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: isPC ? (_) => setState(() => _isHovered = true) : null,
      onExit: isPC ? (_) => setState(() => _isHovered = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: isPC && _isHovered ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 卡片主体 - 2:1 长宽比
              Expanded(
                child: AspectRatio(
                  aspectRatio: 2.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.themeService.isDarkMode
                          ? const Color(0xFF1e1e1e)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: widget.buildChannelLogo(
                              widget.channel, widget.themeService),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 标题 - 放在卡片下方居中
              const SizedBox(height: 8),
              Text(
                widget.channel.name,
                style: FontUtils.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isPC && _isHovered
                      ? const Color(0xFF27ae60)
                      : (widget.themeService.isDarkMode
                          ? Colors.white
                          : const Color(0xFF2c3e50)),
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
