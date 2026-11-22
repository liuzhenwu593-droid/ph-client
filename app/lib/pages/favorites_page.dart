import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import '../widgets/video_list.dart';
import 'player_page.dart';

/// Favorites (starred videos) only, all local.
/// Watch history lives on its own tab now (HistoryPage, v0.2.2).
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({
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
      listenable: favorites,
      builder: (context, _) {
        final favs = favorites.items;
        return ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '我的收藏',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            if (favs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  '还没有收藏，点视频卡片右上角的星星就能收藏。',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              ...favs.map(
                (video) => VideoCard(
                  video: video,
                  onTap: () => _open(context, video),
                  isFavorite: true,
                  onToggleFavorite: () => favorites.toggle(video),
                  onRefreshThumb: (v) async {
                    final fresh = await api.refreshThumb(v.viewkey);
                    if (fresh.isEmpty) return null;
                    await favorites.updateThumb(v.viewkey, fresh);
                    return fresh;
                  },
                ),
              ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
