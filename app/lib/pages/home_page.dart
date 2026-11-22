import 'package:flutter/material.dart';

import '../models.dart';
import '../ph_api.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api});

  final PhApi api;

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
        builder: (_) => PlayerPage(video: video, api: widget.api),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return VideoListView(
      videos: _videos,
      isLoading: _isLoading,
      error: _error,
      onRefresh: () => _load(reset: true),
      onLoadMore: _loadMore,
      hasMore: _error == null,
      onOpen: _open,
    );
  }
}
