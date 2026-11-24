/// In-app Pornhub parser — Dart port of backend/ph_parse.py.
///
/// This is the fallback that lets the APK play with NO backend configured:
/// the phone parses Pornhub directly. When a backend URL is set in
/// Settings, the app prefers the backend (ph_api.dart) and only uses this
/// code if the backend fails.
///
/// Same verified behaviour as the Python version (2026-11-22, live):
/// - Webmasters search returns 30 videos/page JSON, no playable URL.
/// - Detail page flashvars.mediaDefinitions holds 240/480/720/1080 HLS
///   master.m3u8 URLs. Pornhub randomly serves two HLS URL schemes:
///   ev-h.phncdn.com (?validfrom&hash) works, hv-h.phncdn.com (?h= token)
///   returns 410 Gone under every header combination tried. So this
///   parser re-fetches until the start HLS URL verifies with a real
///   playlist GET (~235 bytes): v0.2.1 runs 2 parallel rounds of 5
///   fetches (ev-h share per fetch is only ~20-40% now, so 5 sequential
///   attempts failed ~17-33% of videos).
/// - Signed HLS URLs expire 2h after issue; never cache them across
///   launches. No login, no account, no download in this app.
///   (v0.2: PlaybackCache in play_cache.dart keeps them up to 110 minutes
///   — inside the 2h validity — so replays skip the network entirely.)
/// - Default start quality (v0.2.2): the highest HLS <= 720p (720p when
///   present even if 1080p exists, else 480p, else 240p); only that URL
///   is verified per attempt; see directVideoSources.
///
/// Pure Dart (dart:io / dart:convert only) so it can be tested with a
/// standalone Dart SDK: see README.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

const String _base = 'https://www.pornhub.com';
const String _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

class ParseException implements Exception {
  ParseException(this.message);
  final String message;
  @override
  String toString() => 'ParseException: $message';
}

/// The Webmasters API answered with an error object instead of a video
/// list, e.g. {"code":"2001","message":"No Videos found!"}.
///
/// This is a VALID API answer (the query itself is rejected), not a
/// malformed response — so it is a [ParseException] subtype callers can
/// catch separately and fall back to another source. It deliberately
/// keeps [ParseException]'s toString ("ParseException: ...") so existing
/// error displays do not change shape.
///
/// Seen live 2026-11-23: empty search + period=weekly answers 2001,
/// while the same call without period returns 30 videos.
class ApiNoVideosException extends ParseException {
  ApiNoVideosException(super.message);
}

Future<String> _getString(
  String url, {
  Map<String, String>? extraHeaders,
  String? userAgent,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent ?? _userAgent);
    request.headers.set(
      HttpHeaders.cookieHeader,
      'age_verified=1; accessAgeDisclaimerPH=1; '
      'accessAgeDisclaimerUK=1; accessPH=1',
    );
    extraHeaders?.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw ParseException('HTTP ${response.statusCode} from $url');
    }
    return body;
  } finally {
    client.close();
  }
}

/// Webmasters search. Empty [query] + ordering=mostviewed is the Home feed.
/// NOTE: do NOT pass period=weekly with an empty query — the API now
/// answers {"code":"2001","message":"No Videos found!"} for that
/// combination (verified live 2026-11-23). Home calls this with
/// period: '' (ordering=mostviewed alone returns 30 videos); search
/// calls keep the default period because a non-empty search term works.
Future<List<VideoItem>> directSearch(
  String query, {
  int page = 1,
  String ordering = 'mostviewed',
  String period = 'weekly',
}) async {
  final params = <String, String>{'page': '$page'};
  if (query.isNotEmpty) params['search'] = query;
  if (ordering.isNotEmpty) params['ordering'] = ordering;
  if (period.isNotEmpty) params['period'] = period;
  final url = '$_base/webmasters/search?${Uri(queryParameters: params).query}';
  final body = await _getString(url);
  final data = jsonDecode(body);
  if (data is! Map || data['videos'] is! List) {
    if (data is Map) {
      final code = data['code']?.toString() ?? '';
      final message = data['message']?.toString() ?? '';
      if (code.isNotEmpty || message.isNotEmpty) {
        throw ApiNoVideosException(
          message.isNotEmpty ? message : 'No videos found (code $code)',
        );
      }
    }
    throw ParseException('unexpected Webmasters search shape');
  }
  return (data['videos'] as List)
      .whereType<Map<String, dynamic>>()
      .map(VideoItem.fromJson)
      .toList();
}

/// Webmasters detail for one video: metadata only, no playable URL.
/// Used to refresh a stored thumbnail whose signed URL expired (24h):
/// the returned thumb is freshly signed. Throws [ParseException] when
/// the video is missing.
Future<String> directVideoThumb(String viewkey) async {
  final url =
      '$_base/webmasters/video_by_id?id=${Uri.encodeComponent(viewkey)}';
  final body = await _getString(url);
  final data = jsonDecode(body);
  if (data is! Map || data['video'] is! Map<String, dynamic>) {
    throw ParseException('no video in video_by_id for $viewkey');
  }
  final video = VideoItem.fromJson(data['video'] as Map<String, dynamic>);
  return video.thumb;
}

