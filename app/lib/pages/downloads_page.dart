import 'dart:io';

import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../settings.dart';
import 'player_page.dart';

/// Download manager: progress, cancel, play offline, delete.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({
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

  Future<void> _play(BuildContext context, DownloadItem item) async {
    final path = await downloads.localPlaylistPath(item);
    final file = File(path);
    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('本地文件找不到了，请删除后重新下载')));
      }
      return;
    }
    final video = VideoItem(
      viewkey: item.viewkey,
      title: item.title,
      duration: item.duration,
      views: 0,
      rating: 0,
      thumb: item.thumb,
      url: '',
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          video: video,
          api: api,
          favorites: favorites,
          watch: watch,
          settings: settings,
          downloads: downloads,
          localFile: file,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的下载')),
      body: ListenableBuilder(
        listenable: downloads,
        builder: (context, _) {
          final items = downloads.items;
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有下载。\n打开视频点右上角的下载按钮，选画质就能离线看。',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final downloading = item.status == DownloadStatus.downloading;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: item.thumb.isEmpty
                      ? const Icon(Icons.video_library, size: 40)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(
                            item.thumb,
                            width: 72,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.video_library, size: 40),
                          ),
                        ),
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item.qualityLabel}  •  ${item.duration}'
                        '${item.status == DownloadStatus.done ? '  •  ${item.sizeLabel}' : ''}',
                      ),
                      if (downloading) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: item.progress),
                        const SizedBox(height: 4),
                        Text(
                          '下载中 ${item.downloadedSegments}/${item.totalSegments} 分片'
                          '${item.sizeBytes > 0 ? '  •  ${item.sizeLabel}' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                      if (item.status == DownloadStatus.failed)
                        Text(
                          '下载失败：${item.error}',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (downloading)
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: '取消下载',
                          onPressed: downloads.cancelActive,
                        )
                      else ...[
                        if (item.status == DownloadStatus.done)
                          IconButton(
                            icon: const Icon(Icons.play_arrow),
                            tooltip: '播放',
                            onPressed: () => _play(context, item),
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '删除',
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('删除这个下载？'),
                                content: const Text('本地文件也会一起删掉。'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await downloads.deleteDownload(item);
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
