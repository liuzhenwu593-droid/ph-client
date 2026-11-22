/// Data source routing: backend first (when configured), in-app parser
/// as fallback. The app works with NO backend at all — direct parsing is
/// the default path until the user pastes a backend URL in Settings.
///
/// Backend contract (backend/server.py): GET {base}/api/home,
/// /api/search?q=&page=, /api/video?viewkey=, /api/categories,
/// /api/category?id=&page= — all JSON, same shapes as the models here.
/// The backend only returns verified-playable HLS URLs (it retries until
/// the master playlist GETs 200), so the app can trust backend sources
/// without re-verifying them.
///
/// Search ordering (verified live 2026-11-22): the Webmasters API only
/// honours ordering=mostviewed; toprated/mostrecent/longest all return
/// the same unsorted default list. So "评分最高" and "最新" are sorted
/// client-side below (by rating / publish date) after the fetch — the
/// sort applies to the loaded page, not the whole catalogue.
/// Duration and HD: the API returns no duration filter and no HD flag
/// (neither search nor video_by_id), so duration is filtered client-side
/// from the "M:SS" string and there is deliberately no HD toggle.
///
/// Pure Dart (dart:io / dart:convert only).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'list_cache.dart';
import 'models.dart';
import 'ph_parse.dart' as direct;
import 'play_cache.dart';
import 'site_list.dart' as site;

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => 'ApiException: $message';
}

/// Search sort modes shown in the UI.
enum SearchOrdering { mostViewed, topRated, mostRecent, longest }

extension SearchOrderingApi on SearchOrdering {
  String get label {
    switch (this) {
      case SearchOrdering.mostViewed:
        return '最多播放';
      case SearchOrdering.topRated:
        return '评分最高';
      case SearchOrdering.mostRecent:
        return '最新';
      case SearchOrdering.longest:
        return '最长';
    }
  }

  String get apiValue {
    switch (this) {
      case SearchOrdering.mostViewed:
        return 'mostviewed';
      case SearchOrdering.topRated:
        return 'toprated';
      case SearchOrdering.mostRecent:
        return 'mostrecent';
      case SearchOrdering.longest:
        return 'longest';
    }
  }
}

class PhApi {
  PhApi({String? backendUrl, PlaybackCache? cache})
    : _backendUrl = _clean(backendUrl),
      _cache = cache;

