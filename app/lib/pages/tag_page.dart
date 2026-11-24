import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

/// One tag's video list (v0.2.9): opened by tapping a tag chip on the
/// player page. The tag route is the site's own: clicking a tag on the
/// site goes to /video/search?search=TAG, and the app's search already
/// parses that mobile search page first (same videos and order as the
/// mobile site), with the Webmasters API as fallback — so this page
/// just reuses [PhApi.search]. Same list behaviour as Home/Search —
/// covers with Referer, auto-play previews, load-more pagination,
/// grid toggle.
class TagPage extends StatefulWidget {
  const TagPage({
    super.key,
    required this.tag,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.settings,
    required this.downloads,
  });

  final String tag;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final AppSettings settings;
  final DownloadManager downloads;

  @override
  State<TagPage> createState() => _TagPageState();
}

class _TagPageState extends State<TagPage> {
  final List<VideoItem> _videos = [];
  final Map<String, String> _previews = {};
  final Set<String> _seenViewkeys = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({
    required bool reset,
    bool forceRefresh = false,
  }) async {
    if (reset) {
      setState(() {
        _isLoading = true;
        _error = null;
        _page = 1;
      });
    }
    try {
      final page = reset ? 1 : _page + 1;
      final items = await widget.api.search(
        widget.tag,
        page: page,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _videos.clear();
          _seenViewkeys.clear();
        }
        // Dedupe across pages: the site repeats a couple of videos
        // across pages, and a page that ignores ?page= must not show
        // the same video twice.
        for (final v in items) {
          if (_seenViewkeys.add(v.viewkey)) _videos.add(v);
        }
        _page = page;
        _isLoading = false;
        _isLoadingMore = false;
        _error = null;
      });
      _fetchPreviews(page);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        // Plain message only — never a raw exception class name.
        _error = e is ApiException ? e.message : '加载失败，请重试';
      });
    }
  }

  Future<void> _fetchPreviews(int page) async {
    try {
      final urls = await widget.api.previewUrls(
        query: widget.tag,
        ordering: SearchOrdering.mostViewed.siteValue,
        page: page,
      );
      if (!mounted || urls.isEmpty) return;
      setState(() => _previews.addAll(urls));
    } catch (_) {
      // No previews for this list: covers stay, nothing breaks.
    }
  }

  /// Per-video preview resolve (v0.2.3 HLS fallback), same as Home.
  Future<String?> _resolvePreview(String viewkey) async {
    final url = await widget.api.previewHlsFor(viewkey);
    if (url.isEmpty || !mounted) return null;
    setState(() => _previews[viewkey] = url);
    return url;
  }

  void _loadMore() {
    if (_isLoading || _isLoadingMore || _error != null) return;
    setState(() => _isLoadingMore = true);
    _load(reset: false);
  }

  void _open(VideoItem video) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          video: video,
          api: widget.api,
          favorites: widget.favorites,
          watch: widget.watch,
          settings: widget.settings,
          downloads: widget.downloads,
        ),
      ),
    );
  }

  Future<void> _toggleFavorite(VideoItem video) async {
    await widget.favorites.toggle(video);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.tag}')),
      body: ListenableBuilder(
        listenable: widget.favorites,
        builder: (context, _) {
          return VideoListView(
            videos: _videos,
            isLoading: _isLoading,
            error: _error,
            onRefresh: () => _load(reset: true, forceRefresh: true),
            onLoadMore: _loadMore,
            hasMore: _error == null,
            onOpen: _open,
            isFavorite: (v) => widget.favorites.isFavorite(v.viewkey),
            onToggleFavorite: _toggleFavorite,
            previewUrls: _previews,
            onResolvePreview: _resolvePreview,
            columns: widget.settings.gridColumns,
            emptyText: '这个标签下还没有视频',
          );
        },
      ),
    );
  }
}
