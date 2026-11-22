/// Tiny settings store: 18+ gate + optional backend URL.
/// Kept separate so pages never touch SharedPreferences directly.
library;

import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  AppSettings._(this._prefs);
  final SharedPreferences _prefs;

  static const _ageKey = 'age_confirmed';
  static const _backendKey = 'backend_url';

  static Future<AppSettings> load() async {
    return AppSettings._(await SharedPreferences.getInstance());
  }

  bool get ageConfirmed => _prefs.getBool(_ageKey) ?? false;

  Future<void> confirmAge() => _prefs.setBool(_ageKey, true);

  /// Empty string = no backend: the app parses Pornhub directly.
  String get backendUrl => _prefs.getString(_backendKey) ?? '';

  Future<void> setBackendUrl(String url) =>
      _prefs.setString(_backendKey, url.trim());
}
