// Plain data models. No Flutter imports: this file is analyzable with a
// standalone Dart SDK (see README.md).

/// The uploader/author of one video (v0.2.8).
///
/// Parsed from the desktop detail page's "about" tab
/// (`video-detailed-info` -> `usernameWrap clearfix`): it is the ONLY
/// author block that belongs to the current video. The page also
/// carries ~77 `.videoUploaderBlock` divs, but those belong to related
/// video cards — the first one is a related video's uploader, NOT this
/// video's (verified live 2026-11-24: the first block on
/// ph5a7f1ba584481 says "Net Video Girls" while the about tab says
/// "Alex Adams", the actual author). [path] is one of
/// `/channels/<slug>`, `/model/<slug>`, `/users/<slug>`, `/pornstar/<slug>`.
class AuthorInfo {
  const AuthorInfo({
    required this.name,
    required this.path,
    this.avatarUrl = '',
    this.videosText = '',
    this.subscribersText = '',
  });

  factory AuthorInfo.fromJson(Map<String, dynamic> json) => AuthorInfo(
    name: (json['name'] ?? '').toString(),
    path: (json['path'] ?? '').toString(),
    avatarUrl: (json['avatarUrl'] ?? '').toString(),
    videosText: (json['videosText'] ?? '').toString(),
    subscribersText: (json['subscribersText'] ?? '').toString(),
  );

  final String name;
  final String path;
  final String avatarUrl;

  /// Raw labels from the about tab, e.g. "357 Videos", "2.1M Subscribers".
  final String videosText;
  final String subscribersText;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'avatarUrl': avatarUrl,
    'videosText': videosText,
    'subscribersText': subscribersText,
  };

  /// The list URL for this author's videos. Channels and users list on
  /// their profile page (?page=N works); models and pornstars need the
  /// /videos subpage — the profile page ignores ?page= (verified live
  /// 2026-11-24: /model/luxury-girl?page=2 repeats page 1, while
  /// /model/luxury-girl/videos?page=2 gives 36 fresh videos).
  String get videosUrl {
    if (path.startsWith('/model/') || path.startsWith('/pornstar/')) {
      return 'https://www.pornhub.com$path/videos';
    }
    return 'https://www.pornhub.com$path';
  }
}

/// Author-page sort modes (v0.2.10).
///
/// Server-side support (verified live 2026-11-24): /model and /pornstar
/// /videos pages honour ?o=mv (most viewed) and ?o=lg (longest); ?o=mr
/// 301-redirects to the default (most recent) order. /channels and
/// /users do NOT: ?o= on the profile page returns a list-less page and
/// /videos?o=... 404s — those sorts are applied client-side over the
/// loaded videos instead (views and duration are known per card).
enum AuthorOrdering { mostRecent, mostViewed, longest }

extension AuthorOrderingApi on AuthorOrdering {
  String get label {
    switch (this) {
      case AuthorOrdering.mostRecent:
        return '最新';
      case AuthorOrdering.mostViewed:
        return '最热';
      case AuthorOrdering.longest:
        return '最长';
    }
  }

  /// The site's `o=` value for the /videos subpage, or null when the
  /// sort IS the default order (most recent — no param needed).
  String? get siteValue {
    switch (this) {
      case AuthorOrdering.mostRecent:
        return null;
      case AuthorOrdering.mostViewed:
        return 'mv';
      case AuthorOrdering.longest:
        return 'lg';
    }
  }
}

/// Timeline (seek-preview) sprite sheets for one video (v0.2.10).
///
/// Parsed from the desktop detail page's flashvars `thumbs` object:
/// `samplingFrequency` seconds per thumbnail and `spritePatterns`, one
/// URL per sheet. Layout verified live 2026-11-24 on
/// ph5a7f1ba584481 (28:50, sampling 9, 8 sheets): each sheet is an
/// 800x450 image = 5 cols x 5 rows of 160x90 cells (25 thumbs per
/// sheet); thumb index = seconds ~/ sampling; sheet = index ~/ 25,
/// cell = index % 25. 1730s / 9 = 193 thumbs = 7.7 sheets, matching
/// the 8 patterns. The `S{7}` in `urlPattern` is the sheet index —
/// replacing S0 with S1/S7 in the first pattern yields the exact bytes
/// of patterns[1]/[7] — so [sheetUrl] can also generate sheets from
/// the pattern when the array is absent.
class TimelineSprites {
  const TimelineSprites({
    required this.samplingSeconds,
    required this.patterns,
    this.urlPattern = '',
  });

