import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「极光影院」配色体系
/// 深色沉浸：极夜蓝黑背景 + 电光紫罗兰→品红渐变主强调 + 青色点缀
class AppColors {
  // 主强调色(电光紫罗兰)
  static const Color primary = Color(0xFF7C5CFF);
  static const Color primaryLight = Color(0xFF9D8CFF);
  static const Color primaryDark = Color(0xFF5A3FD9);

  // 渐变
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7C5CFF), Color(0xFFE23B8E)],
  );
  static const LinearGradient blueGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2BD9E8), Color(0xFF7C5CFF)],
  );
  static const LinearGradient purpleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7C5CFF), Color(0xFFE23B8E)],
  );
  static const LinearGradient orangeGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF5B84B), Color(0xFFFF8A3D)],
  );
  static const LinearGradient pinkGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE23B8E), Color(0xFFFF5C7A)],
  );
  static const LinearGradient cyanGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2BD9E8), Color(0xFF34B3F1)],
  );
  static const LinearGradient redGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF4D5E), Color(0xFFE23B8E)],
  );

  // 亮色主题（晨曦）
  static const Color lightBackground = Color(0xFFF7F8FC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFEEF0F8);
  static const Color lightText = Color(0xFF1A2133);
  static const Color lightTextSecondary = Color(0xFF5A6478);
  static const Color lightTextMuted = Color(0xFF9BA3B5);
  static const Color lightBorder = Color(0xFFE5E8F2);
  static const Color lightCard = Color(0xFFFFFFFF);

  // 暗色主题（极夜）
  static const Color darkBackground = Color(0xFF0B0F1A);
  static const Color darkSurface = Color(0xFF121828);
  static const Color darkSurfaceVariant = Color(0xFF1A2133);
  static const Color darkText = Color(0xFFEDF0F7);
  static const Color darkTextSecondary = Color(0xFF9BA3B5);
  static const Color darkTextMuted = Color(0xFF6B7280);
  static const Color darkBorder = Color(0xFF2A3247);
  static const Color darkCard = Color(0xFF121828);

  // 评分色
  static const Color ratingAmber = Color(0xFFFFB020);
  static const Color ratingPink = Color(0xFFFF5C7A);
}

class ThemeService extends ChangeNotifier {
  static const String _themeModeKey = 'app_theme_mode';

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  /// 异步初始化：从本地存储恢复上次的主题选择
  static Future<ThemeService> create() async {
    final service = ThemeService();
    await service._loadFromPrefs();
    return service;
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_themeModeKey);
      if (saved != null) {
        _themeMode = _parseMode(saved);
        // ignore: avoid_print
        print('[ThemeService] 恢复主题模式: $saved');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ThemeService] 读取主题失败: $e');
    }
  }

  Future<void> _saveToPrefs(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeModeKey, _stringifyMode(mode));
    } catch (e) {
      // ignore: avoid_print
      print('[ThemeService] 保存主题失败: $e');
    }
  }

  ThemeMode _parseMode(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  String _stringifyMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  set themeMode(ThemeMode value) {
    _themeMode = value;
    _saveToPrefs(value);
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
        secondary: AppColors.primaryLight,
      ),
      scaffoldBackgroundColor: AppColors.lightBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightBackground,
        foregroundColor: AppColors.lightText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
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
        secondary: AppColors.primaryLight,
      ),
      scaffoldBackgroundColor: AppColors.darkBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: AppColors.darkText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
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
