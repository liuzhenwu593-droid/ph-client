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
///   parser re-fetches until the top HLS URL verifies with a real
///   playlist GET (~235 bytes), up to 5 attempts.
/// - Signed HLS URLs expire 2h after issue; never cache them across
///   launches. No login, no account, no download in this app.
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
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(HttpHeaders.cookieHeader,
        'age_verified=1; accessAgeDisclaimerPH=1; '
        'accessAgeDisclaimerUK=1; accessPH=1');
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
    request.headers.set(HttpHeaders.refererHeader,
        '$_base/view_video.php?viewkey=$viewkey');
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
    sources.add(VideoSource(
      quality: (item['quality'] ?? '').toString(),
      format: (item['format'] ?? '').toString(),
      url: videoUrl,
      width: item['width'] is num ? (item['width'] as num).toInt() : 0,
      height: item['height'] is num ? (item['height'] as num).toInt() : 0,
      isDefault: item['defaultQuality'] == true,
    ));
  }
  sources.sort((a, b) {
    final formatOrder =
        (a.format == 'hls' ? 0 : 1) - (b.format == 'hls' ? 0 : 1);
    if (formatOrder != 0) return formatOrder;
    return b.height - a.height;
  });
  return sources;
}

/// Fetch detail page and return playable sources, retrying until the top
/// HLS URL verifies (see file header for the ev-h / hv-h finding).
/// Throws [ParseException] if no verifiable URL appears in 5 attempts.
Future<VideoDetail> directVideoSources(
  String viewkey, {
  int maxAttempts = 5,
}) async {
  ParseException? lastError;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    Map<String, dynamic> flashvars;
    try {
      final html = await _getString(
          '$_base/view_video.php?viewkey=${Uri.encodeComponent(viewkey)}');
      flashvars = extractFlashvars(html);
    } on ParseException catch (e) {
      lastError = e;
      if (attempt < maxAttempts) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      rethrow;
    }
    final sources = _sourcesFromFlashvars(flashvars);
    final hls = sources.where((s) => s.format == 'hls').toList();
    if (hls.isNotEmpty && await _verifyHls(hls.first.url, viewkey)) {
      return VideoDetail(
        viewkey: viewkey,
        title: (flashvars['video_title'] ?? '').toString(),
        duration: flashvars['video_duration'] is num
            ? (flashvars['video_duration'] as num).toInt()
            : 0,
        thumb: (flashvars['image_url'] ?? '').toString(),
        sources: sources,
      );
    }
    lastError = ParseException(
        'attempt $attempt: HLS URL did not verify '
        '(host=${hls.isNotEmpty ? Uri.parse(hls.first.url).host : 'none'})');
    if (attempt < maxAttempts) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }
  throw ParseException(
      'no verifiable HLS URL after $maxAttempts attempts: $lastError');
}
