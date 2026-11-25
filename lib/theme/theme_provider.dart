import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tema de la app, persistido en SharedPreferences.
class ThemeProvider extends ChangeNotifier {
  static const String storageKey = 'theme_mode';

  ThemeProvider(this._themeMode);

  ThemeMode _themeMode;
  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode != ThemeMode.light;

  static ThemeMode modeFromName(String? name) => switch (name) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, mode.name);
  }
}