/// Extract the `var flashvars_<n> = {...};` object with a balanced-brace
/// scan (regex alone breaks on nested objects).
Map<String, dynamic> extractFlashvars(String html) {
  final marker = html.indexOf('var flashvars_');
  if (marker < 0) throw ParseException('flashvars block not found');
  var start = html.indexOf('{', marker);
  if (start < 0) throw ParseException('flashvars object not found');
  var depth = 0;
  var inString = false;
  var escaped = false;
  var i = start;
  while (i < html.length) {
    final ch = html[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
    } else {
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) break;
      }
    }
    i++;
  }
  if (depth != 0) throw ParseException('unterminated flashvars object');
  final parsed = jsonDecode(html.substring(start, i + 1));
  if (parsed is! Map<String, dynamic>) {
    throw ParseException('flashvars is not an object');
  }
  return parsed;
}

Future<bool> _verifyHls(String url, String viewkey) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(
      HttpHeaders.refererHeader,
      '$_base/view_video.php?viewkey=$viewkey',
    );
    request.headers.set('Origin', _base);
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) return false;
    final head = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    return head.contains('#EXTM3U');
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// The video's seek-preview sprites (v0.2.10), from the flashvars
/// `thumbs` object of the same detail fetch that gets playback URLs —
/// no extra request.
///
/// Layout verified live 2026-11-24 on ph5a7f1ba584481 (28:50):
/// `samplingFrequency` 9, 8 `spritePatterns` URLs, each sheet 800x450
/// = 5x5 cells of 160x90 (checked by downloading a sheet and reading
/// its pixels; cells are distinct frames). 1730s / 9 = 193 thumbs =
/// 7.7 sheets, matching the 8 patterns. Returns null when the page
/// has no usable thumbs block; the player then shows only the
/// timestamp while scrubbing.
TimelineSprites? extractTimelineSprites(Map<String, dynamic> flashvars) {
  final thumbs = flashvars['thumbs'];
  if (thumbs is! Map<String, dynamic>) return null;
  final patterns = <String>[];
  final raw = thumbs['spritePatterns'];
  if (raw is List) {
    for (final item in raw) {
      final url = _unescapeHtml(item.toString());
      if (url.isNotEmpty) patterns.add(url);
    }
  }
  final urlPattern = _unescapeHtml((thumbs['urlPattern'] ?? '').toString());
  final sampling = thumbs['samplingFrequency'] is num
      ? (thumbs['samplingFrequency'] as num).toInt()
      : 9;
  if (patterns.isEmpty && !urlPattern.contains('{7}')) return null;
  if (sampling <= 0) return null;
  return TimelineSprites(
    samplingSeconds: sampling,
    patterns: patterns,
    urlPattern: urlPattern,
  );
}

List<VideoSource> _sourcesFromFlashvars(Map<String, dynamic> flashvars) {
  final defs = flashvars['mediaDefinitions'];
  if (defs is! List || defs.isEmpty) {
    throw ParseException('mediaDefinitions empty — page layout changed?');
  }
  final sources = <VideoSource>[];
  for (final item in defs) {
    if (item is! Map<String, dynamic>) continue;
    final videoUrl = (item['videoUrl'] ?? '').toString();
    if (videoUrl.isEmpty) continue;
    sources.add(
      VideoSource(
        quality: (item['quality'] ?? '').toString(),
        format: (item['format'] ?? '').toString(),
        url: videoUrl,
        width: item['width'] is num ? (item['width'] as num).toInt() : 0,
        height: item['height'] is num ? (item['height'] as num).toInt() : 0,
        isDefault: item['defaultQuality'] == true,
      ),
    );
  }
  sources.sort((a, b) {
    final formatOrder =
        (a.format == 'hls' ? 0 : 1) - (b.format == 'hls' ? 0 : 1);
    if (formatOrder != 0) return formatOrder;
    return b.height - a.height;
  });
  return sources;
}

/// Fetch detail page and return playable sources, retrying until the
/// *start* HLS URL verifies (see file header for the ev-h / hv-h finding).
/// v0.2.2: only the start candidate (highest HLS <= 720p, usually 720p)
/// is verified, not the 1080p top URL — the player starts at 720p by
/// default and the user can switch to 1080p afterwards. All qualities
/// from one fetch share the same CDN host (verified live 2026-11-22),
/// so verifying the start URL validates the whole set.
///
/// v0.2.1: attempts run in PARALLEL rounds. The ev-h share per fetch has
/// dropped to roughly 20-40% (it was ~50% when v0.1 was measured), so 5
/// sequential attempts fail ~17-33% of videos — and each costs a ~1.6 MB
/// detail fetch (~1.8s) plus delays. Two rounds of 5 concurrent fetches
/// (10 attempts total) cut the failure rate to ~3-11% and a round takes
/// ~2s instead of ~9s sequential. The ev-h-only rule is unchanged:
/// hv-h URLs are never returned.
/// Throws [ParseException] if no verifiable URL appears.
Future<VideoDetail> directVideoSources(
  String viewkey, {
  int maxAttempts = 10,
}) async {
  const perRound = 5;
  final rounds = (maxAttempts / perRound).ceil();
  for (var round = 0; round < rounds; round++) {
    final results = await Future.wait(
      List.generate(perRound, (_) => _tryOneFetch(viewkey)),
    );
    for (final detail in results) {
      if (detail != null) return detail;
    }
  }
  throw ParseException(
    'no verifiable HLS URL after $maxAttempts attempts '
    '(ev-h share is only ~20-40% per fetch)',
  );
}

