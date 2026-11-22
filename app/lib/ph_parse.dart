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
String mobileListUrl({String? query, int? categoryId, int page = 1}) {
  if (query != null && query.isNotEmpty) {
    return '$_base/video/search?search=${Uri.encodeQueryComponent(query)}'
        '&page=$page';
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
}) async {
  // One retry: the site intermittently answers the first request with a
  // 302/empty body (seen live in the sandbox 2026-11-22) and the retry
  // succeeds, so a single failed fetch must not mean "no previews".
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final html = await _getString(
        mobileListUrl(query: query, categoryId: categoryId, page: page),
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
