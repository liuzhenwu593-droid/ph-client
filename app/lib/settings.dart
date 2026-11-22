/// Settings store: 18+ gate + optional backend URL + player prefs.
/// Kept separate so pages never touch SharedPreferences directly.
/// A ChangeNotifier so the layout toggle (v0.2.2) can rebuild lists.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);
  final SharedPreferences _prefs;

  static const _ageKey = 'age_confirmed';
  static const _backendKey = 'backend_url';
  static const _seekSecondsKey = 'seek_seconds';
  static const _gridColumnsKey = 'grid_columns';

  /// Double-tap seek step choices offered in Settings.
  static const seekOptions = [5, 10, 15, 30];

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    // v0.2.1: the PIN app lock was removed entirely. A PIN hash stored by
    // v0.2.0 must never be able to lock anyone out again, so drop it here.
    await prefs.remove('pin_hash');
    return AppSettings._(prefs);
  }

  bool get ageConfirmed => _prefs.getBool(_ageKey) ?? false;

  Future<void> confirmAge() => _prefs.setBool(_ageKey, true);

  /// Empty string = no backend: the app parses Pornhub directly.
  String get backendUrl => _prefs.getString(_backendKey) ?? '';

  Future<void> setBackendUrl(String url) =>
      _prefs.setString(_backendKey, url.trim());

  /// Seconds skipped by one double-tap (left = back, right = forward).
  int get seekSeconds {
    final value = _prefs.getInt(_seekSecondsKey) ?? 10;
    return seekOptions.contains(value) ? value : 10;
  }

  Future<void> setSeekSeconds(int seconds) async {
    if (!seekOptions.contains(seconds)) return;
    await _prefs.setInt(_seekSecondsKey, seconds);
  }

  /// Video list columns (v0.2.2): 1, 2 or 3. Default 1 (the old list).
  /// Persisted so the layout survives restart.
  int get gridColumns {
    final value = _prefs.getInt(_gridColumnsKey) ?? 1;
    return value >= 1 && value <= 3 ? value : 1;
  }

  Future<void> setGridColumns(int columns) async {
    final clamped = columns.clamp(1, 3);
    await _prefs.setInt(_gridColumnsKey, clamped);
    notifyListeners();
  }
}
