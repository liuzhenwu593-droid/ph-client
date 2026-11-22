/// Loopback relay for ExoPlayer (v0.2.5).
///
/// video_player / ExoPlayer has no proxy setting, so when the in-app
/// proxy is ON the player cannot fetch HLS playlists, segments or
/// preview mp4s directly — it would go direct (and fail) instead of
/// through the node. The relay fixes that: a tiny HTTP server on
/// 127.0.0.1:10810 that fetches the real URL through the proxied
/// HttpClient and streams it back.
///
/// - `/hls/list.m3u8?u=<url>&vk=<viewkey>`: fetches a playlist and
///   rewrites every URI inside it (segments, nested playlists, EXT-X-KEY
///   / EXT-X-MAP URIs) to relay URLs, so the whole HLS session stays
///   behind the relay. The path keeps the .m3u8 extension so ExoPlayer
///   detects HLS.
/// - `/fetch/file.<ext>?u=<url>&vk=<viewkey>`: byte pass-through for
///   segments and preview mp4s, forwarding Range headers (ExoPlayer
///   seeks mp4s with ranges) and status / content headers.
///
/// The relay binds loopback only and only forwards http(s) URLs. It
/// runs on a FIXED port so player URLs stay valid even if the relay is
/// briefly down — then ExoPlayer gets a clean connection-refused
/// instead of silently playing direct.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_client.dart';

const String _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
const String _base = 'https://www.pornhub.com';

class ProxyRelay {
  ProxyRelay._();
  static final ProxyRelay instance = ProxyRelay._();

  static const int port = 10810;

  HttpServer? _server;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// Relay URL for any playable media URL (HLS playlist or mp4). The
  /// path keeps the original extension so ExoPlayer infers the type.
  String mediaUrl(String url, {String? viewkey}) {
    final ext = _extensionOf(url);
    final isPlaylist = ext == 'm3u8';
    final path = isPlaylist ? '/hls/list.m3u8' : '/fetch/file.$ext';
    return _relayUrl(path, url, viewkey);
  }

  String _relayUrl(String path, String url, String? viewkey) {
    var out =
        'http://127.0.0.1:$port$path?u=${Uri.encodeComponent(url)}';
    if (viewkey != null && viewkey.isNotEmpty) {
      out += '&vk=${Uri.encodeComponent(viewkey)}';
    }
    return out;
  }

  static String _extensionOf(String url) {
    final path = Uri.parse(url).path;
    final last = path.split('/').last;
    final dot = last.lastIndexOf('.');
    if (dot < 0) return 'bin';
    final ext = last.substring(dot + 1).toLowerCase();
    if (ext.isEmpty || ext.length > 5) return 'bin';
    return ext;
  }

  static const _forwardResponseHeaders = {
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
  };

  Future<void> _handle(HttpRequest request) async {
    final target = request.uri.queryParameters['u'];
    if (target == null ||
        !(target.startsWith('http://') || target.startsWith('https://'))) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('bad url');
      await request.response.close();
      return;
    }
    final viewkey = request.uri.queryParameters['vk'];
    final isPlaylist = request.uri.path.startsWith('/hls');
    try {
      final client = ProxyHttp.newClient(
        timeout: const Duration(seconds: 15),
      );
      try {
        final upstream = await client.getUrl(Uri.parse(target));
        upstream.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        upstream.headers.set(
          HttpHeaders.refererHeader,
          viewkey != null && viewkey.isNotEmpty
              ? '$_base/view_video.php?viewkey=$viewkey'
              : '$_base/',
        );
        upstream.headers.set('Origin', _base);
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          upstream.headers.set(HttpHeaders.rangeHeader, range);
        }
        final response = await upstream.close();
        final out = request.response;
        out.statusCode = response.statusCode;
        response.headers.forEach((name, values) {
          if (_forwardResponseHeaders.contains(name.toLowerCase())) {
            for (final value in values) {
              out.headers.add(name, value);
            }
          }
        });
        if (isPlaylist) {
          final body = await response.transform(utf8.decoder).join();
          out.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/vnd.apple.mpegurl',
          );
          out.write(_rewritePlaylist(body, target, viewkey));
          await out.close();
        } else {
          await out.addStream(response);
          await out.close();
        }
      } finally {
        client.close();
      }
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.write('relay error: $e');
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Rewrite every URI in a playlist to a relay URL, resolved against
  /// the playlist's own URL (segments are usually relative).
  String _rewritePlaylist(String body, String playlistUrl, String? viewkey) {
    final base = Uri.parse(playlistUrl);
    final out = StringBuffer();
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trimRight();
      if (line.startsWith('#')) {
        out.writeln(
          line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
            final absolute = base.resolve(match.group(1)!).toString();
            return 'URI="${mediaUrl(absolute, viewkey: viewkey)}"';
          }),
        );
      } else if (line.isEmpty) {
        out.writeln(line);
      } else {
        final absolute = base.resolve(line).toString();
        out.writeln(mediaUrl(absolute, viewkey: viewkey));
      }
    }
    return out.toString();
  }
}
