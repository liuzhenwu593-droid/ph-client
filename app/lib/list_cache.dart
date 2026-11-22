/// Short-lived in-memory cache for video lists (home / search / category).
///
/// Why: returning to Home re-fetched the whole list every time (the
/// Webmasters search takes ~1-1.5s in sandbox, more on a slow VPN route),
/// so the list visibly reloaded on every tab switch. Within the TTL the
/// page shows the cached list instantly and refreshes silently in the
/// background; pull-to-refresh always forces a fresh fetch.
///
/// Thumb URLs inside cached lists are signed for 24h; a 5-minute list
/// TTL is far inside that, so cached covers stay valid. Playable HLS
/// URLs are NOT cached here (they live in PlaybackCache with its own
/// 110-minute TTL).
library;

import 'models.dart';

class ListCache {
  ListCache({Duration ttl = const Duration(minutes: 5), int maxEntries = 20})
    : _ttl = ttl,
      _maxEntries = maxEntries;

  final Duration _ttl;
  final int _maxEntries;
  final Map<String, _ListCacheEntry> _entries = {};

  /// Fresh cached items for [key], or null. Expired entries are dropped.
  /// Returns a mutable copy, so callers can sort/filter freely.
  List<VideoItem>? peek(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.fetchedAt) >= _ttl) {
      _entries.remove(key);
      return null;
    }
    return List<VideoItem>.of(entry.items);
  }

  void put(String key, List<VideoItem> items) {
    if (_entries.length >= _maxEntries && !_entries.containsKey(key)) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = _ListCacheEntry(
      List<VideoItem>.of(items),
      DateTime.now(),
    );
  }

  void invalidate(String key) => _entries.remove(key);
  void clear() => _entries.clear();
  int get length => _entries.length;
}

class _ListCacheEntry {
  _ListCacheEntry(this.items, this.fetchedAt);
  final List<VideoItem> items;
  final DateTime fetchedAt;
}
