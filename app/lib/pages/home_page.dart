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
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _isLoading = true;
        _error = null;
        _page = 1;
      });
    }
    try {
      final page = reset ? 1 : _page + 1;
      final items = await widget.api.home(page: page);
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
        _error = '加载失败：$e';
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
      listenable: Listenable.merge([widget.favorites, widget.watch]),
      builder: (context, _) {
        final resume = widget.watch.continueWatching;
        return Column(
          children: [
            if (resume.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '继续观看',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              SizedBox(
                height: 132,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: resume.length,
                  itemBuilder: (context, index) {
                    final entry = resume[index];
                    return _ResumeCard(
                      entry: entry,
                      onTap: () => _open(entry.video),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
            ],
            Expanded(
              child: VideoListView(
                videos: _videos,
                isLoading: _isLoading,
                error: _error,
                onRefresh: () => _load(reset: true),
                onLoadMore: _loadMore,
                hasMore: _error == null,
                onOpen: _open,
                isFavorite: (v) => widget.favorites.isFavorite(v.viewkey),
                onToggleFavorite: _toggleFavorite,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.entry, required this.onTap});

  final WatchEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: entry.video.thumb.isEmpty
                        ? Container(color: Colors.grey.shade900)
                        : Image.network(
                            entry.video.thumb,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            errorBuilder: (_, _, _) =>
                                Container(color: Colors.grey.shade900),
                          ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: entry.progress,
                      minHeight: 3,
                      backgroundColor: Colors.black45,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.redAccent,
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  entry.video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '上次看到 ${entry.positionLabel}',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
