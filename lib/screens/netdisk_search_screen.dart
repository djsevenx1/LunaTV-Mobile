import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/models/netdisk_result.dart';
import 'package:luna_tv/services/netdisk_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/font_utils.dart';

/// 网盘搜索页面
class NetdiskSearchScreen extends StatefulWidget {
  const NetdiskSearchScreen({super.key});

  @override
  State<NetdiskSearchScreen> createState() => _NetdiskSearchScreenState();
}

class _NetdiskSearchScreenState extends State<NetdiskSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<NetdiskResult> _results = [];
  bool _isLoading = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    // 自动聚焦
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _onSearch(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _hasSearched = true;
      _results = [];
    });

    final results = await NetdiskService.search(query.trim());

    if (!mounted) return;

    setState(() {
      _results = results;
      _isLoading = false;
    });
  }

  void _onResultTap(NetdiskResult result) {
    Clipboard.setData(ClipboardData(text: result.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('链接已复制: ${result.title}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;
        final bgColor = isDark ? const Color(0xFF1e1e1e) : Colors.white;
        final textColor = isDark ? const Color(0xFFffffff) : const Color(0xFF2c3e50);
        final subTextColor = isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d);

        return Scaffold(
          backgroundColor: bgColor,
          appBar: AppBar(
            backgroundColor: bgColor,
            foregroundColor: textColor,
            elevation: 0,
            title: Text(
              '网盘搜索',
              style: FontUtils.poppins(context,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          body: Column(
            children: [
              // 搜索框
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchController,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: '搜索网盘资源...',
                    hintStyle: FontUtils.poppins(context,
                      fontSize: 14,
                      color: subTextColor,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      color: subTextColor,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(
                              Icons.clear,
                              color: subTextColor,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _hasSearched = false;
                                _results = [];
                              });
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF333333)
                        : Colors.grey[100],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  style: FontUtils.poppins(context,
                    fontSize: 14,
                    color: textColor,
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: _onSearch,
                  onChanged: (value) {
                    setState(() {});
                  },
                ),
              ),
              // 内容区域
              Expanded(
                child: _buildContent(themeService),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(ThemeService themeService) {
    if (!_hasSearched) {
      return _buildInitialState(themeService);
    }

    if (_isLoading) {
      return _buildLoadingState(themeService);
    }

    if (_results.isEmpty) {
      return _buildEmptyState(themeService);
    }

    return _buildResultList(themeService);
  }

  /// 初始状态 - 未搜索
  Widget _buildInitialState(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_search_outlined,
            size: 72,
            color: isDark
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '输入关键词搜索网盘资源',
            style: FontUtils.poppins(context,
              fontSize: 15,
              color: isDark
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
        ],
      ),
    );
  }

  /// 加载状态
  Widget _buildLoadingState(ThemeService themeService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF27ae60)),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '搜索中...',
            style: FontUtils.poppins(context,
              fontSize: 14,
              color: themeService.isDarkMode
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
        ],
      ),
    );
  }

  /// 空状态 - 搜索无结果
  Widget _buildEmptyState(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 64,
            color: isDark
                ? Colors.white.withOpacity(0.3)
                : Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '未找到相关资源',
            style: FontUtils.poppins(context,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: isDark
                  ? const Color(0xFFb0b0b0)
                  : const Color(0xFF7f8c8d),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '换个关键词试试',
            style: FontUtils.poppins(context,
              fontSize: 13,
              color: isDark
                  ? Colors.white.withOpacity(0.4)
                  : Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索结果列表
  Widget _buildResultList(ThemeService themeService) {
    final isDark = themeService.isDarkMode;
    final textColor = isDark ? const Color(0xFFffffff) : const Color(0xFF2c3e50);
    final subTextColor = isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d);
    final cardColor = isDark ? const Color(0xFF2a2a2a) : Colors.grey[50];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final result = _results[index];
        return GestureDetector(
          onTap: () => _onResultTap(result),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.grey[300]!,
                width: 0.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                Text(
                  result.title,
                  style: FontUtils.poppins(context,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                // 标签行: 来源 + 大小 + 日期
                Row(
                  children: [
                    // 来源标签
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF27ae60).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        result.source,
                        style: FontUtils.sourceCodePro(context,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF27ae60),
                        ),
                      ),
                    ),
                    if (result.size.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Text(
                        result.size,
                        style: FontUtils.sourceCodePro(context,
                          fontSize: 12,
                          color: subTextColor,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (result.date.isNotEmpty)
                      Text(
                        result.date,
                        style: FontUtils.sourceCodePro(context,
                          fontSize: 12,
                          color: subTextColor,
                        ),
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
}
