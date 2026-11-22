import 'package:flutter/material.dart';

import '../models.dart';
import 'thumb_image.dart';

/// One video row: thumbnail (16:9) + title + duration/views/rating.
/// [isFavorite]/[onToggleFavorite] add the star button; when they are
/// null no star is shown. [onRefreshThumb] is called once when a cover
/// fails to load (favorites use it to fetch a fresh signed thumb URL).
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.isFavorite,
    this.onToggleFavorite,
    this.onRefreshThumb,
  });

  final VideoItem video;
  final VoidCallback onTap;
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;
  final Future<String?> Function(VideoItem video)? onRefreshThumb;

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
                  child: ThumbImage(
                    url: video.thumb,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    onRefreshUrl: onRefreshThumb == null
                        ? null
                        : () => onRefreshThumb!(video),
                  ),
                ),
                if (video.duration.isNotEmpty)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        video.duration,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                if (isFavorite != null && onToggleFavorite != null)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton(
                      icon: Icon(
                        isFavorite! ? Icons.star : Icons.star_border,
                        color: isFavorite! ? Colors.amber : Colors.white,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black45,
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: onToggleFavorite,
                      tooltip: isFavorite! ? '取消收藏' : '收藏',
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
    this.isFavorite,
    this.onToggleFavorite,
    this.onRefreshThumb,
  });

  final List<VideoItem> videos;
  final bool isLoading;
  final String? error;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final bool hasMore;
  final void Function(VideoItem video) onOpen;
  final bool Function(VideoItem video)? isFavorite;
  final void Function(VideoItem video)? onToggleFavorite;
  final Future<String?> Function(VideoItem video)? onRefreshThumb;

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
              FilledButton(onPressed: onRefresh, child: const Text('重试')),
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
          // Prefetch the next few covers so scrolling shows them instantly.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              precacheThumbs(
                context,
                videos.skip(index + 1).take(3).map((v) => v.thumb),
              );
            }
          });
          return VideoCard(
            video: video,
            onTap: () => onOpen(video),
            isFavorite: isFavorite == null ? null : isFavorite!(video),
            onToggleFavorite: onToggleFavorite == null
                ? null
                : () => onToggleFavorite!(video),
            onRefreshThumb: onRefreshThumb,
          );
        },
      ),
    );
  }
}
