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
/// Search ordering (v0.2.4): search now parses the mobile website's own
/// search page first, so results and order match what the user sees on
/// the mobile site. The site honours all four sort modes server-side
/// via its `o=` param (mv/tr/mr/lg — verified live 2026-11-22), so no
/// client-side sort is needed for site results. The Webmasters API is
/// kept only as a fallback when the site fetch fails or the page layout
/// changes — and the API only honours ordering=mostviewed, so fallback
/// results (and backend results, which are Webmasters-backed) are still
/// sorted client-side below (by rating / publish date / duration) after
/// the fetch; the sort applies to the loaded page, not the whole
/// catalogue.
/// Duration and HD: neither the site page nor the API returns a
/// duration filter or an HD flag, so duration is filtered client-side
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

/// One cached preview-URL map (see [PhApi.previewUrls]).
class _PreviewEntry {
  const _PreviewEntry({required this.fetchedAt, required this.urls});
  final int fetchedAt;
  final Map<String, String> urls;
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

  /// The mobile site's own sort param (search page `o=`), verified live
  /// 2026-11-22: each value gives a different order of 28 cards, and
  /// o=lg durations are strictly descending.
  String get siteValue {
    switch (this) {
      case SearchOrdering.mostViewed:
        return 'mv';
      case SearchOrdering.topRated:
        return 'tr';
      case SearchOrdering.mostRecent:
        return 'mr';
      case SearchOrdering.longest:
        return 'lg';
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
    List<VideoItem> items;
    if (usesBackend) {
      try {
        items = _videosFrom(await _getBackendJson('/api/home?page=$page'));
        lists.put(key, items);
        return items;
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    // Webmasters home call WITHOUT period: empty search + period=weekly
    // now answers {"code":"2001","message":"No Videos found!"}
    // (verified live 2026-11-23); ordering=mostviewed alone returns 30
    // videos. Any API failure (2001, changed shape, network) falls
    // through to the mobile site home page below.
    try {
      items = await direct.directSearch('', page: page, period: '');
    } catch (_) {
      items = <VideoItem>[];
    }
    if (items.isEmpty) {
      // Mobile site home page (?o=mv&t=w) — same list the user sees on
      // the mobile site. Its preview map goes into the preview cache so
      // the home page does not fetch the same page a second time.
      try {
        final sitePage = await direct.directSiteHome(page: page);
        if (sitePage.videos.isNotEmpty) {
          _previewCache[_previewKey(page: page)] = _PreviewEntry(
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
            urls: sitePage.previews,
          );
          items = sitePage.videos;
        }
      } catch (_) {
        // Both sources failed — friendly error below.
      }
    }
    if (items.isEmpty) throw ApiException('加载失败，请重试');
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
    if (!forceRefresh) {
      final cached = lists.peek(key);
      // Cached pages are stored in display order (site order, or
      // client-sorted for API/backend results), so they are returned
      // as-is — no re-sort on cache hits.
      if (cached != null) return cached;
    }
    List<VideoItem> items;
    if (usesBackend) {
      try {
        final encoded = Uri.encodeQueryComponent(query);
        items = _videosFrom(
          await _getBackendJson(
            '/api/search?q=$encoded&page=$page&ordering=${ordering.apiValue}',
          ),
        );
        // The backend is Webmasters-backed, and the API only honours
        // mostviewed server-side — sort client-side like the fallback.
        items = _sortedSearch(items, ordering);
      } on ApiException {
        items = await _siteSearchOrApi(
          query,
          page: page,
          ordering: ordering,
        );
      }
    } else {
      items = await _siteSearchOrApi(query, page: page, ordering: ordering);
    }
    lists.put(key, items);
    return items;
  }

  /// Site search first (same videos and order as the mobile site), with
  /// the Webmasters API as fallback so search never dies when the site
  /// fetch fails or the page layout changes. The API returns a different
  /// video set (overlap 0/30 for the same query, verified live), so the
  /// fallback is a safety net, not an equivalent. Site results are
  /// already server-sorted; API results are client-sorted. The preview
  /// clip map from the site fetch is stored in the preview cache, so
  /// the search page's preview fetch is served from cache instead of
  /// fetching the same page a second time.
  Future<List<VideoItem>> _siteSearchOrApi(
    String query, {
    required int page,
    required SearchOrdering ordering,
  }) async {
    try {
      final result = await direct.directSiteSearch(
        query,
        page: page,
        ordering: ordering.siteValue,
      );
      if (result.videos.isNotEmpty) {
        _previewCache[_previewKey(
          query: query,
          ordering: ordering.siteValue,
          page: page,
        )] = _PreviewEntry(
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
          urls: result.previews,
        );
        return result.videos;
      }
    } on direct.ParseException {
      // Fall through to the API fallback below.
    }
    final items = await direct.directSearch(
      query,
      page: page,
      ordering: ordering.apiValue,
    );
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
    List<VideoItem> items;
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

  /// Preview clip URLs (v0.2.2, mobile-site style). In-memory cache,
  /// 50 minutes: the clip signatures last 1-2h, so 50 min stays inside
  /// validity. Fetched in the background after a list loads; an empty
  /// map just means "no previews for this list" and the covers stay.
  final Map<String, _PreviewEntry> _previewCache = {};

  /// Preview-cache key. [ordering] is the site sort value (mv/tr/mr/lg)
  /// so a sorted search page does not reuse another sort's clip map.
  String _previewKey({
    String? query,
    int? categoryId,
    int page = 1,
    String? ordering,
  }) => 'preview:${query ?? ''}:${categoryId ?? ''}:$page:${ordering ?? ''}';

  Future<Map<String, String>> previewUrls({
    String? query,
    int? categoryId,
    int page = 1,
    String? ordering,
  }) async {
    final key = _previewKey(
      query: query,
      categoryId: categoryId,
      page: page,
      ordering: ordering,
    );
    final entry = _previewCache[key];
    if (entry != null &&
        DateTime.now().millisecondsSinceEpoch - entry.fetchedAt <
            50 * 60 * 1000) {
      return entry.urls;
    }
    final urls = await direct.directPreviewUrls(
      query: query,
      categoryId: categoryId,
      page: page,
      ordering: ordering,
    );
    _previewCache[key] = _PreviewEntry(
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
      urls: urls,
    );
    return urls;
  }

  /// Per-video preview clip (v0.2.3 HLS fallback): resolves the muted
  /// preview URL for ONE displayed video via its detail page, because
  /// the bulk mobile-list map never contains API-listed videos (0/30
  /// overlap, verified live). Cached 50 minutes (same window as the
  /// bulk preview map); '' means no preview — the card stays on its
  /// cover. The clip is the video's own 240p HLS master URL.
  final Map<String, _PreviewEntry> _previewHlsCache = {};

  Future<String> previewHlsFor(String viewkey) async {
    final entry = _previewHlsCache[viewkey];
    if (entry != null &&
        DateTime.now().millisecondsSinceEpoch - entry.fetchedAt <
            50 * 60 * 1000) {
      return entry.urls['hls'] ?? '';
    }
    final url = await direct.directPreviewHls(viewkey);
    _previewHlsCache[viewkey] = _PreviewEntry(
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
      urls: {'hls': url},
    );
    return url;
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
