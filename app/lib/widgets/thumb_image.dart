import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Headers every phncdn thumbnail request must carry.
///
/// Root cause, verified live 2026-11-22: phncdn serves thumbs from three
/// hosts and one of them — pix-cdn77.phncdn.com, ~51% of thumbs over 90
/// videos — answers **403** to a request with no headers, and 200 with a
/// browser Referer. pix-fl and ei.phncdn.com answer 200 either way, so
/// the failure looked random per video. The app used to send no headers
/// at all (`Image.network`), so about half of all covers were grey boxes.
/// A disk cache alone cannot fix a 403; the headers are the fix, the
/// cache is what makes repeat views instant.
const _thumbHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  'Referer': 'https://www.pornhub.com/',
};

/// Thumbnail disk cache: 7 days, max 200 files. The bytes are cached, not
/// the signed URL — a thumb URL's 24h signature only gates the download,
/// so a cached image stays valid after its URL expires.
final CacheManager _thumbCacheManager = CacheManager(
  Config(
    'phThumbs',
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 200,
  ),
);

/// URLs already prefetched this run, so scrolling never re-triggers them.
final Set<String> _precached = <String>{};

/// Prefetch up to [limit] thumbnails in the background (fire-and-forget).
/// Used by lists for the next few cards below the fold.
void precacheThumbs(BuildContext context, Iterable<String> urls,
    {int limit = 6}) {
  var count = 0;
  for (final url in urls) {
    if (url.isEmpty || _precached.contains(url)) continue;
    if (count >= limit) break;
    count++;
    _precached.add(url);
    unawaited(
      precacheImage(
        CachedNetworkImageProvider(
          url,
          cacheManager: _thumbCacheManager,
          headers: _thumbHeaders,
        ),
        context,
      ),
    );
  }
}

/// One video thumbnail: cached, with headers, a loading spinner and a
/// tap-to-retry error state (so a failed cover never looks like "no cover").
/// [onRefreshUrl] is called once on error when provided (favorites use it
/// to fetch a fresh thumb for a stored video whose signed URL expired);
/// when it returns a different non-empty URL, that URL is loaded instead.
class ThumbImage extends StatefulWidget {
  const ThumbImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.compact = false,
    this.onRefreshUrl,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Compact mode (e.g. the 72x40 download list thumb): error state is
  /// just an icon, no retry text — the text would not fit.
  final bool compact;

  final Future<String?> Function()? onRefreshUrl;

  @override
  State<ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<ThumbImage> {
  String? _overrideUrl;
  int _retryKey = 0;
  bool _refreshTried = false;

  String get _url => _overrideUrl ?? widget.url;

  Widget _greyBox(Widget child) {
    return Container(
      color: Colors.grey.shade900,
      width: widget.width,
      height: widget.height,
      child: child,
    );
  }

  Future<void> _retry() async {
    if (_refreshTried || widget.onRefreshUrl == null) {
      if (mounted) setState(() => _retryKey++);
      return;
    }
    _refreshTried = true;
    final fresh = await widget.onRefreshUrl!();
    if (!mounted) return;
    if (fresh != null && fresh.isNotEmpty && fresh != _url) {
      setState(() {
        _overrideUrl = fresh;
        _retryKey++;
      });
    } else {
      setState(() => _retryKey++);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_url.isEmpty) {
      return _greyBox(
        const Center(child: Icon(Icons.image_not_supported)),
      );
    }
    return CachedNetworkImage(
      key: ValueKey('$_retryKey:$_url'),
      imageUrl: _url,
      cacheManager: _thumbCacheManager,
      httpHeaders: _thumbHeaders,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      placeholder: (context, url) => _greyBox(
        const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      errorWidget: (context, url, error) => GestureDetector(
        onTap: _retry,
        child: _greyBox(
          Center(
            child: widget.compact
                ? const Icon(Icons.broken_image)
                : const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image),
                      SizedBox(height: 4),
                      Text('封面加载失败，点我重试', style: TextStyle(fontSize: 12)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
