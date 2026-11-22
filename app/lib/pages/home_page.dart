import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.settings,
    required this.downloads,
  });

  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final AppSettings settings;
  final DownloadManager downloads;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<VideoItem> _videos = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    // Within 5 minutes of the last load, show the cached list at once
    // and refresh silently in the background instead of spinning.
    // (v0.2.1: the "继续观看" row was removed; resume still works from
    // the player itself, and resume points are still saved.)
    final cached = widget.api.peekHome(page: 1);
    if (cached != null) {
      _videos.addAll(cached);
      _load(reset: true, background: true);
    } else {
      _load(reset: true);
    }
  }

  Future<void> _load({
    required bool reset,
    bool background = false,
    bool forceRefresh = false,
  }) async {
    if (reset && !background) {
      setState(() {
        _isLoading = true;
        _error = null;
        _page = 1;
      });
    }
    try {
      final page = reset ? 1 : _page + 1;
      // A background refresh must actually fetch: api.home() returns the
      // cached list unless forceRefresh is set, so a silent refresh with
      // forceRefresh: false would be a no-op.
      final items = await widget.api.home(
        page: page,
        forceRefresh: forceRefresh || background,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _videos.clear();
        }
        _videos.addAll(items);
        _page = page;
        _isLoading = false;
        _isLoadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        // A failed background refresh must not wipe the cached list.
        if (!background) _error = '加载失败：$e';
      });
    }
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
    return ListenableBuilder(
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
        );
      },
    );
  }
}