/// One fetch-and-verify attempt. Never throws: null means "try again".
Future<VideoDetail?> _tryOneFetch(String viewkey) async {
  try {
    final html = await _getString(
      '$_base/view_video.php?viewkey=${Uri.encodeComponent(viewkey)}',
    );
    final flashvars = extractFlashvars(html);
    final sources = _sourcesFromFlashvars(flashvars);
    final detail = VideoDetail(
      viewkey: viewkey,
      title: (flashvars['video_title'] ?? '').toString(),
      duration: flashvars['video_duration'] is num
          ? (flashvars['video_duration'] as num).toInt()
          : 0,
      thumb: (flashvars['image_url'] ?? '').toString(),
      sources: sources,
      // Same fetch, no extra request: the author comes from the about
      // tab of this very page (see extractAuthor), the tags from
      // its tagsWrapper (see extractTags), and the seek-preview
      // sprites from flashvars.thumbs (see extractTimelineSprites).
      author: extractAuthor(html),
      tags: extractTags(html),
      timelineSprites: extractTimelineSprites(flashvars),
    );
    final start = detail.startSource;
    if (start != null && await _verifyHls(start.url, viewkey)) {
      return detail;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Mobile-site preview clip URLs (v0.2.2).
///
/// The mobile site auto-plays a small muted preview when a video card
/// scrolls into view — no tap, no long-press. Each card's `<a>` carries
/// the clip in a `data-webm="https://.../360P_360K_<id>_fb.mp4?..."`.
/// attribute (360p, low bitrate, signed). The Webmasters JSON API does
/// NOT return this URL, so the app fetches the matching mobile list page
/// and extracts the viewkey -> clip map.
///
/// Verified live 2026-11-22 (sandbox, mobile UA on www.pornhub.com):
/// - Mobile search page: 30/30 video cards carry data-webm + viewkey in
///   the same `<a>`; mobile home (?o=mv&t=w): 41 hits; mobile category
///   page: 69 hits. Desktop pages do NOT carry it (0 _fb.mp4), so the
///   fetch must use a mobile UA.
/// - The clip GETs 200 video/mp4 (~512 KB, ftypisom) with or without
///   Referer. Signatures last 1-2h (hdnea exp = 1h, validfrom/validto
///   = 2h), so the caller caches the map well inside that window.
const String _mobileUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

/// Mobile list-page URL matching a list the app shows: search, category,
/// or the home feed (most-viewed, weekly — same as the Webmasters home).
/// [ordering] is the site's own sort value for search (`o=` param:
/// mv/tr/mr/lg — see directSiteSearch); null means the site default.
String mobileListUrl({
  String? query,
  int? categoryId,
  int page = 1,
  String? ordering,
}) {
  if (query != null && query.isNotEmpty) {
    var url = '$_base/video/search?search=${Uri.encodeQueryComponent(query)}'
        '&page=$page';
    if (ordering != null && ordering.isNotEmpty) url += '&o=$ordering';
    return url;
  }
  if (categoryId != null) {
    return '$_base/video?c=$categoryId&page=$page';
  }
  return '$_base/video?o=mv&t=w&page=$page';
}

/// Fetch a mobile list page and return viewkey -> preview mp4 URL.
///
/// The map is keyed twice per video: by the hex viewkey from the card's
/// href AND by the numeric video id (the `data-video-id` attribute and
/// the id inside the mp4 path), because API lists key videos by the
/// numeric id while site lists use the hex viewkey. Returns an empty map
/// (never throws) when the page layout changes or the fetch fails —
/// previews are a bonus, the list still works without them.
Future<Map<String, String>> directPreviewUrls({
  String? query,
  int? categoryId,
  int page = 1,
  String? ordering,
}) async {
  // One retry: the site intermittently answers the first request with a
  // 302/empty body (seen live in the sandbox 2026-11-22) and the retry
  // succeeds, so a single failed fetch must not mean "no previews".
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final html = await _getString(
        mobileListUrl(
          query: query,
          categoryId: categoryId,
          page: page,
          ordering: ordering,
        ),
        userAgent: _mobileUserAgent,
        extraHeaders: {HttpHeaders.refererHeader: '$_base/'},
      );
      final found = <String, String>{};
      final anchorRe = RegExp(r'<a[^>]*>', dotAll: true);
      final webmRe = RegExp(r'data-webm="([^"]+)"');
      final viewkeyRe = RegExp(r'viewkey=([0-9a-z]+)');
      final videoIdRe = RegExp(r'data-video-id="(\d+)"');
      final mp4IdRe = RegExp(r'/(\d+)/360P_360K_\d+_fb\.mp4');
      for (final match in anchorRe.allMatches(html)) {
        final tag = match.group(0)!;
        final webm = webmRe.firstMatch(tag)?.group(1);
        if (webm == null || !webm.contains('_fb.mp4')) continue;
        final url = webm
            .replaceAll('&amp;', '&')
            .replaceAll('&#039;', "'")
            .replaceAll('&quot;', '"');
        final viewkey = viewkeyRe.firstMatch(tag)?.group(1);
        if (viewkey != null && viewkey.isNotEmpty) {
          found[viewkey] = url;
        }
        final numericId =
            videoIdRe.firstMatch(tag)?.group(1) ??
            mp4IdRe.firstMatch(url)?.group(1);
        if (numericId != null && numericId.isNotEmpty) {
          found[numericId] = url;
        }
      }
      return found;
    } catch (_) {
      if (attempt == 1) return {};
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }
  return {};
}

/// One parsed mobile search page (v0.2.4): the videos in site order plus
/// the per-card preview clip URLs from the same fetch, so search results
/// and previews come from one request instead of two.
class SiteSearchPage {
  const SiteSearchPage({required this.videos, required this.previews});
  final List<VideoItem> videos;
  final Map<String, String> previews;
}

String _unescapeHtml(String s) {
  return s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#39;', "'");
}

/// "121K" -> 121000, "2.2M" -> 2200000, "1,234" -> 1234.
int _parseSiteViews(String raw) {
  final s = raw.trim().replaceAll(',', '');
  if (s.isEmpty) return 0;
  final m = RegExp(r'^([\d.]+)\s*([KM])?$').firstMatch(s);
  if (m == null) return int.tryParse(s) ?? 0;
  final value = double.tryParse(m.group(1)!) ?? 0;
  final suffix = m.group(2);
  if (suffix == 'M') return (value * 1000000).round();
  if (suffix == 'K') return (value * 1000).round();
  return value.round();
}

/// Extract a <ul>...</ul> section with a balanced scan: cards contain
/// nested <ul> menus, so the first </ul> after the opening tag is NOT
/// the end of the list.
String _balancedUlSection(String html, RegExp openRe, String notFound) {
  final open = openRe.firstMatch(html);
  if (open == null) {
    throw ParseException(notFound);
  }
  var depth = 0;
  final tagRe = RegExp(r'</?ul\b[^>]*>');
  for (final m in tagRe.allMatches(html, open.start)) {
    if (m.group(0)!.startsWith('</')) {
      depth--;
    } else {
      depth++;
    }
    if (depth == 0) return html.substring(open.start, m.end);
  }
  throw ParseException('$notFound (not closed)');
}

/// Extract the <ul id="videoListSearchResults"> ... </ul> section.
String _searchResultsSection(String html) => _balancedUlSection(
  html,
  RegExp(r'<ul[^>]*id="videoListSearchResults"[^>]*>'),
  'videoListSearchResults not found',
);

/// Parse the main result list out of a mobile search page. Returns the
/// videos in site order. Only <li class="videoSearchList_*"> cards are
/// taken — the same <ul> also carries shorties and ad slots, which are
/// not results. Throws [ParseException] when the page layout is not
/// recognised or no video cards are found.
SiteSearchPage parseSiteSearch(String html) {
  final section = _searchResultsSection(html);
  final itemRe = RegExp(
    r'<li\b[^>]*class="[^"]*videoSearchList[^"]*"[^>]*>.*?</li>',
    dotAll: true,
  );
  final videos = <VideoItem>[];
  final previews = <String, String>{};
  for (final match in itemRe.allMatches(section)) {
    final block = match.group(0)!;
    // NOTE: the viewkey is [0-9a-z]+, not [0-9a-f]+ — many cards carry
    // a "ph..."-prefixed viewkey (verified live), which a hex-only
    // pattern silently drops (that bug cost o=mv 20 of 28 cards in an
    // early probe). The detail page accepts ph viewkeys (200 +
    // mediaDefinitions, verified live).
    final vkey =
        RegExp(r'data-video-vkey="([0-9a-z]+)"').firstMatch(block)?.group(1);
    if (vkey == null || vkey.isEmpty) continue;
    var title =
        RegExp(r'alt="([^"]+)"').firstMatch(block)?.group(1) ?? '';
    if (title.isEmpty) {
      final titleMatch = RegExp(
        r'<a class="thumbnailTitle"[^>]*>(.*?)</a>',
        dotAll: true,
      ).firstMatch(block);
      title = titleMatch == null
          ? ''
          : titleMatch
                .group(1)!
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim();
    }
    title = _unescapeHtml(title).trim();
    if (title.isEmpty) continue;
    var thumb =
        RegExp(r'src="(https://[^"]*phncdn[^"]*)"').firstMatch(block)?.group(1) ??
        RegExp(r'data-poster="(https://[^"]*phncdn[^"]*)"')
            .firstMatch(block)
            ?.group(1) ??
        '';
    thumb = _unescapeHtml(thumb);
    final duration =
        RegExp(r'class="bgEffect time">([^<]+)<')
            .firstMatch(block)
            ?.group(1)
            ?.trim() ??
        '';
    final viewsMatch = RegExp(
      r'class="videoViews">.*?([\d.,]+)\s*([KM])?<',
      dotAll: true,
    ).firstMatch(block);
    final views = viewsMatch == null
        ? 0
        : _parseSiteViews(
            '${viewsMatch.group(1) ?? ''}${viewsMatch.group(2) ?? ''}',
          );
    final webm = RegExp(r'data-webm="([^"]+)"').firstMatch(block)?.group(1);
    videos.add(
      VideoItem(
        viewkey: vkey,
        title: title,
        duration: duration,
        views: views,
        // Cards carry no rating on the site; sorting is server-side
        // via o=, so no client-side sort is needed for these items.
        rating: 0,
        thumb: thumb,
        url: '$_base/view_video.php?viewkey=$vkey',
      ),
    );
    if (webm != null && webm.contains('_fb.mp4')) {
      previews[vkey] = _unescapeHtml(webm);
    }
  }
  if (videos.isEmpty) {
    throw ParseException('no videos parsed from site search');
  }
  return SiteSearchPage(videos: videos, previews: previews);
}

/// Search via the mobile website's own search page (v0.2.4).
///
/// The Webmasters API and the site return DIFFERENT video sets for the
/// same query (verified live: overlap 0/30), so API search can never
/// find some videos the site shows. The site page is the source of
/// truth for what the user sees on the mobile site: same videos, same
/// order. Sort modes are the site's own `o=` params (verified live
/// 2026-11-22 — default/o=mv/o=tr/o=mr/o=lg each give a different
/// order of 28 cards; o=lg durations strictly descending):
///   most viewed -> mv, top rated -> tr, most recent -> mr,
///   longest -> lg.
/// Throws [ParseException] when the fetch fails or no cards are found,
/// so the caller can fall back to the Webmasters API search.
Future<SiteSearchPage> directSiteSearch(
  String query, {
  int page = 1,
  String ordering = 'mv',
}) async {
  final params = <String, String>{'search': query, 'page': '$page'};
  if (ordering.isNotEmpty) params['o'] = ordering;
  final url = '$_base/video/search?${Uri(queryParameters: params).query}';
  // One retry: the site intermittently answers the first request with a
  // 302/empty body (seen live with the preview fetch), so a single
  // failed fetch must not mean "no results".
  ParseException? lastError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final html = await _getString(
        url,
        userAgent: _mobileUserAgent,
        extraHeaders: {HttpHeaders.refererHeader: '$_base/'},
      );
      return parseSiteSearch(html);
    } on ParseException catch (e) {
      lastError = e;
      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }
  throw lastError ?? ParseException('site search failed');
}

/// Parse the main video list out of a mobile home page
/// (`/video?o=mv&t=w`). The main list is the
/// `<ul class="videoList clearfix browseVideo-tabSplit">` — the other
/// videoList sections on the page (filter dropdowns, the scrollable
/// strip) are NOT the feed. Returns the videos in site order plus the
/// per-card preview clip URLs from the same fetch. Throws
/// [ParseException] when the page layout is not recognised or no video
/// cards are found.
///
/// Verified live 2026-11-23 (sandbox, mobile UA): page 1 = 31 cards,
/// page 2 = 43 cards, 0 overlap; every card carries data-video-vkey,
/// img alt title, data-poster thumb, <span class="time"> duration,
/// <div class="views"> views, and a data-webm preview clip.
SiteSearchPage parseSiteHome(String html) {
  final section = _balancedUlSection(
    html,
    RegExp(r'<ul[^>]*class="[^"]*browseVideo-tabSplit[^"]*"[^>]*>'),
    'home video list not found',
  );
  final itemRe = RegExp(
    r'<li\b[^>]*data-video-vkey="([0-9a-z]+)"[^>]*>.*?</li>',
    dotAll: true,
  );
  final videos = <VideoItem>[];
  final previews = <String, String>{};
  for (final match in itemRe.allMatches(section)) {
    final block = match.group(0)!;
    final vkey = match.group(1)!;
    var title =
        RegExp(r'alt="([^"]+)"').firstMatch(block)?.group(1) ?? '';
    if (title.isEmpty) {
      final titleMatch = RegExp(
        r'<div class="title">\s*<a[^>]*>(.*?)</a>',
        dotAll: true,
      ).firstMatch(block);
      title = titleMatch == null
          ? ''
          : titleMatch
                .group(1)!
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim();
    }
    title = _unescapeHtml(title).trim();
    if (title.isEmpty) continue;
    var thumb =
        RegExp(r'data-poster="(https://[^"]*phncdn[^"]*)"')
                .firstMatch(block)
                ?.group(1) ??
            RegExp(r'src="(https://[^"]*phncdn[^"]*)"')
                .firstMatch(block)
                ?.group(1) ??
        '';
    thumb = _unescapeHtml(thumb);
    final duration =
        RegExp(r'<span class="time">([^<]+)</span>')
            .firstMatch(block)
            ?.group(1)
            ?.trim() ??
        '';
    final viewsMatch = RegExp(
      r'<div class="views">\s*([\d.,]+)\s*([KM])?',
    ).firstMatch(block);
    final views = viewsMatch == null
        ? 0
        : _parseSiteViews(
            '${viewsMatch.group(1) ?? ''}${viewsMatch.group(2) ?? ''}',
          );
    final webm = RegExp(r'data-webm="([^"]+)"').firstMatch(block)?.group(1);
    videos.add(
      VideoItem(
        viewkey: vkey,
        title: title,
        duration: duration,
        views: views,
        // Cards carry no rating on the site; the home feed is
        // server-ordered (most viewed, weekly).
        rating: 0,
        thumb: thumb,
        url: '$_base/view_video.php?viewkey=$vkey',
      ),
    );
    if (webm != null && webm.contains('_fb.mp4')) {
      previews[vkey] = _unescapeHtml(webm);
    }
  }
  if (videos.isEmpty) {
    throw ParseException('no videos parsed from site home');
  }
  return SiteSearchPage(videos: videos, previews: previews);
}

/// Home feed via the mobile website's own home page (v0.2.7 fallback).
///
/// The Webmasters home call (empty search + period=weekly) now answers
/// {"code":"2001","message":"No Videos found!"} (verified live
/// 2026-11-23), so Home falls back here when the API fails or answers
/// 2001. Same videos and order as the mobile site's home feed.
/// Throws [ParseException] when the fetch fails or no cards are found,
/// so the caller can show its own friendly error.
Future<SiteSearchPage> directSiteHome({int page = 1}) async {
  ParseException? lastError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final html = await _getString(
        mobileListUrl(page: page),
        userAgent: _mobileUserAgent,
        extraHeaders: {HttpHeaders.refererHeader: '$_base/'},
      );
      return parseSiteHome(html);
    } on ParseException catch (e) {
      lastError = e;
      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }
  throw lastError ?? ParseException('site home failed');
}

