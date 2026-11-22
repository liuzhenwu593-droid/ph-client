/// Site listing pages (HTML) — used for category browsing.
///
/// The Webmasters JSON API has no category-listing endpoint: it can list
/// categories (names + ids) but not the videos inside one. The site's own
/// `/video?c=<id>` pages do, with a server-rendered list in
/// `<ul id="videoCategory">`.
///
/// Verified live 2026-11-22 from this VM:
/// - GET /video?c=37 -> 200, 30 items in #videoCategory, page=2 works
///   (different videos, ~2 overlap from the header dropdowns — those are
///   excluded by parsing only inside #videoCategory).
/// - Each item carries data-video-vkey, title, thumb, duration, views.
///   No rating is shown in the list, so rating is 0 for these items.
/// - Country feeds were NOT implemented here: the server ignores the ?cc=
///   parameter for anonymous requests (phCountryCode stays US, lists are
///   byte-identical for jp/us/de/br/kr/gb/world, pages 1-3, hottest and
///   most-viewed, with and without session cookies). The ranking follows
///   the request IP's country, which the app cannot override — so no
///   country switcher is shipped. See README.md.
///
/// Pure Dart (dart:io / dart:convert only).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

const String _base = 'https://www.pornhub.com';
const String _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

Future<String> _getHtml(String url) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(
      HttpHeaders.cookieHeader,
      'age_verified=1; accessAgeDisclaimerPH=1; '
      'accessAgeDisclaimerUK=1; accessPH=1',
    );
    request.headers.set(HttpHeaders.refererHeader, '$_base/');
    final response = await request.close().timeout(const Duration(seconds: 30));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw ParseException('HTTP ${response.statusCode} from $url');
    }
    return body;
  } finally {
    client.close();
  }
}

class ParseException implements Exception {
  ParseException(this.message);
  final String message;
  @override
  String toString() => 'ParseException: $message';
}

String _unescape(String s) {
  return s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#39;', "'");
}

/// "2.2M" -> 2200000, "179K" -> 179000, "1,234" -> 1234.
int _parseViews(String raw) {
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

/// Parse the #videoCategory list out of a /video listing page.
/// Returns the videos in page order. Throws [ParseException] when the
/// page layout is not recognised.
List<VideoItem> parseSiteList(String html) {
  final start = html.indexOf('<ul id="videoCategory"');
  if (start < 0) throw ParseException('videoCategory list not found');
  final end = html.indexOf('</ul>', start);
  if (end < 0) throw ParseException('videoCategory list not closed');
  final section = html.substring(start, end);
  final itemRe = RegExp(r'<li class="pcVideoListItem.*?</li>', dotAll: true);
  final videos = <VideoItem>[];
  for (final match in itemRe.allMatches(section)) {
    final block = match.group(0)!;
    final vkey = RegExp(r'data-video-vkey="([0-9a-f]+)"')
        .firstMatch(block)
        ?.group(1);
    if (vkey == null || vkey.isEmpty) continue;
    final titleMatch = RegExp(
      r'<span class="title">\s*<a[^>]*>(.*?)</a>',
      dotAll: true,
    ).firstMatch(block);
    final title = titleMatch == null
        ? ''
        : _unescape(
            titleMatch.group(1)!.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
          );
    if (title.isEmpty) continue;
    final thumbMatch = RegExp(
      r'(?:src|data-mediumthumb)="(https://[^"]*phncdn[^"]*)"',
    ).firstMatch(block);
    final thumb = thumbMatch?.group(1) ?? '';
    final duration =
        RegExp(r'<var class="duration">([^<]+)</var>')
            .firstMatch(block)
            ?.group(1)
            ?.trim() ??
        '';
    final viewsRaw =
        RegExp(r'<span class="views"><var>([^<]+)</var>')
            .firstMatch(block)
            ?.group(1) ??
        '';
    videos.add(
      VideoItem(
        viewkey: vkey,
        title: title,
        duration: duration,
        views: _parseViews(viewsRaw),
        rating: 0,
        thumb: thumb,
        url: '$_base/view_video.php?viewkey=$vkey',
      ),
    );
  }
  if (videos.isEmpty) throw ParseException('no videos parsed from site list');
  return videos;
}

/// Videos inside one category (site page `/video?c=<id>`).
Future<List<VideoItem>> directCategoryVideos(
  int categoryId, {
  int page = 1,
}) async {
  final html = await _getHtml('$_base/video?c=$categoryId&page=$page');
  return parseSiteList(html);
}

/// Category list (Webmasters JSON, 243 entries). Same source the backend
/// /api/categories uses.
Future<List<CategoryItem>> directCategories() async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('$_base/webmasters/categories'))
        .timeout(const Duration(seconds: 30));
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(
      HttpHeaders.cookieHeader,
      'age_verified=1; accessAgeDisclaimerPH=1; '
      'accessAgeDisclaimerUK=1; accessPH=1',
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw ParseException('HTTP ${response.statusCode} from categories');
    }
    final data = jsonDecode(body);
    if (data is! Map || data['categories'] is! List) {
      throw ParseException('unexpected categories shape');
    }
    return (data['categories'] as List)
        .whereType<Map<String, dynamic>>()
        .map(CategoryItem.fromJson)
        .where((c) => c.id != 0 && c.name.isNotEmpty)
        .toList();
  } finally {
    client.close();
  }
}
