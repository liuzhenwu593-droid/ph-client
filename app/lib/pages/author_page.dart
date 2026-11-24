import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/thumb_image.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

/// One author's video list (v0.2.8): opened by tapping the author row
/// on the player page. Same list behaviour as Home/Search — covers with
/// Referer, auto-play previews, load-more pagination, grid toggle.
/// The author comes from the detail page's about tab (see
/// extractAuthor in ph_parse.dart); the list itself is parsed from the
/// author's mobile profile page (see directAuthorVideos).
class AuthorPage extends StatefulWidget {
  const AuthorPage({
    super.key,
    required this.author,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.settings,
    required this.downloads,
  });

  final AuthorInfo author;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final AppSettings settings;
  final DownloadManager downloads;

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  final List<VideoItem> _videos = [];
  final Map<String, String> _previews = {};
  final Set<String> _seenViewkeys = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _page = 1;
  AuthorOrdering _ordering = AuthorOrdering.mostRecent;

  /// /model and /pornstar sort server-side (?o=mv/?o=lg on the
  /// /videos subpage, verified live 2026-11-24); /channels and /users
  /// cannot sort server-side (?o= kills the list / 404s), so those
  /// sorts are applied client-side over the loaded videos below.
  bool get _serverSorted =>
      widget.author.path.startsWith('/model/') ||
      widget.author.path.startsWith('/pornstar/');

  /// Re-sort the accumulated list for channel/user pages (client-side
  /// only — views and duration are known per card). Latest is the
  /// server's default order, so it needs no sorting.
  void _applyClientSort() {
    if (_serverSorted || _ordering == AuthorOrdering.mostRecent) return;
    if (_ordering == AuthorOrdering.mostViewed) {
      _videos.sort((a, b) => b.views.compareTo(a.views));
    } else {
      _videos.sort(
        (a, b) => b.durationSeconds.compareTo(a.durationSeconds),
      );
    }
  }

  void _setOrdering(AuthorOrdering ordering) {
    if (ordering == _ordering) return;
    setState(() => _ordering = ordering);
    _load(reset: true);
  }

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
      final items = await widget.api.authorVideos(
        widget.author.path,
        page: page,
        ordering: _ordering,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _videos.clear();
          _seenViewkeys.clear();
        }
        // Dedupe across pages: a page that ignores ?page= (or a site
        // repeat) must not show the same video twice.
        for (final v in items) {
          if (_seenViewkeys.add(v.viewkey)) _videos.add(v);
        }
        _applyClientSort();
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
        authorPath: widget.author.path,
        page: page,
        ordering: _ordering.name,
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
    final author = widget.author;
    final meta = [
      if (author.videosText.isNotEmpty) author.videosText,
      if (author.subscribersText.isNotEmpty) author.subscribersText,
    ].join('  •  ');
    return Scaffold(
      appBar: AppBar(title: Text(author.name)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                if (author.avatarUrl.isNotEmpty)
                  ClipOval(
                    child: ThumbImage(
                      url: author.avatarUrl,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      compact: true,
                    ),
                  )
                else
                  const CircleAvatar(
                    radius: 24,
                    child: Icon(Icons.person),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        author.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          meta,
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Sort chips (v0.2.10): 最新 / 最热 / 最长. /model and
          // /pornstar sort server-side; /channels and /users sort
          // client-side over the loaded videos (see _applyClientSort).
          // Default stays 最新, the same order as before.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: AuthorOrdering.values
                  .map(
                    (o) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(o.label),
                        selected: _ordering == o,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => _setOrdering(o),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
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
                  emptyText: '这个作者还没有视频',
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
