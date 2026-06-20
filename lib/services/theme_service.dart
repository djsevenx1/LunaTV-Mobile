import 'package:flutter/material.dart';

class AppColors {
  // 主强调色(绿色)
  static const Color primary = Color(0xFF22C55E);
  static const Color primaryLight = Color(0xFF4ADE80);
  static const Color primaryDark = Color(0xFF16A34A);

  // 渐变
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF22C55E), Color(0xFF10B981)],
  );
  static const LinearGradient blueGradient = LinearGradient(
    colors: [Color(0xFF3B82F6), Color(0xFF6366F1)],
  );
  static const LinearGradient purpleGradient = LinearGradient(
    colors: [Color(0xFFA855F7), Color(0xFFEC4899)],
  );
  static const LinearGradient orangeGradient = LinearGradient(
    colors: [Color(0xFFF59E0B), Color(0xFFF97316)],
  );
  static const LinearGradient pinkGradient = LinearGradient(
    colors: [Color(0xFFEC4899), Color(0xFFF43F5E)],
  );
  static const LinearGradient cyanGradient = LinearGradient(
    colors: [Color(0xFF06B6D4), Color(0xFF0EA5E9)],
  );
  static const LinearGradient redGradient = LinearGradient(
    colors: [Color(0xFFEF4444), Color(0xFFF43F5E)],
  );

  // 亮色主题
  static const Color lightBackground = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFF3F4F6);
  static const Color lightText = Color(0xFF111827);
  static const Color lightTextSecondary = Color(0xFF4B5563);
  static const Color lightTextMuted = Color(0xFF9CA3AF);
  static const Color lightBorder = Color(0xFFE5E7EB);
  static const Color lightCard = Color(0xFFFFFFFF);

  // 暗色主题
  static const Color darkBackground = Color(0xFF000000);
  static const Color darkSurface = Color(0xFF111111);
  static const Color darkSurfaceVariant = Color(0xFF1E1E1E);
  static const Color darkText = Color(0xFFE5E7EB);
  static const Color darkTextSecondary = Color(0xFF9CA3AF);
  static const Color darkTextMuted = Color(0xFF6B7280);
  static const Color darkBorder = Color(0xFF374151);
  static const Color darkCard = Color(0xFF1E1E1E);

  // 评分色
  static const Color ratingAmber = Color(0xFFF59E0B);
  static const Color ratingPink = Color(0xFFEC4899);
}

class ThemeService extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode value) {
    _themeMode = value;
    notifyListeners();
  }

  bool get isDarkMode {
    if (_themeMode == ThemeMode.dark) return true;
    if (_themeMode == ThemeMode.light) return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    notifyListeners();
  }

  void toggleTheme() {
    if (_themeMode == ThemeMode.light) {
      setThemeMode(ThemeMode.dark);
    } else {
      setThemeMode(ThemeMode.light);
    }
  }

  ThemeData get lightTheme {
    final textTheme = ThemeData.light().textTheme.copyWith(
          bodyLarge: const TextStyle(color: AppColors.lightText),
          bodyMedium: const TextStyle(color: AppColors.lightText),
          bodySmall: const TextStyle(color: AppColors.lightTextSecondary),
          titleLarge: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w600),
          titleMedium: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w600),
          titleSmall: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w500),
          headlineLarge: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w700),
          headlineMedium: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w700),
          headlineSmall: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w600),
          labelLarge: const TextStyle(
              color: AppColors.lightText, fontWeight: FontWeight.w500),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.primary,
        secondary: AppColors.primary,
      ),
      scaffoldBackgroundColor: AppColors.lightBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightBackground,
        foregroundColor: AppColors.lightText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardTheme(
        color: AppColors.lightCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      textTheme: textTheme,
      fontFamily: 'Microsoft YaHei',
      iconTheme: const IconThemeData(color: AppColors.lightText),
      dividerColor: AppColors.lightBorder,
    );
  }

  ThemeData get darkTheme {
    final textTheme = ThemeData.dark().textTheme.copyWith(
          bodyLarge: const TextStyle(color: AppColors.darkText),
          bodyMedium: const TextStyle(color: AppColors.darkText),
          bodySmall: const TextStyle(color: AppColors.darkTextSecondary),
          titleLarge: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w600),
          titleMedium: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w600),
          titleSmall: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w500),
          headlineLarge: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w700),
          headlineMedium: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w700),
          headlineSmall: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w600),
          labelLarge: const TextStyle(
              color: AppColors.darkText, fontWeight: FontWeight.w500),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: AppColors.primary,
        secondary: AppColors.primary,
      ),
      scaffoldBackgroundColor: AppColors.darkBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: AppColors.darkText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardTheme(
        color: AppColors.darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      textTheme: textTheme,
      fontFamily: 'Microsoft YaHei',
      iconTheme: const IconThemeData(color: AppColors.darkText),
      dividerColor: AppColors.darkBorder,
    );
  }
}