/// Balanced-<ul> extraction that returns null instead of throwing,
/// for trying several candidate sections in priority order.
String? _balancedUlSectionOrNull(String html, RegExp openRe) {
  final open = openRe.firstMatch(html);
  if (open == null) return null;
  var depth = 0;
  final tagRe = RegExp(r'</?ul\b[^>]*>');
  for (final m in tagRe.allMatches(html, open.start)) {
    if (m.group(0)!.startsWith('</')) {
      depth--;
    } else {
      depth++;
    }
    if (depth == 0) return html.substring(open.start, m.end);
  }
  return null;
}

/// Parse the main video list out of a mobile author page (v0.2.8): a
/// channel / model / user profile, or a pornstar's /videos page.
/// Section priority (verified live 2026-11-24):
///   1. `<ul id="mostRecentSection">` (channels, 35 cards)
///   2. `<ul id="mostRecentVideosSection">` (pornstars, 36 cards)
///   3. `<ul id="uploadedVideosSection">` (pornstars, fallback, 5 cards)
///   4. the first <ul class="... videoList ..."> that is not the
///      shorties strip (models' /videos page, users, generic fallback).
/// Cards carry the same fields as mobile search cards, except the
/// duration/views markup differs by page type — channel cards use
/// `<span class="time">` + `<div class="views">` (home style),
/// model/pornstar cards use `<span class="bgEffect time">` +
/// `<div class="videoViews">` (search style) — so both forms are tried.
/// Throws [ParseException] when no list section or no cards are found.
SiteSearchPage parseAuthorList(String html) {
  final candidates = <String>[];
  for (final pattern in <RegExp>[
    RegExp(r'<ul[^>]*id="mostRecentSection"[^>]*>'),
    RegExp(r'<ul[^>]*id="mostRecentVideosSection"[^>]*>'),
    RegExp(r'<ul[^>]*id="uploadedVideosSection"[^>]*>'),
  ]) {
    final section = _balancedUlSectionOrNull(html, pattern);
    if (section != null) candidates.add(section);
  }
  if (candidates.isEmpty) {
    // Generic fallback: first videoList <ul> that is not the shorties
    // strip (modelShorties__recent__videos).
    final ulRe = RegExp(r'<ul[^>]*class="[^"]*videoList[^"]*"[^>]*>');
    for (final m in ulRe.allMatches(html)) {
      if (m.group(0)!.contains('modelShorties')) continue;
      final section = _balancedUlSectionOrNull(
        html,
        RegExp(RegExp.escape(m.group(0)!)),
      );
      if (section != null) candidates.add(section);
      break;
    }
  }
  for (final section in candidates) {
    final page = _parseAuthorCards(section);
    if (page.videos.isNotEmpty) return page;
  }
  throw ParseException('author video list not found');
}

