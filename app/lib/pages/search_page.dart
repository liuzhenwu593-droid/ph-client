import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

/// Duration buckets for the search filter (client-side: the Webmasters
/// API has no duration parameter, so the loaded page is filtered locally
/// by the "M:SS" duration string).
enum DurationFilter { all, short, medium, long }

extension on DurationFilter {
  String get label {
    switch (this) {
      case DurationFilter.all:
        return '全部';
      case DurationFilter.short:
        return '短片 <5分钟';
      case DurationFilter.medium:
        return '中 5-20分钟';
      case DurationFilter.long:
        return '长片 >20分钟';
    }
  }

  bool matches(VideoItem video) {
    final seconds = video.durationSeconds;
    switch (this) {
      case DurationFilter.all:
        return true;
      case DurationFilter.short:
        return seconds > 0 && seconds < 300;
      case DurationFilter.medium:
        return seconds >= 300 && seconds <= 1200;
      case DurationFilter.long:
        return seconds > 1200;
    }
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.settings,
    required this.downloads,
    required this.searchHistory,
  });

  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final AppSettings settings;
  final DownloadManager downloads;
  final SearchHistoryStore searchHistory;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final List<VideoItem> _videos = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  String _query = '';
  int _page = 1;
  bool _searched = false;
  SearchOrdering _ordering = SearchOrdering.mostViewed;
  DurationFilter _duration = DurationFilter.all;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query, {bool forceRefresh = false}) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await widget.searchHistory.add(q);
    setState(() {
      _query = q;
      _page = 1;
      _isLoading = true;
      _error = null;
      _searched = true;
      _videos.clear();
    });
    await _loadPage(1, forceRefresh: forceRefresh);
  }

  Future<void> _loadPage(int page, {bool forceRefresh = false}) async {
    try {
      final items = await widget.api.search(
        _query,
        page: page,
        ordering: _ordering,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _videos.addAll(items.where((v) => _duration.matches(v)));
        _page = page;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        _error = '搜索失败：$e';
      });
    }
  }

  void _loadMore() {
    if (_isLoading || _isLoadingMore || _error != null || !_searched) return;
    setState(() => _isLoadingMore = true);
    _loadPage(_page + 1);
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

  void _applyFilters() {
    if (_searched) {
      _search(_query);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            decoration: InputDecoration(
              hintText: '搜索视频',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        setState(() {});
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 0,
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text('排序：'),
                    ...SearchOrdering.values.map(
                      (o) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(o.label),
                          selected: _ordering == o,
                          onSelected: (_) {
                            setState(() => _ordering = o);
                            _applyFilters();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text('时长：'),
                    ...DurationFilter.values.map(
                      (d) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(d.label),
                          selected: _duration == d,
                          onSelected: (_) {
                            setState(() => _duration = d);
                            _applyFilters();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: !_searched
              ? _buildHistory()
              : VideoListView(
                  videos: _videos,
                  isLoading: _isLoading,
                  error: _error,
                  onRefresh: () => _search(_query, forceRefresh: true),
                  onLoadMore: _loadMore,
                  hasMore: _error == null,
                  onOpen: _open,
                  isFavorite: (v) => widget.favorites.isFavorite(v.viewkey),
                  onToggleFavorite: (v) async {
                    await widget.favorites.toggle(v);
                    if (mounted) setState(() {});
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHistory() {
    return ListenableBuilder(
      listenable: widget.searchHistory,
      builder: (context, _) {
        final history = widget.searchHistory.items;
        if (history.isEmpty) {
          return const Center(child: Text('输入关键词开始搜索'));
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            Row(
              children: [
                const Text(
                  '搜索历史',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => widget.searchHistory.clear(),
                  child: const Text('清空'),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: history
                  .map(
                    (q) => ActionChip(
                      label: Text(q),
                      onPressed: () {
                        _controller.text = q;
                        _search(q);
                      },
                    ),
                  )
                  .toList(),
            ),
          ],
        );
      },
    );
  }
}
