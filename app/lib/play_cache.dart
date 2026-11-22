/// In-memory + on-disk cache for playable video details.
///
/// Signed HLS URLs are valid for 2h after issue. Re-opening the same video
/// within 110 minutes (2h minus a safety margin) reuses the cached sources
/// instead of re-fetching the ~1.6 MB detail page and re-verifying — this
/// is the biggest playback-start win for replays and for quality switches.
/// Entries older than the TTL are dropped and never reused.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class PlaybackCache {
  PlaybackCache._(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      try {
        final data = jsonDecode(raw);
        if (data is Map<String, dynamic>) {
          for (final entry in data.entries) {
            final value = entry.value;
            if (value is Map<String, dynamic>) {
              final fetchedAt = value['fetchedAt'];
              final detailJson = value['detail'];
              if (fetchedAt is num && detailJson is Map<String, dynamic>) {
                _memory[entry.key] = _CachedDetail(
                  fetchedAt: fetchedAt.toInt(),
                  detail: VideoDetail.fromJson(detailJson),
                );
              }
            }
          }
        }
      } catch (_) {
        // Corrupt cache: start empty.
        _memory.clear();
      }
    }
    _prune();
  }

  static const _key = 'play_cache_v1';

  /// 110 minutes: inside the 2h signature validity, with margin.
  static const _ttlSeconds = 6600;

  final SharedPreferences _prefs;
  final Map<String, _CachedDetail> _memory = {};

  static Future<PlaybackCache> load() async {
    return PlaybackCache._(await SharedPreferences.getInstance());
  }

  VideoDetail? get(String viewkey) {
    final hit = _memory[viewkey];
    if (hit == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now - hit.fetchedAt > _ttlSeconds) {
      _memory.remove(viewkey);
      _persist();
      return null;
    }
    return hit.detail;
  }

  Future<void> put(String viewkey, VideoDetail detail) async {
    _memory[viewkey] = _CachedDetail(
      fetchedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      detail: detail,
    );
    if (_memory.length > 40) {
      // Keep the cache bounded: drop the oldest entries.
      final sorted = _memory.entries.toList()
        ..sort((a, b) => a.value.fetchedAt.compareTo(b.value.fetchedAt));
      for (final entry in sorted.take(_memory.length - 40)) {
        _memory.remove(entry.key);
      }
    }
    await _persist();
  }

  Future<void> invalidate(String viewkey) async {
    _memory.remove(viewkey);
    await _persist();
  }

  void _prune() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _memory.removeWhere((_, hit) => now - hit.fetchedAt > _ttlSeconds);
  }

  Future<void> _persist() async {
    final data = <String, dynamic>{
      for (final entry in _memory.entries)
        entry.key: {
          'fetchedAt': entry.value.fetchedAt,
          'detail': entry.value.detail.toJson(),
        },
    };
    await _prefs.setString(_key, jsonEncode(data));
  }
}

class _CachedDetail {
  const _CachedDetail({required this.fetchedAt, required this.detail});
  final int fetchedAt;
  final VideoDetail detail;
}