/// One author-list section's cards, in page order. Same fields as
/// mobile search cards (see parseSiteSearch), with both duration/views
/// markup variants accepted.
SiteSearchPage _parseAuthorCards(String section) {
  final itemRe = RegExp(
    r'<li\b[^>]*data-video-vkey="([0-9a-z]+)"[^>]*>.*?</li>',
    dotAll: true,
  );
  final videos = <VideoItem>[];
  final previews = <String, String>{};
  for (final match in itemRe.allMatches(section)) {
    final block = match.group(0)!;
    final vkey = match.group(1)!;
    var title =
        RegExp(r'alt="([^"]+)"').firstMatch(block)?.group(1) ?? '';
    if (title.isEmpty) {
      final titleMatch = RegExp(
        r'<div class="title">\s*<a[^>]*>(.*?)</a>',
        dotAll: true,
      ).firstMatch(block);
      title = titleMatch == null
          ? ''
          : titleMatch
                .group(1)!
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim();
    }
    title = _unescapeHtml(title).trim();
    if (title.isEmpty) continue;
    var thumb =
        RegExp(r'data-poster="(https://[^"]*phncdn[^"]*)"')
                .firstMatch(block)
                ?.group(1) ??
            RegExp(r'src="(https://[^"]*phncdn[^"]*)"')
                .firstMatch(block)
                ?.group(1) ??
        '';
    thumb = _unescapeHtml(thumb);
    final duration =
        RegExp(r'class="bgEffect time">([^<]+)<')
                .firstMatch(block)
                ?.group(1)
                ?.trim() ??
            RegExp(r'<span class="time">([^<]+)</span>')
                .firstMatch(block)
                ?.group(1)
                ?.trim() ??
        '';
    var views = 0;
    final viewsMatch =
        RegExp(
          r'class="videoViews">.*?([\d.,]+)\s*([KM])?<',
          dotAll: true,
        ).firstMatch(block) ??
        RegExp(
          r'<div class="views">\s*([\d.,]+)\s*([KM])?',
        ).firstMatch(block);
    if (viewsMatch != null) {
      views = _parseSiteViews(
        '${viewsMatch.group(1) ?? ''}${viewsMatch.group(2) ?? ''}',
      );
    }
    final webm = RegExp(r'data-webm="([^"]+)"').firstMatch(block)?.group(1);
    videos.add(
      VideoItem(
        viewkey: vkey,
        title: title,
        duration: duration,
        views: views,
        rating: 0,
        thumb: thumb,
        url: '$_base/view_video.php?viewkey=$vkey',
      ),
    );
    if (webm != null && webm.contains('_fb.mp4')) {
      previews[vkey] = _unescapeHtml(webm);
    }
  }
  return SiteSearchPage(videos: videos, previews: previews);
}

