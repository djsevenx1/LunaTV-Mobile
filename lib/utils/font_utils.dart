import 'package:flutter/material.dart';

class FontUtils {
  static const _fontFamily = 'Microsoft YaHei';

  static TextStyle poppins(
    BuildContext? context, {
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    final Color fallbackColor = context != null
        ? (Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black87)
        : Colors.black87;
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize ?? 14,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color ?? fallbackColor,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static TextStyle sourceCodePro(
    BuildContext? context, {
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    final Color fallbackColor = context != null
        ? (Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black87)
        : Colors.black87;
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize ?? 14,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color ?? fallbackColor,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static TextStyle getTitleStyle(BuildContext context) {
    return poppins(context, fontSize: 18, fontWeight: FontWeight.w600);
  }

  static TextStyle getBodyStyle(BuildContext context) {
    return poppins(context, fontSize: 14);
  }
}
