import 'package:flutter/material.dart';

import '../models.dart';

/// One video row: thumbnail (16:9) + title + duration/views/rating.
class VideoCard extends StatelessWidget {
  const VideoCard({super.key, required this.video, required this.onTap});

  final VideoItem video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: video.thumb.isEmpty
                      ? Container(color: Colors.grey.shade900)
                      : Image.network(
                          video.thumb,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, _, _) =>
                              Container(color: Colors.grey.shade900),
                        ),
                ),
                if (video.duration.isNotEmpty)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        video.duration,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${video.viewsLabel}'
                    '${video.rating > 0 ? '  •  ${video.rating.toStringAsFixed(0)}% 好评' : ''}',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scrollable video list with pull-to-refresh and load-more.
/// [onLoadMore] is called when the user scrolls near the bottom.
/// [onOpen] is called when the user taps a video (the parent owns
/// navigation so this widget stays API-free).
class VideoListView extends StatelessWidget {
  const VideoListView({
    super.key,
    required this.videos,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
    required this.onLoadMore,
    required this.hasMore,
    required this.onOpen,
  });

  final List<VideoItem> videos;
  final bool isLoading;
  final String? error;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final bool hasMore;
  final void Function(VideoItem video) onOpen;

  @override
  Widget build(BuildContext context) {
    if (error != null && videos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              Text(error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onRefresh,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (videos.isEmpty && isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (videos.isEmpty) {
      return const Center(child: Text('没有结果，换个关键词试试'));
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        itemCount: videos.length + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= videos.length) {
            // Load-more sentinel.
            Future.microtask(onLoadMore);
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final video = videos[index];
          return VideoCard(
            video: video,
            onTap: () => onOpen(video),
          );
        },
      ),
    );
  }
}