/// One author's videos via their mobile profile page (v0.2.8).
///
/// URL rules (verified live 2026-11-24): `/channels/<slug>` and
/// `/users/<slug>` list on the profile page itself (?page=N works, 0
/// overlap p1/p2); `/model/<slug>` and `/pornstar/<slug>` need the /videos
/// subpage (the profile page ignores ?page=, /videos paginates 36
/// fresh videos per page). See [AuthorInfo.videosUrl].
///
/// Sorting (v0.2.10, verified live 2026-11-24): /model and /pornstar
/// /videos pages honour ?o=mv (most viewed) and ?o=lg (longest)
/// server-side — pornstar p1/p2 with ?o=mv give 41 videos each, 0
/// overlap — while ?o=mr 301-redirects to the default (most recent)
/// order. /channels and /users do NOT sort server-side: ?o= on the
/// profile page returns a list-less page (4 links, shorties only) and
/// /videos?o=... 404s — so [ordering] is ignored here for those
/// paths and the author page sorts client-side instead.
/// Throws [ParseException] when the fetch fails or no cards are found.
Future<SiteSearchPage> directAuthorVideos(
  String authorPath, {
  int page = 1,
  AuthorOrdering ordering = AuthorOrdering.mostRecent,
}) async {
  final base = AuthorInfo(name: '', path: authorPath).videosUrl;
  final isVideosPage =
      authorPath.startsWith('/model/') ||
      authorPath.startsWith('/pornstar/');
  final sort = isVideosPage ? ordering.siteValue : null;
  final url = '$base?page=$page${sort != null ? '&o=$sort' : ''}';
  ParseException? lastError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final html = await _getString(
        url,
        userAgent: _mobileUserAgent,
        extraHeaders: {HttpHeaders.refererHeader: '$_base/'},
      );
      return parseAuthorList(html);
    } on ParseException catch (e) {
      lastError = e;
      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }
  throw lastError ?? ParseException('author videos failed');
}

