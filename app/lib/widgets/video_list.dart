import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../models.dart';
import 'preview_player.dart';
import 'thumb_image.dart';

/// One video row: thumbnail (16:9) + title + duration/views/rating.
/// [isFavorite]/[onToggleFavorite] add the star button; when they are
/// null no star is shown. [onRefreshThumb] is called once when a cover
/// fails to load (favorites use it to fetch a fresh signed thumb URL).
/// When [autoplayPreview] is true and [previewUrl] is set, the card
/// plays the muted preview clip over the cover instead of the still
/// image (v0.2.2, mobile-site style).
/// [compact] is the 2/3-column grid mode: no outer margin, tighter
/// padding, views only on one line (no rating) so the card fits.
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.isFavorite,
    this.onToggleFavorite,
    this.onRefreshThumb,
    this.previewUrl,
    this.autoplayPreview = false,
    this.compact = false,
  });

  final VideoItem video;
  final VoidCallback onTap;
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;
  final Future<String?> Function(VideoItem video)? onRefreshThumb;
  final String? previewUrl;
  final bool autoplayPreview;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final showPreview =
        autoplayPreview && previewUrl != null && previewUrl!.isNotEmpty;
    return Card(
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                  child: showPreview
                      ? PreviewPlayer(
                          previewUrl: previewUrl!,
                          thumbUrl: video.thumb,
                          onRefreshThumb: onRefreshThumb == null
                              ? null
                              : () => onRefreshThumb!(video),
                        )
                      : ThumbImage(
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
              padding: compact
                  ? const EdgeInsets.all(8)
                  : const EdgeInsets.all(10),
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
                  if (compact)
                    Text(
                      video.viewsLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 11,
                      ),
                    )
                  else
                    Text(
                      '${video.viewsLabel}'
                      '${video.rating > 0 ? '  •  ${video.rating.toStringAsFixed(0)}% 好评' : ''}',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                      ),
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
///
/// Auto-play previews (v0.2.2, mobile-site style): [previewUrls] maps a
/// video's viewkey to its small muted preview clip. The most-visible
/// card (visible fraction >= 0.5) plays its clip, muted and looped;
/// only one preview plays at a time, and previews stop when the app
/// goes to the background or a player page is pushed on top.
/// When the most-visible card has no clip URL yet, [onResolvePreview]
/// resolves that one video's clip in the background (v0.2.3 HLS
/// fallback — the bulk map never contains API-listed videos).
///
/// Layout (v0.2.2): [columns] is 1 (the old full-width list), 2 or 3.
/// In grid mode the cards are compact (16:9 cover + 1-2 line title +
/// duration badge); pull-to-refresh, load-more and auto-play previews
/// all work the same as in list mode.
class VideoListView extends StatefulWidget {
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
    this.previewUrls = const {},
    this.onResolvePreview,
    this.columns = 1,
    this.emptyText = '没有结果，换个关键词试试',
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

  /// viewkey -> preview mp4 URL. Empty map = no previews for this list.
  final Map<String, String> previewUrls;

  /// Called when the most-visible card has no clip URL yet (v0.2.3):
  /// the parent resolves that one video's preview (HLS fallback) and
  /// puts the URL into [previewUrls]. Null = no per-video resolving.
  final Future<String?> Function(String viewkey)? onResolvePreview;

  /// 1 = full-width list (default), 2 or 3 = grid.
  final int columns;

  /// Shown when the list is empty and not loading.
  final String emptyText;

  @override
  State<VideoListView> createState() => _VideoListViewState();
}

class _VideoListViewState extends State<VideoListView>
    with WidgetsBindingObserver {
  /// Last reported visible fraction per card, keyed by "$index:viewkey".
  final Map<String, double> _fractions = {};

  /// Key of the card currently playing its preview, or null.
  String? _activeKey;
  Timer? _debounce;

  /// Viewkeys with a clip resolve currently in flight (v0.2.3).
  final Set<String> _resolving = {};

  /// Viewkeys whose last resolve failed, with the failure time: not
  /// retried for 60s so a stuck card cannot spam the network while it
  /// stays visible.
  final Map<String, int> _resolveFailedAt = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Fires when this route is pushed/popped: re-evaluate so previews
    // restart when coming back from the player.
    _scheduleEvaluate();
  }

  @override
  void didUpdateWidget(VideoListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Always prune: pages mutate their video list in place (same list
    // object), so identity comparison cannot detect a refresh — stale
    // fractions would otherwise pick a card that no longer exists.
    final alive = widget.videos
        .asMap()
        .entries
        .map((e) => '${e.key}:${e.value.viewkey}')
        .toSet();
    _fractions.removeWhere((key, _) => !alive.contains(key));
    if (_activeKey != null && !alive.contains(_activeKey)) {
      _activeKey = null;
    }
    _scheduleEvaluate();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never autoplay while backgrounded: stop the current preview at
    // once; coming back re-evaluates from the stored fractions.
    if (state != AppLifecycleState.resumed) {
      if (_activeKey != null) setState(() => _activeKey = null);
    } else {
      _scheduleEvaluate();
    }
  }

  void _onVisibility(String key, double fraction) {
    _fractions[key] = fraction;
    _scheduleEvaluate();
  }

  /// Debounced: fast scrolling must not start a preview for every card
  /// it flies past — only the card the user actually stops on plays.
  void _scheduleEvaluate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _evaluate);
  }

  void _evaluate() {
    if (!mounted) return;
    // A player page on top: stop previews (the list is covered).
    // lifecycleState is null before the first resume; only an explicit
    // non-resumed state pauses previews.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!isCurrent ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      if (_activeKey != null) setState(() => _activeKey = null);
      return;
    }
    // Most-visible card (fraction >= 0.5), whether or not its clip URL
    // is known yet. v0.2.2 only considered cards that already had a
    // URL, so a card whose clip was never resolved could never become
    // active — and nothing ever resolved it. That is why previews never
    // played on API-sourced lists: the bulk map never contains those
    // videos (v0.2.3 root cause, 0/30 overlap verified live).
    String? bestKey;
    String? bestViewkey;
    var bestFraction = 0.5;
    for (final entry in _fractions.entries) {
      final key = entry.key;
      final fraction = entry.value;
      if (fraction < bestFraction) continue;
      bestKey = key;
      bestFraction = fraction;
      bestViewkey = key.substring(key.indexOf(':') + 1);
    }
    if (bestKey == null || bestViewkey == null) {
      if (_activeKey != null) setState(() => _activeKey = null);
      return;
    }
    final url = widget.previewUrls[bestViewkey];
    if (url != null && url.isNotEmpty) {
      if (bestKey != _activeKey) setState(() => _activeKey = bestKey);
    } else {
      // Most-visible card has no clip yet: stop any playing preview
      // and resolve this card's clip in the background (HLS fallback,
      // v0.2.3). When the URL arrives the parent rebuilds this list
      // and _evaluate runs again via didUpdateWidget.
      if (_activeKey != null) setState(() => _activeKey = null);
      _maybeResolvePreview(bestViewkey);
    }
  }

  /// Resolve one video's preview clip in the background (at most one
  /// in-flight request per video; failures are not retried for 60s).
  void _maybeResolvePreview(String viewkey) {
    final resolve = widget.onResolvePreview;
    if (resolve == null) return;
    if (_resolving.contains(viewkey)) return;
    final failedAt = _resolveFailedAt[viewkey];
    if (failedAt != null &&
        DateTime.now().millisecondsSinceEpoch - failedAt < 60000) {
      return;
    }
    _resolving.add(viewkey);
    resolve(viewkey).then((url) {
      _resolving.remove(viewkey);
      if (url == null || url.isEmpty) {
        _resolveFailedAt[viewkey] = DateTime.now().millisecondsSinceEpoch;
      }
      // The parent stores a good URL in previewUrls; didUpdateWidget
      // re-evaluates and starts the preview.
    }).catchError((_) {
      _resolving.remove(viewkey);
      _resolveFailedAt[viewkey] = DateTime.now().millisecondsSinceEpoch;
    });
  }

  @override
  Widget build(BuildContext context) {
    final videos = widget.videos;
    if (widget.error != null && videos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              Text(widget.error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: widget.onRefresh,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (videos.isEmpty && widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (videos.isEmpty) {
      return Center(child: Text(widget.emptyText));
    }
    if (widget.columns > 1) {
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(12),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: widget.columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  // Compact card: 16:9 cover + title (1-2 lines) + one
                  // meta line. Slightly taller than the worst case so a
                  // two-line title never overflows the cell.
                  childAspectRatio: widget.columns == 2 ? 1.0 : 0.8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildCard(context, index),
                  childCount: videos.length,
                ),
              ),
            ),
            if (widget.hasMore)
              SliverToBoxAdapter(
                child: Builder(
                  builder: (context) {
                    // Load-more sentinel, same as the list mode below.
                    Future.microtask(widget.onLoadMore);
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  },
                ),
              ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView.builder(
        itemCount: videos.length + (widget.hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= videos.length) {
            // Load-more sentinel.
            Future.microtask(widget.onLoadMore);
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _buildCard(context, index);
        },
      ),
    );
  }

  /// One card with visibility tracking (for auto-play previews) and
  /// cover prefetch. Shared by list and grid modes.
  Widget _buildCard(BuildContext context, int index) {
    final videos = widget.videos;
    final video = videos[index];
    final cardKey = '$index:${video.viewkey}';
    // Prefetch the next few covers so scrolling shows them instantly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        precacheThumbs(
          context,
          videos.skip(index + 1).take(3).map((v) => v.thumb),
        );
      }
    });
    return VisibilityDetector(
      key: ValueKey('vis:$cardKey'),
      onVisibilityChanged: (info) =>
          _onVisibility(cardKey, info.visibleFraction),
      child: VideoCard(
        video: video,
        onTap: () => widget.onOpen(video),
        isFavorite: widget.isFavorite == null
            ? null
            : widget.isFavorite!(video),
        onToggleFavorite: widget.onToggleFavorite == null
            ? null
            : () => widget.onToggleFavorite!(video),
        onRefreshThumb: widget.onRefreshThumb,
        previewUrl: widget.previewUrls[video.viewkey],
        autoplayPreview: _activeKey == cardKey,
        compact: widget.columns > 1,
      ),
    );
  }
}
