import 'package:flutter/material.dart';

import '../app_services.dart';

class ThemeModeController extends ChangeNotifier {
  static const _themeModeSettingKey = 'ui_theme_mode_v1';

  ThemeMode _themeMode = ThemeMode.system;
  bool _initialized = false;

  ThemeMode get themeMode => _themeMode;
  bool get initialized => _initialized;

  Future<void> restore() async {
    if (_initialized) return;
    try {
      final stored = await AppServices.wearableSampleRepository
          .getAppSettingJson(_themeModeSettingKey);
      final restored = _decodeThemeMode(stored);
      if (restored != null) {
        _themeMode = restored;
      }
    } catch (_) {
      // Keep system mode if persistence is unavailable.
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode && _initialized) return;
    _themeMode = mode;
    _initialized = true;
    notifyListeners();
    try {
      await AppServices.wearableSampleRepository.upsertAppSettingJson(
        key: _themeModeSettingKey,
        value: _encodeThemeMode(mode),
      );
    } catch (_) {
      // Keep in-memory mode so UI remains responsive.
    }
  }

  String _encodeThemeMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  ThemeMode? _decodeThemeMode(Object? value) {
    if (value is! String) return null;
    switch (value.toLowerCase().trim()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return null;
    }
  }
}

class ThemeModeControllerScope extends InheritedNotifier<ThemeModeController> {
  const ThemeModeControllerScope({
    required ThemeModeController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ThemeModeController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ThemeModeControllerScope>();
    assert(
      scope != null,
      'ThemeModeControllerScope is missing in widget tree.',
    );
    return scope!.notifier!;
  }
}
