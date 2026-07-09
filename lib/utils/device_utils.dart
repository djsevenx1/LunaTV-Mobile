import 'dart:io';

import 'package:flutter/material.dart';

/// 设备类型工具类
class DeviceUtils {
  // 平板的最小宽度阈值（dp）
  static const double tabletMinWidth = 600.0;

  /// 判断当前设备是否是平板
  ///
  /// 通过屏幕宽度判断，宽度 >= 600dp 视为平板
  static bool isTablet(BuildContext context) {
    if (isPC()) {
      return true;
    }
    final double width = MediaQuery.of(context).size.width;
    return width >= tabletMinWidth;
  }

  /// 判断当前设备是否是平板竖屏
  ///
  /// 逻辑：isTablet 且宽高比小于等于 1.2
  static bool isPortraitTablet(BuildContext context) {
    if (!isTablet(context)) {
      return false;
    }
    if (isPC()) {
      return false;
    }

    final Size size = MediaQuery.of(context).size;
    final double aspectRatio = size.width / size.height;
    return aspectRatio <= 1.2;
  }

  /// 判断当前平台是否是 Windows
  static bool isWindows() {
    return Platform.isWindows;
  }

  /// 判断当前平台是否是 macOS
  static bool isMacOS() {
    return Platform.isMacOS;
  }

  /// 判断当前平台是否是 PC（Windows 或 macOS）
  static bool isPC() {
    return isWindows() || isMacOS();
  }

  /// 根据屏幕宽度动态计算平板模式下的列数（6～8列）
  ///
  /// 宽度范围：
  /// - < 1000: 6列
  /// - 1000-1200: 7列
  /// - >= 1200: 8列
  static int getTabletColumnCount(BuildContext context) {
    if (!isTablet(context)) {
      return 3; // 手机模式固定3列
    }

    final double width = MediaQuery.of(context).size.width;

    if (width < 1000) {
      return 6;
    } else if (width < 1200) {
      return 7;
    } else {
      return 8;
    }
  }

  /// 根据屏幕宽度动态计算横向滚动列表的可见卡片数（5.75、6.75、7.75）
  ///
  /// 用于 continue_watching_section 和 recommendation_section
  /// 宽度范围：
  /// - < 1000: 5.75列
  /// - 1000-1200: 6.75列
  /// - >= 1200: 7.75列
  static double getHorizontalVisibleCards(BuildContext context, double mobileCardCount) {
    if (!isTablet(context)) {
      return mobileCardCount; // 手机模式使用传入的卡片数
    }

    final double width = MediaQuery.of(context).size.width;

    if (width < 1000) {
      return 5.75;
    } else if (width < 1200) {
      return 6.75;
    } else {
      return 7.75;
    }
  }

  /// 根据屏幕宽度动态计算直播频道列表的列数
  static int getLiveChannelColumnCount(BuildContext context) {
    if (!isTablet(context)) {
      return 2; // 手机模式固定2列
    }
    final double width = MediaQuery.of(context).size.width;

    if (width < 1000) {
      return 3;
    } else if (width < 1200) {
      return 4;
    } else {
      return 5;
    }
  }
}
