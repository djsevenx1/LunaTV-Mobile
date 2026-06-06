import 'package:flutter/material.dart';

class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({
    super.key,
    this.forceBlack = false,
    this.customBackgroundColor,
    this.title,
  });

  final bool forceBlack;
  final Color? customBackgroundColor;
  final String? title;

  @override
  Widget build(BuildContext context) {
    // 移动端无需本组件，始终返回空占位
    return const SizedBox.shrink();
  }
}
