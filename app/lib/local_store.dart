/// Local-only stores: favorites, watch history + resume positions,
/// search history. No login, no account, everything in SharedPreferences.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// One video the user starred. Tapping the star again removes it.
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._(this._prefs) {
    final raw = _prefs.getStringList(_key) ?? const [];
    for (final item in raw) {
      try {
        final data = jsonDecode(item);
        if (data is Map<String, dynamic>) _items.add(VideoItem.fromJson(data));
      } catch (_) {
        // Skip one corrupt entry.
      }
    }
  }

  static const _key = 'favorites_v1';

  final SharedPreferences _prefs;
  final List<VideoItem> _items = [];

  static Future<FavoritesStore> load() async {
    return FavoritesStore._(await SharedPreferences.getInstance());
  }

  List<VideoItem> get items => List.unmodifiable(_items);

  bool isFavorite(String viewkey) => _items.any((v) => v.viewkey == viewkey);

  Future<void> toggle(VideoItem video) async {
    if (isFavorite(video.viewkey)) {
      _items.removeWhere((v) => v.viewkey == video.viewkey);
    } else {
      _items.insert(0, video);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String viewkey) async {
    _items.removeWhere((v) => v.viewkey == viewkey);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _prefs.setStringList(
      _key,
      _items.map((v) => jsonEncode(v.toJson())).toList(),
    );
  }
}

/// One watched video with its resume position.
class WatchEntry {
  const WatchEntry({
    required this.video,
    required this.positionSec,
    required this.durationSec,
    required this.updatedAtMs,
  });

  factory WatchEntry.fromJson(Map<String, dynamic> json) {
    return WatchEntry(
      video: VideoItem.fromJson(json['video'] as Map<String, dynamic>),
      positionSec: json['positionSec'] is num
          ? (json['positionSec'] as num).toInt()
          : 0,
      durationSec: json['durationSec'] is num
          ? (json['durationSec'] as num).toInt()
          : 0,
      updatedAtMs: json['updatedAtMs'] is num
          ? (json['updatedAtMs'] as num).toInt()
          : 0,
    );
  }

  final VideoItem video;
  final int positionSec;
  final int durationSec;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    'positionSec': positionSec,
    'durationSec': durationSec,
    'updatedAtMs': updatedAtMs,
  };

  /// Resume makes sense only when meaningfully into the video and not
  /// basically finished.
  bool get canResume {
    if (positionSec <= 15) return false;
    if (durationSec <= 0) return true;
    return positionSec < durationSec - 30;
  }

  String get positionLabel {
    final m = positionSec ~/ 60;
    final s = positionSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  double get progress =>
      durationSec > 0 ? (positionSec / durationSec).clamp(0.0, 1.0) : 0;
}

/// Watch history + resume positions, most recent first, capped at 50.
class WatchStore extends ChangeNotifier {
  WatchStore._(this._prefs) {
    final raw = _prefs.getStringList(_key) ?? const [];
    for (final item in raw) {
      try {
        final data = jsonDecode(item);
        if (data is Map<String, dynamic>)
          _entries.add(WatchEntry.fromJson(data));
      } catch (_) {
        // Skip one corrupt entry.
      }
    }
  }

  static const _key = 'watch_history_v1';
  static const _maxEntries = 50;

  final SharedPreferences _prefs;
  final List<WatchEntry> _entries = [];

  static Future<WatchStore> load() async {
    return WatchStore._(await SharedPreferences.getInstance());
  }

  List<WatchEntry> get entries => List.unmodifiable(_entries);

  /// Entries worth showing in the Home "继续观看" row.
  List<WatchEntry> get continueWatching =>
      _entries.where((e) => e.canResume).toList();

  WatchEntry? resumeFor(String viewkey) {
    for (final entry in _entries) {
      if (entry.video.viewkey == viewkey) return entry;
    }
    return null;
  }

  /// Called while playing (throttled by the caller) and on pause/dispose.
  /// A finished video (within 30s of the end) drops its resume position
  /// but stays in history at position 0.
  Future<void> record(VideoItem video, int positionSec, int durationSec) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final finished = durationSec > 0 && positionSec >= durationSec - 30;
    final entry = WatchEntry(
      video: video,
      positionSec: finished ? 0 : positionSec,
      durationSec: durationSec,
      updatedAtMs: now,
    );
    _entries.removeWhere((e) => e.video.viewkey == video.viewkey);
    _entries.insert(0, entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _prefs.setStringList(
      _key,
      _entries.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }
}

/// Last search keywords, most recent first, capped at 10.
class SearchHistoryStore extends ChangeNotifier {
  SearchHistoryStore._(this._prefs) {
    _items.addAll(_prefs.getStringList(_key) ?? const []);
  }

  static const _key = 'search_history_v1';
  static const _maxItems = 10;

  final SharedPreferences _prefs;
  final List<String> _items = [];

  static Future<SearchHistoryStore> load() async {
    return SearchHistoryStore._(await SharedPreferences.getInstance());
  }

  List<String> get items => List.unmodifiable(_items);

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _items.remove(q);
    _items.insert(0, q);
    if (_items.length > _maxItems) {
      _items.removeRange(_maxItems, _items.length);
    }
    await _prefs.setStringList(_key, _items);
    notifyListeners();
  }

  Future<void> clear() async {
    _items.clear();
    await _prefs.setStringList(_key, _items);
    notifyListeners();
  }
}