/// The current video's author, from the desktop detail page's "about"
/// tab (v0.2.8).
///
/// Anchor: the single `video-detailed-info` block (exactly one per
/// page, verified live on 8 videos) -> `usernameWrap clearfix` -> the
/// first `<a href="/channels|/model|/users|/pornstar/...">`. The avatar
/// comes from the `userAvatar` img in the same block, and the "357
/// Videos" / "2.1M Subscribers" spans right after the usernameWrap.
///
/// Do NOT anchor on `.videoUploaderBlock`: the page carries ~77 of
/// those and they all belong to related video cards — the first one is
/// a related video's uploader, not this video's. Returns null when the
/// page has no author block; the caller hides the author row then.
AuthorInfo? extractAuthor(String html) {
  final infoAt = html.indexOf('video-detailed-info');
  if (infoAt < 0) return null;
  // Bound the scan: the whole about-tab user block is ~2 KB.
  final end = (infoAt + 8000).clamp(0, html.length);
  final window = html.substring(infoAt, end);
  final wrap = RegExp(
    r'<div class="usernameWrap clearfix"[^>]*>(.*?)</div>',
    dotAll: true,
  ).firstMatch(window);
  if (wrap == null) return null;
  final link = RegExp(
    r'<a [^>]*href="(/[^"]+)"[^>]*>(.*?)</a>',
    dotAll: true,
  ).firstMatch(wrap.group(1)!);
  if (link == null) return null;
  final path = link.group(1)!;
  if (!path.startsWith('/channels/') &&
      !path.startsWith('/model/') &&
      !path.startsWith('/users/') &&
      !path.startsWith('/pornstar/')) {
    return null;
  }
  final name = _unescapeHtml(
    link.group(2)!.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
  );
  if (name.isEmpty) return null;
  var avatarUrl = '';
  final avatar = RegExp(
    r'<div class="userAvatar">.*?<img[^>]*src="([^"]+)"',
    dotAll: true,
  ).firstMatch(window);
  if (avatar != null) avatarUrl = _unescapeHtml(avatar.group(1)!);
  final tail = window.substring(wrap.end);
  final videos = RegExp(
    r'<span>([\d.,]+\s*[KM]?)\s*Videos</span>',
  ).firstMatch(tail)?.group(1)?.trim();
  final subs = RegExp(
    r'<span>([\d.,]+\s*[KM]?)\s*Subscribers</span>',
  ).firstMatch(tail)?.group(1)?.trim();
  return AuthorInfo(
    name: name,
    path: path,
    avatarUrl: avatarUrl,
    videosText: videos == null ? '' : '$videos Videos',
    subscribersText: subs == null ? '' : '$subs Subscribers',
  );
}

