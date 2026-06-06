import 'package:flutter/material.dart';

ThemeMode ThemeMode2 = ThemeMode.system;

class ThemeService extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;
  ThemeMode set themeMode(ThemeMode value) {
    _themeMode = value;
    notifyListeners();
    return _themeMode;
  }


  bool get isDarkMode {
    if (_themeMode == ThemeMode.dark) return true;
    if (_themeMode == ThemeMode.light) return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  }

  void setThemeMode(ThemeMode mode) {
    themeMode2 = mode;
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
      bodyLarge: const TextStyle(color: Color(0xFF2c3e50)),
      bodyMedium: const TextStyle(color: Color(0xFF2c3e50)),
      bodySmall: const TextStyle(color: Color(0xFF7f8c8d)),
      titleLarge: const TextStyle(color: Color(0xFF2c3e50)),
      titleMedium: const TextStyle(color: Color(0xFF2c3e50)),
      titleSmall: const TextStyle(color: Color(0xFF2c3e50)),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF2c3e50), brightness: Brightness.light),
      scaffoldBackgroundColor: Color(0xFFf8f9fa),
      appBarTheme: AppBarTheme(backgroundColor: Color(0xFFffffff), foregroundColor: Color(0xFF2c3e50), elevation: 0),
      cardTheme: CardThemeData(color: Color(0xFFffffff), elevation: 2),
      textTheme: textTheme,
      fontFamily: 'Microsoft YaHei',
    );
  }

  ThemeData get darkTheme {
    final textTheme = ThemeData.dark().textTheme.copyWith(
      bodyLarge: const TextStyle(color: Color(0xFFffffff)),
      bodyMedium: const TextStyle(color: Color(0xFFffffff)),
      bodySmall: const TextStyle(color: Color(0xFFb0b0b0)),
      titleLarge: const TextStyle(color: Color(0xFFffffff)),
      titleMedium: const TextStyle(color: Color(0xFFffffff)),
      titleSmall: const TextStyle(color: Color(0xFFffffff)),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF2c3e50), brightness: Brightness.dark),
      scaffoldBackgroundColor: Color(0xFF121212),
      appBarTheme: AppBarTheme(backgroundColor: Color(0xFF1e1e1e), foregroundColor: Color(0xFFffffff), elevation: 0),
      cardTheme: CardThemeData(color: Color(0xFF1e1e1e), elevation: 2),
      textTheme: textTheme,
      fontFamily: 'Microsoft YaHei',
    );
  }
}
