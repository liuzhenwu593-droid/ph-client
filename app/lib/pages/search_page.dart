import 'package:flutter/material.dart';

import '../models.dart';
import '../ph_api.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.api});

  final PhApi api;

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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() {
      _query = q;
      _page = 1;
      _isLoading = true;
      _error = null;
      _searched = true;
      _videos.clear();
    });
    await _loadPage(1);
  }

  Future<void> _loadPage(int page) async {
    try {
      final items = await widget.api.search(_query, page: page);
      if (!mounted) return;
      setState(() {
        _videos.addAll(items);
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
        builder: (_) => PlayerPage(video: video, api: widget.api),
      ),
    );
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
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: !_searched
              ? const Center(child: Text('输入关键词开始搜索'))
              : VideoListView(
                  videos: _videos,
                  isLoading: _isLoading,
                  error: _error,
                  onRefresh: () => _search(_query),
                  onLoadMore: _loadMore,
                  hasMore: _error == null,
                  onOpen: _open,
                ),
        ),
      ],
    );
  }
}
