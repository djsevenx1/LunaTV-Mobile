import 'package:flutter/material.dart';
import 'package:luna_tv/utils/device_utils.dart';

/// 切换播放源/集数时的加载蒙版组件
class SwitchLoadingOverlay extends StatelessWidget {
  final bool isVisible;
  final String message;
  final AnimationController animationController;
  final VoidCallback? onBackPressed;

  const SwitchLoadingOverlay({
    super.key,
    required this.isVisible,
    required this.message,
    required this.animationController,
    this.onBackPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (!isVisible) return const SizedBox.shrink();

    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            // 左上角返回按钮
            if (onBackPressed != null)
              Positioned(
                top: 4,
                left: 8.0,
                child: DeviceUtils.isPC()
                    ? _HoverBackButton(
                        onTap: onBackPressed!,
                        iconColor: Colors.white,
                      )
                    : GestureDetector(
                        onTap: onBackPressed,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          child: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
              ),
            // 中心加载内容
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 加载动画 - 与页面加载蒙版保持一致
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      // 旋转的背景方块（半透明绿色）
                      RotationTransition(
                        turns: animationController,
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2ecc71).withOpacity(0.3),
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                      // 中间的图标容器
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF2ecc71), Color(0xFF27ae60)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: Text(
                            '🎬',
                            style: TextStyle(fontSize: 24),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // 加载文案
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 带 hover 效果的返回按钮（PC 端专用）
class _HoverBackButton extends StatefulWidget {
  final VoidCallback onTap;
  final Color iconColor;

  const _HoverBackButton({
    required this.onTap,
    required this.iconColor,
  });

  @override
  State<_HoverBackButton> createState() => _HoverBackButtonState();
}

class _HoverBackButtonState extends State<_HoverBackButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: _isHovering
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.withOpacity( 0.5),
                )
              : null,
          child: Icon(
            Icons.arrow_back,
            color: widget.iconColor,
            size: 20,
          ),
        ),
      ),
    );
  }
}
