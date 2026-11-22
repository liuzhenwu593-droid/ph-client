/// Settings store: 18+ gate + optional backend URL + player prefs + app PIN.
/// Kept separate so pages never touch SharedPreferences directly.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  AppSettings._(this._prefs);
  final SharedPreferences _prefs;

  static const _ageKey = 'age_confirmed';
  static const _backendKey = 'backend_url';
  static const _seekSecondsKey = 'seek_seconds';
  static const _pinHashKey = 'pin_hash';

  /// Double-tap seek step choices offered in Settings.
  static const seekOptions = [5, 10, 15, 30];

  static Future<AppSettings> load() async {
    return AppSettings._(await SharedPreferences.getInstance());
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

  // ---- App PIN lock ----
  //
  // Only the SHA-256 of the PIN is stored, never the PIN itself.
  // There is no recovery: forgetting the PIN means uninstalling and
  // reinstalling the app (the stored hash is wiped with the app data).
  // This is a casual privacy lock, not security-grade protection.

  static String hashPin(String pin) {
    return sha256.convert(utf8.encode('psexhub-pin:$pin')).toString();
  }

  String get pinHash => _prefs.getString(_pinHashKey) ?? '';

  bool get pinEnabled => pinHash.isNotEmpty;

  bool checkPin(String pin) => pinEnabled && hashPin(pin) == pinHash;

  Future<void> setPin(String pin) async {
    await _prefs.setString(_pinHashKey, hashPin(pin));
  }

  Future<void> clearPin() async {
    await _prefs.remove(_pinHashKey);
  }
}
