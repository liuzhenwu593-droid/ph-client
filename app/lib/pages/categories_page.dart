import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

/// Category browser (243 categories from the Webmasters list).
/// Tapping a category opens its videos via the site's `/video?c=<id>` pages.
class CategoriesPage extends StatefulWidget {
  const CategoriesPage({
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
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<CategoryItem>? _categories;
  String? _error;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.categories();
      if (!mounted) return;
      setState(() {
        _categories = items;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '分类加载失败：$e';
        _isLoading = false;
      });
    }
  }

  void _open(CategoryItem category) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CategoryVideosPage(
          category: category,
          api: widget.api,
          favorites: widget.favorites,
          watch: widget.watch,
          settings: widget.settings,
          downloads: widget.downloads,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final categories = _categories ?? const [];
    if (categories.isEmpty) {
      return const Center(child: Text('没有分类'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 3.2,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final category = categories[index];
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(category),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class CategoryVideosPage extends StatefulWidget {
  const CategoryVideosPage({
    super.key,
    required this.category,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.settings,
    required this.downloads,
  });

  final CategoryItem category;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final AppSettings settings;
  final DownloadManager downloads;

  @override
  State<CategoryVideosPage> createState() => _CategoryVideosPageState();
}

class _CategoryVideosPageState extends State<CategoryVideosPage> {
  final List<VideoItem> _videos = [];
  final Map<String, String> _previews = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset, bool forceRefresh = false}) async {
    if (reset) {
      setState(() {
        _isLoading = true;
        _error = null;
        _page = 1;
      });
    }
    try {
      final page = reset ? 1 : _page + 1;
      final items = await widget.api.categoryVideos(
        widget.category.id,
        page: page,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _videos.clear();
        _videos.addAll(items);
        _page = page;
        _isLoading = false;
        _isLoadingMore = false;
      });
      // Previews (v0.2.2): fetch in the background, never block the list.
      _fetchPreviews(page);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isLoadingMore = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _fetchPreviews(int page) async {
    try {
      final urls = await widget.api.previewUrls(
        categoryId: widget.category.id,
        page: page,
      );
      if (!mounted || urls.isEmpty) return;
      setState(() => _previews.addAll(urls));
    } catch (_) {
      // No previews for this list: covers stay, nothing breaks.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.name)),
      body: ListenableBuilder(
        listenable: widget.favorites,
        builder: (context, _) => VideoListView(
          videos: _videos,
          isLoading: _isLoading,
          error: _error,
          onRefresh: () => _load(reset: true, forceRefresh: true),
          onLoadMore: _loadMore,
          hasMore: _error == null,
          onOpen: _open,
          isFavorite: (v) => widget.favorites.isFavorite(v.viewkey),
          onToggleFavorite: (v) async {
            await widget.favorites.toggle(v);
            if (mounted) setState(() {});
          },
          previewUrls: _previews,
        ),
      ),
    );
  }
}
