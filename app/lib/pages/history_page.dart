import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

/// Watch history only (v0.2.2: split out of FavoritesPage).
/// Storage and the 50-entry cap are unchanged (WatchStore); tapping an
/// entry opens the player, which resumes from its saved position.
/// "清空历史" also clears all resume points, as before.
/// Layout follows the 1/2/3-column toggle (v0.2.2) like the other lists.
class HistoryPage extends StatelessWidget {
  const HistoryPage({
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

  void _open(BuildContext context, VideoItem video) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          video: video,
          api: api,
          favorites: favorites,
          watch: watch,
          settings: settings,
          downloads: downloads,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([favorites, watch]),
      builder: (context, _) {
        final history = watch.entries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  const Text(
                    '观看历史',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (history.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('清空观看历史？'),
                            content: const Text('会同时清除所有续播断点。'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('清空'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) await watch.clear();
                      },
                      child: const Text('清空历史'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: VideoListView(
                videos: history.map((e) => e.video).toList(),
                isLoading: false,
                error: null,
                onRefresh: () async {},
                onLoadMore: () {},
                hasMore: false,
                onOpen: (v) => _open(context, v),
                isFavorite: (v) => favorites.isFavorite(v.viewkey),
                onToggleFavorite: (v) => favorites.toggle(v),
                columns: settings.gridColumns,
                emptyText: '还没有看过视频。',
              ),
            ),
          ],
        );
      },
    );
  }
}
