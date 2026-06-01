import 'package:flutter/material.dart';
import '../utils/device_utils.dart';
import 'filter_pill_hover.dart';

/// 显示筛选选项的公共方法
/// 在 PC 端显示居中对话框，在移动端显示底部弹出
void showFilterOptionsSelector({
  required BuildContext context,
  required String title,
  required List<SelectorOption> options,
  required String selectedValue,
  required ValueChanged<String> onSelected,
  bool useCompactLayout = false,
}) {
  // 计算需要的行数
  final rowCount = (options.length / 4).ceil();
  // 计算GridView的高度：行数 * (item高度 + 间距) + padding
  final gridHeight = rowCount * (40.0 + 10.0) - 10.0 + 32.0; // 32.0是上下padding

  if (DeviceUtils.isPC()) {
    // PC端显示居中对话框 - 紧凑4列设计
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Container(
            width: 480,
            constraints: const BoxConstraints(maxHeight: 450),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF2A2A2A)
                  : Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题栏
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).dividerColor.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                // 选项网格
                Flexible(
                  child: SingleChildScrollView(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          childAspectRatio: 2.5,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: options.length,
                        itemBuilder: (context, index) {
                          final option = options[index];
                          final isSelected = option.value == selectedValue;
                          return FilterOptionHover(
                            isPC: DeviceUtils.isPC(),
                            isSelected: isSelected,
                            label: option.label,
                            useCompactLayout: useCompactLayout,
                            onTap: () {
                              onSelected(option.value);
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  } else {
    // 移动端显示底部弹出
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child:
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
              ),
              Container(
                height: gridHeight,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 2.5,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    final isSelected = option.value == selectedValue;
                    return FilterOptionHover(
                      isPC: DeviceUtils.isPC(),
                      isSelected: isSelected,
                      label: option.label,
                      onTap: () {
                        onSelected(option.value);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16), // 底部间距
            ],
          ),
        );
      },
    );
  }
}
