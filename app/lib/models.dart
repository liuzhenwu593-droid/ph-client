// Plain data models. No Flutter imports: this file is analyzable with a
// standalone Dart SDK (see README.md).

class VideoItem {
  const VideoItem({
    required this.viewkey,
    required this.title,
    required this.duration,
    required this.views,
    required this.rating,
    required this.thumb,
    required this.url,
    this.publishDate = '',
    this.tags = const [],
    this.categories = const [],
  });

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) {
      if (value is List) {
        return value
            .map(
              (e) => e is Map
                  ? (e['tag_name'] ?? e['category'] ?? e['pornstar_name'] ?? '')
                        .toString()
                  : e.toString(),
            )
            .where((s) => s.isNotEmpty)
            .toList();
      }
      return const [];
    }

    return VideoItem(
      viewkey: (json['viewkey'] ?? json['video_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      duration: (json['duration'] ?? '').toString(),
      views: json['views'] is num ? (json['views'] as num).toInt() : 0,
      rating: json['rating'] is num ? (json['rating'] as num).toDouble() : 0,
      thumb: (json['thumb'] ?? json['default_thumb'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      publishDate: (json['publish_date'] ?? '').toString(),
      tags: strings(json['tags']),
      categories: strings(json['categories']),
    );
  }

  final String viewkey;
  final String title;
  final String duration;
  final int views;
  final double rating;
  final String thumb;
  final String url;
  final String publishDate;
  final List<String> tags;
  final List<String> categories;

  Map<String, dynamic> toJson() => {
    'viewkey': viewkey,
    'title': title,
    'duration': duration,
    'views': views,
    'rating': rating,
    'thumb': thumb,
    'url': url,
    'publish_date': publishDate,
    'tags': tags,
    'categories': categories,
  };

  /// "7:24" -> 444, "1:02:03" -> 3723. Used by the duration filter.
  int get durationSeconds {
    final parts = duration.split(':').map(int.tryParse).toList();
    if (parts.isEmpty || parts.any((p) => p == null)) return 0;
    var total = 0;
    for (final p in parts) {
      total = total * 60 + p!;
    }
    return total;
  }

  String get viewsLabel {
    if (views >= 1000000)
      return '${(views / 1000000).toStringAsFixed(1)}M views';
    if (views >= 1000) return '${(views / 1000).toStringAsFixed(1)}K views';
    return '$views views';
  }
}

class VideoSource {
  const VideoSource({
    required this.quality,
    required this.format,
    required this.url,
    required this.width,
    required this.height,
    required this.isDefault,
  });

  factory VideoSource.fromJson(Map<String, dynamic> json) {
    return VideoSource(
      quality: (json['quality'] ?? '').toString(),
      format: (json['format'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      width: json['width'] is num ? (json['width'] as num).toInt() : 0,
      height: json['height'] is num ? (json['height'] as num).toInt() : 0,
      isDefault: json['default'] == true,
    );
  }

  final String quality;
  final String format;
  final String url;
  final int width;
  final int height;
  final bool isDefault;

  Map<String, dynamic> toJson() => {
    'quality': quality,
    'format': format,
    'url': url,
    'width': width,
    'height': height,
    'default': isDefault,
  };

  String get label => quality.isEmpty ? format.toUpperCase() : '${quality}p';
}

class VideoDetail {
  const VideoDetail({
    required this.viewkey,
    required this.title,
    required this.duration,
    required this.thumb,
    required this.sources,
  });

  factory VideoDetail.fromJson(Map<String, dynamic> json) {
    final raw = json['sources'];
    final sources = <VideoSource>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>)
          sources.add(VideoSource.fromJson(item));
      }
    }
    return VideoDetail(
      viewkey: (json['viewkey'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      duration: json['duration'] is num
          ? (json['duration'] as num).toInt()
          : int.tryParse((json['duration'] ?? '').toString()) ?? 0,
      thumb: (json['thumb'] ?? '').toString(),
      sources: sources,
    );
  }

  final String viewkey;
  final String title;
  final int duration;
  final String thumb;
  final List<VideoSource> sources;

  Map<String, dynamic> toJson() => {
    'viewkey': viewkey,
    'title': title,
    'duration': duration,
    'thumb': thumb,
    'sources': sources.map((s) => s.toJson()).toList(),
  };

  /// HLS first, highest quality first — same order the backend returns.
  List<VideoSource> get hlsSources =>
      sources.where((s) => s.format == 'hls' && s.url.isNotEmpty).toList();

  VideoSource? get bestSource {
    final hls = hlsSources;
    if (hls.isEmpty) return sources.isEmpty ? null : sources.first;
    return hls.first;
  }

  /// Fast-start source: the lowest HLS quality that is still >= 480p
  /// (usually 480p itself). All qualities from one detail-page fetch share
  /// the same CDN host (verified live 2026-11-22: all four qualities are
  /// either ev-h or hv-h together), so verifying this one URL validates
  /// the whole set and the player can upgrade to 1080p later for free.
  /// Falls back to the lowest available HLS quality when nothing is >= 480p.
  VideoSource? get startSource {
    final hls = hlsSources;
    if (hls.isEmpty) return bestSource;
    final atLeast480 = hls.where((s) => s.height >= 480).toList();
    if (atLeast480.isNotEmpty) {
      atLeast480.sort((a, b) => a.height.compareTo(b.height));
      return atLeast480.first;
    }
    final sorted = List<VideoSource>.from(hls)
      ..sort((a, b) => a.height.compareTo(b.height));
    return sorted.first;
  }

  String get durationLabel {
    if (duration <= 0) return '';
    final m = duration ~/ 60;
    final s = duration % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// One category from the Webmasters category list (243 entries).
/// The id is what the site's /video?c=<id> pages use.
class CategoryItem {
  const CategoryItem({required this.id, required this.name});

  factory CategoryItem.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    return CategoryItem(
      id: rawId is num ? rawId.toInt() : int.tryParse('$rawId') ?? 0,
      name: (json['category'] ?? json['name'] ?? '').toString(),
    );
  }

  final int id;
  final String name;
}