  factory TimelineSprites.fromJson(Map<String, dynamic> json) {
    final raw = json['patterns'];
    final patterns = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final s = item.toString();
        if (s.isNotEmpty) patterns.add(s);
      }
    }
    return TimelineSprites(
      samplingSeconds: json['samplingSeconds'] is num
          ? (json['samplingSeconds'] as num).toInt()
          : 9,
      patterns: patterns,
      urlPattern: (json['urlPattern'] ?? '').toString(),
    );
  }

  /// Seconds between thumbnails (the page's samplingFrequency).
  final int samplingSeconds;

  /// Sprite sheet URLs in order (one per [cellsPerSheet] thumbnails).
  final List<String> patterns;

  /// Raw `urlPattern` with an `S{7}` sheet-index placeholder, kept as
  /// a fallback when [patterns] is empty.
  final String urlPattern;

  static const cellWidth = 160;
  static const cellHeight = 90;
  static const cols = 5;
  static const rows = 5;
  static const cellsPerSheet = cols * rows;

  Map<String, dynamic> toJson() => {
    'samplingSeconds': samplingSeconds,
    'patterns': patterns,
    if (urlPattern.isNotEmpty) 'urlPattern': urlPattern,
  };

  /// URL of sprite sheet [sheet], or null when unknown. The patterns
  /// array is authoritative: beyond its length there is no sheet, so
  /// null is returned instead of a URL that would 404. The urlPattern
  /// fallback only applies when the array is empty.
  String? sheetUrl(int sheet) {
    if (sheet < 0) return null;
    if (sheet < patterns.length) return patterns[sheet];
    if (patterns.isEmpty && urlPattern.contains('{7}')) {
      return urlPattern.replaceAll('{7}', '$sheet');
    }
    return null;
  }

  /// Sheet + cell for [seconds] into the video, or null when the
  /// layout cannot serve that timestamp.
  ({int sheet, int col, int row})? cellFor(int seconds) {
    if (samplingSeconds <= 0 || seconds < 0) return null;
    final index = seconds ~/ samplingSeconds;
    final sheet = index ~/ cellsPerSheet;
    if (sheetUrl(sheet) == null) return null;
    final cell = index % cellsPerSheet;
    return (sheet: sheet, col: cell % cols, row: cell ~/ cols);
  }
}

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
    this.pornstars = const [],
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
      pornstars: strings(json['pornstars']),
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

  /// Performer names from the Webmasters API (`pornstars[].pornstar_name`).
  /// Only API-sourced items carry them; site-parsed lists leave this empty.
  final List<String> pornstars;

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
    'pornstars': pornstars,
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
    if (views >= 1000000) {
      return '${(views / 1000000).toStringAsFixed(1)}M views';
    }
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
    this.author,
    this.tags = const [],
    this.timelineSprites,
  });

  factory VideoDetail.fromJson(Map<String, dynamic> json) {
    final raw = json['sources'];
    final sources = <VideoSource>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          sources.add(VideoSource.fromJson(item));
        }
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
      author: json['author'] is Map<String, dynamic>
          ? AuthorInfo.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      // Cached tags are plain strings (toJson writes the list as-is).
      tags: json['tags'] is List
          ? (json['tags'] as List)
                .map((e) => e.toString())
                .where((s) => s.isNotEmpty)
                .toList()
          : const [],
      timelineSprites: json['timelineSprites'] is Map<String, dynamic>
          ? TimelineSprites.fromJson(
              json['timelineSprites'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  final String viewkey;
  final String title;
  final int duration;
  final String thumb;
  final List<VideoSource> sources;

  /// The video's author (v0.2.8), parsed from the detail page's about
  /// tab. Null when the detail came from the backend or an old cache
  /// entry, or when the page had no author block — the player hides the
  /// author row then instead of crashing.
  final AuthorInfo? author;

  /// The video's tags (v0.2.9), parsed from the detail page's
  /// tagsWrapper. Empty when the detail came from the backend or an old
  /// cache entry, or when the page had no tags block — the player then
  /// falls back to the list item's own tags (API-sourced videos).
  final List<String> tags;

  /// Seek-preview sprite sheets (v0.2.10), parsed from the detail
  /// page's flashvars `thumbs` object in the same fetch. Null when the
  /// detail came from the backend or an old cache entry, or when the
  /// page had no thumbs block — the player then shows only the
  /// timestamp while scrubbing, never a wrong frame.
  final TimelineSprites? timelineSprites;

  Map<String, dynamic> toJson() => {
    'viewkey': viewkey,
    'title': title,
    'duration': duration,
    'thumb': thumb,
    'sources': sources.map((s) => s.toJson()).toList(),
    if (author != null) 'author': author!.toJson(),
    if (tags.isNotEmpty) 'tags': tags,
    if (timelineSprites != null)
      'timelineSprites': timelineSprites!.toJson(),
  };

  /// HLS first, highest quality first — same order the backend returns.
  List<VideoSource> get hlsSources =>
      sources.where((s) => s.format == 'hls' && s.url.isNotEmpty).toList();

  VideoSource? get bestSource {
    final hls = hlsSources;
    if (hls.isEmpty) return sources.isEmpty ? null : sources.first;
    return hls.first;
  }

  /// Default start source (v0.2.2): the highest HLS quality that is
  /// still <= 720p — 720p when present (even if 1080p exists), else 480p,
  /// else 240p. All qualities from one detail-page fetch share the same
  /// CDN host (verified live 2026-11-22: all four qualities are either
  /// ev-h or hv-h together), so verifying this one URL validates the
  /// whole set and the user can still switch to 1080p manually.
  /// Falls back to the lowest available HLS quality when nothing is
  /// <= 720p.
  VideoSource? get startSource {
    final hls = hlsSources;
    if (hls.isEmpty) return bestSource;
    final upTo720 = hls.where((s) => s.height <= 720).toList();
    if (upTo720.isNotEmpty) {
      upTo720.sort((a, b) => b.height.compareTo(a.height));
      return upTo720.first;
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
/// The id is what the site's `/video?c=<id>` pages use.
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