/// The video's tags (v0.2.9), from the detail page's `tagsWrapper`:
/// `<a ... class="... item isTag" href="/video/search?search=...">`
/// `<span>NAME</span></a>` — the same links the site itself uses for
/// tag browsing (clicking a tag goes to /video/search?search=TAG).
/// Returns [] when the page has no tags block; the caller falls back to
/// the list item's own tags then. Verified live 2026-11-24 on
/// ph5a7f1ba584481: 13 tags, matching the Webmasters API tags for the
/// same video.
List<String> extractTags(String html) {
  final start = html.indexOf('tagsWrapper');
  if (start < 0) return [];
  // The wrapper holds only <p>Tags</p> plus the tag <a>s — no nested
  // divs — so the first </div> after it closes the block.
  final end = html.indexOf('</div>', start);
  final window = end < 0
      ? html.substring(start, (start + 10000).clamp(0, html.length))
      : html.substring(start, end);
  final seen = <String>{};
  final tags = <String>[];
  for (final match in RegExp(
    r'<a[^>]*\bisTag\b[^>]*>\s*<span>([^<]+)</span>',
    dotAll: true,
  ).allMatches(window)) {
    final name = _unescapeHtml(match.group(1)!.trim());
    if (name.isNotEmpty && seen.add(name)) tags.add(name);
    if (tags.length >= 15) break;
  }
  return tags;
}

/// "Alex Adams" -> "alex-adams", "Savannah Stéele" ->
/// "savannah-st%C3%A9ele" (the site percent-encodes non-ASCII in
/// pornstar slugs). Used for the pornstar chips on the player page.
String pornstarSlug(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll("'", '')
      .replaceAll(RegExp(r'\s+'), '-');
  return Uri.encodeComponent(slug);
}

/// Per-video preview clip for the exact videos the app shows (v0.2.3).
///
/// Root cause of "previews never play" (verified live 2026-11-22):
/// the Webmasters API list and the mobile site list are DIFFERENT video
/// sets — API home vs mobile ?o=mv&t=w overlapped 0/30, API search vs
/// mobile search 0/30, mobile home pages 2+3 added only 3/30 more. So
/// the bulk map from directPreviewUrls() never contains the displayed
/// videos' viewkeys and no card ever becomes preview-active. (Category
/// lists do overlap — 31/38 — because both sides parse the site, so
/// the bulk map still helps there.) The mobile detail page is no help
/// either: it renders a generic page without the requested video.
/// The only source that always has the video's own playable URL is its
/// detail page (flashvars.mediaDefinitions), so the fallback resolves
/// the preview from there: up to 5 parallel detail fetches (one round,
/// same as playback), first verified fetch wins, and the LOWEST (240p)
/// HLS URL is returned as the muted preview clip. A failed resolve
/// returns '' and the card silently stays on its cover.
Future<String> directPreviewHls(String viewkey, {int maxAttempts = 5}) async {
  final results = await Future.wait(
    List.generate(maxAttempts, (_) => _tryOneFetch(viewkey)),
  );
  for (final detail in results) {
    if (detail == null) continue;
    // All qualities from one fetch share the same CDN host, and
    // _tryOneFetch already verified this fetch's start URL — so the
    // 240p URL from the same fetch is playable too.
    final hls = detail.hlsSources.toList()
      ..sort((a, b) => a.height.compareTo(b.height));
    if (hls.isNotEmpty) return hls.first.url;
  }
  return '';
}