  static String? _clean(String? url) {
    final trimmed = (url ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? null : trimmed;
  }

  void setBackendUrl(String? url) => _backendUrl = _clean(url);

  String? get backendUrl => _backendUrl;
  String? _backendUrl;
  final PlaybackCache? _cache;

  /// Short-lived list cache (5 min): within the TTL, pages show the
  /// cached list instantly and refresh silently in the background.
  final ListCache lists = ListCache();

  bool get usesBackend => _backendUrl != null;

  /// Synchronous cache peek for pages: fresh cached items, or null.
  List<VideoItem>? peekHome({int page = 1}) => lists.peek('home:$page');

  List<VideoItem>? peekSearch(
    String query, {
    SearchOrdering ordering = SearchOrdering.mostViewed,
    int page = 1,
  }) => lists.peek('search:$query:${ordering.apiValue}:$page');

  List<VideoItem>? peekCategory(int categoryId, {int page = 1}) =>
      lists.peek('category:$categoryId:$page');

  Future<Map<String, dynamic>> _getBackendJson(String path) async {
    final base = _backendUrl;
    if (base == null) throw ApiException('no backend configured');
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw ApiException('backend HTTP ${response.statusCode}: $body');
      }
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw ApiException('backend returned unexpected JSON');
      }
      return data;
    } finally {
      client.close();
    }
  }

  List<VideoItem> _videosFrom(Map<String, dynamic> data) {
    final raw = data['videos'];
    if (raw is! List) throw ApiException('missing videos list');
    return raw
        .whereType<Map<String, dynamic>>()
        .map(VideoItem.fromJson)
        .toList();
  }

  Future<List<VideoItem>> home({int page = 1, bool forceRefresh = false}) async {
    final key = 'home:$page';
    if (!forceRefresh) {
      final cached = lists.peek(key);
      if (cached != null) return cached;
    }
    final List<VideoItem> items;
    if (usesBackend) {
      try {
        items = _videosFrom(await _getBackendJson('/api/home?page=$page'));
        lists.put(key, items);
        return items;
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    items = await direct.directSearch('', page: page);
    lists.put(key, items);
    return items;
  }

  Future<List<VideoItem>> search(
    String query, {
    int page = 1,
    SearchOrdering ordering = SearchOrdering.mostViewed,
    bool forceRefresh = false,
  }) async {
    final key = 'search:$query:${ordering.apiValue}:$page';
    List<VideoItem> items;
    if (!forceRefresh) {
      final cached = lists.peek(key);
      if (cached != null) return _sortedSearch(cached, ordering);
    }
    if (usesBackend) {
      try {
        final encoded = Uri.encodeQueryComponent(query);
        items = _videosFrom(
          await _getBackendJson(
            '/api/search?q=$encoded&page=$page&ordering=${ordering.apiValue}',
          ),
        );
      } on ApiException {
        items = await direct.directSearch(
          query,
          page: page,
          ordering: ordering.apiValue,
        );
      }
    } else {
      items = await direct.directSearch(
        query,
        page: page,
        ordering: ordering.apiValue,
      );
    }
    lists.put(key, items);
    // Client-side sort: the API only honours mostviewed server-side.
    return _sortedSearch(items, ordering);
  }

  /// Sort a search page client-side (the API only honours mostviewed
  /// server-side). Returns a sorted copy; the cached original is kept
  /// unsorted so another ordering can sort it differently.
  List<VideoItem> _sortedSearch(
    List<VideoItem> items,
    SearchOrdering ordering,
  ) {
    final sorted = List<VideoItem>.of(items);
    switch (ordering) {
      case SearchOrdering.topRated:
        sorted.sort((a, b) => b.rating.compareTo(a.rating));
      case SearchOrdering.mostRecent:
        sorted.sort((a, b) => b.publishDate.compareTo(a.publishDate));
      case SearchOrdering.longest:
        sorted.sort((a, b) => b.durationSeconds.compareTo(a.durationSeconds));
      case SearchOrdering.mostViewed:
        break;
    }
    return sorted;
  }

  Future<List<CategoryItem>> categories() async {
    if (usesBackend) {
      try {
        final data = await _getBackendJson('/api/categories');
        final raw = data['categories'];
        if (raw is List) {
          return raw
              .whereType<Map<String, dynamic>>()
              .map(CategoryItem.fromJson)
              .where((c) => c.id != 0 && c.name.isNotEmpty)
              .toList();
        }
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    return site.directCategories();
  }

  Future<List<VideoItem>> categoryVideos(
    int categoryId, {
    int page = 1,
    bool forceRefresh = false,
  }) async {
    final key = 'category:$categoryId:$page';
    if (!forceRefresh) {
      final cached = lists.peek(key);
      if (cached != null) return cached;
    }
    final List<VideoItem> items;
    if (usesBackend) {
      try {
        items = _videosFrom(
          await _getBackendJson('/api/category?id=$categoryId&page=$page'),
        );
        lists.put(key, items);
        return items;
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    items = await site.directCategoryVideos(categoryId, page: page);
    lists.put(key, items);
    return items;
  }

  Future<VideoDetail> video(String viewkey, {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _cache?.get(viewkey);
      if (cached != null && cached.hlsSources.isNotEmpty) return cached;
    }
    VideoDetail detail;
    if (usesBackend) {
      try {
        final data = await _getBackendJson(
          '/api/video?viewkey=${Uri.encodeQueryComponent(viewkey)}',
        );
        detail = VideoDetail.fromJson(data);
        if (detail.hlsSources.isEmpty) {
          detail = await direct.directVideoSources(viewkey);
        }
      } on ApiException {
        detail = await direct.directVideoSources(viewkey);
      }
    } else {
      detail = await direct.directVideoSources(viewkey);
    }
    if (detail.hlsSources.isNotEmpty) {
      await _cache?.put(viewkey, detail);
    }
    return detail;
  }

  Future<void> invalidateVideo(String viewkey) async {
    await _cache?.invalidate(viewkey);
  }

  /// Fetch a freshly signed thumbnail URL for one video (stored thumbs
  /// are signed URLs that expire after 24h). Used when a favorite's
  /// cover fails to load. Returns '' when no thumb could be fetched.
  Future<String> refreshThumb(String viewkey) async {
    if (usesBackend) {
      try {
        final data = await _getBackendJson(
          '/api/video_by_id?id=${Uri.encodeQueryComponent(viewkey)}',
        );
        // The backend returns the cleaned video dict itself.
        return VideoItem.fromJson(data).thumb;
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    try {
      return await direct.directVideoThumb(viewkey);
    } on direct.ParseException {
      return '';
    }
  }

  /// Cheap liveness check for the Settings "test connection" button.
  Future<bool> testBackend() async {
    if (!usesBackend) return false;
    try {
      final data = await _getBackendJson('/health');
      return data['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}
