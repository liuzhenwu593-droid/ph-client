/// Offline downloads: HLS (m3u8 + .ts) saved to the app's own directory
/// and played back locally with ExoPlayer. No ffmpeg, no merging.
///
/// How it works (verified live 2026-11-22):
/// - The master playlist has one variant line, e.g.
///   `index-v1-a1.m3u8?validfrom=...&hash=...` (relative, signed query).
/// - The media playlist lists ~3-6s .ts segments, also relative with the
///   same signed query, and has NO #EXT-X-KEY (segments are not encrypted).
/// - So: fetch master -> pick the variant for the chosen quality -> fetch
///   the media playlist -> download every .ts segment -> write a local
///   playlist.m3u8 that references the local segment files by name.
///   The signed URLs are only used during the download itself, which
///   starts immediately after the URLs are issued (they expire in 2h).
/// - Playback is VideoPlayerController.file(File(local playlist)).
///
/// One download runs at a time; starting another while one is active is
/// refused with a message. Downloads survive app restarts (the item list
/// is persisted); an interrupted download is marked failed and can be
/// retried, which re-downloads from scratch.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'proxy_client.dart';

const String _base = 'https://www.pornhub.com';
const String _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

enum DownloadStatus { downloading, done, failed }

class DownloadItem {
  const DownloadItem({
    required this.viewkey,
    required this.title,
    required this.thumb,
    required this.duration,
    required this.qualityLabel,
    required this.dirName,
    required this.totalSegments,
    required this.downloadedSegments,
    required this.sizeBytes,
    required this.downloadedAtMs,
    required this.status,
    this.error = '',
  });

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    return DownloadItem(
      viewkey: (json['viewkey'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      thumb: (json['thumb'] ?? '').toString(),
      duration: (json['duration'] ?? '').toString(),
      qualityLabel: (json['qualityLabel'] ?? '').toString(),
      dirName: (json['dirName'] ?? '').toString(),
      totalSegments: json['totalSegments'] is num
          ? (json['totalSegments'] as num).toInt()
          : 0,
      downloadedSegments: json['downloadedSegments'] is num
          ? (json['downloadedSegments'] as num).toInt()
          : 0,
      sizeBytes: json['sizeBytes'] is num
          ? (json['sizeBytes'] as num).toInt()
          : 0,
      downloadedAtMs: json['downloadedAtMs'] is num
          ? (json['downloadedAtMs'] as num).toInt()
          : 0,
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => DownloadStatus.failed,
      ),
      error: (json['error'] ?? '').toString(),
    );
  }

  final String viewkey;
  final String title;
  final String thumb;
  final String duration;
  final String qualityLabel;
  final String dirName;
  final int totalSegments;
  final int downloadedSegments;
  final int sizeBytes;
  final int downloadedAtMs;
  final DownloadStatus status;
  final String error;

  Map<String, dynamic> toJson() => {
    'viewkey': viewkey,
    'title': title,
    'thumb': thumb,
    'duration': duration,
    'qualityLabel': qualityLabel,
    'dirName': dirName,
    'totalSegments': totalSegments,
    'downloadedSegments': downloadedSegments,
    'sizeBytes': sizeBytes,
    'downloadedAtMs': downloadedAtMs,
    'status': status.name,
    'error': error,
  };

  double get progress =>
      totalSegments > 0 ? downloadedSegments / totalSegments : 0;

  String get sizeLabel {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    return '$sizeBytes B';
  }

  DownloadItem copyWith({
    int? totalSegments,
    int? downloadedSegments,
    int? sizeBytes,
    DownloadStatus? status,
    String? error,
  }) {
    return DownloadItem(
      viewkey: viewkey,
      title: title,
      thumb: thumb,
      duration: duration,
      qualityLabel: qualityLabel,
      dirName: dirName,
      totalSegments: totalSegments ?? this.totalSegments,
      downloadedSegments: downloadedSegments ?? this.downloadedSegments,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      downloadedAtMs: downloadedAtMs,
      status: status ?? this.status,
      error: error ?? this.error,
    );
  }
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._(this._prefs) {
    final raw = _prefs.getStringList(_key) ?? const [];
    for (final item in raw) {
      try {
        final data = jsonDecode(item);
        if (data is Map<String, dynamic>) {
          _items.add(DownloadItem.fromJson(data));
        }
      } catch (_) {
        // Skip one corrupt entry.
      }
    }
    // A previous run that was killed mid-download leaves a stale
    // "downloading" entry: mark it failed so it can be retried.
    var changed = false;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].status == DownloadStatus.downloading) {
        _items[i] = _items[i].copyWith(
          status: DownloadStatus.failed,
          error: '上次下载被中断，请重试',
        );
        changed = true;
      }
    }
    if (changed) _persist();
  }

  static const _key = 'downloads_v1';

  final SharedPreferences _prefs;
  final List<DownloadItem> _items = [];

  bool _active = false;
  bool _cancelRequested = false;

  static Future<DownloadManager> load() async {
    return DownloadManager._(await SharedPreferences.getInstance());
  }

  List<DownloadItem> get items => List.unmodifiable(_items);

  bool get hasActiveDownload => _active;

  DownloadItem? downloadFor(String viewkey) {
    for (final item in _items) {
      if (item.viewkey == viewkey) return item;
    }
    return null;
  }

  bool isDownloaded(String viewkey) {
    final item = downloadFor(viewkey);
    return item != null && item.status == DownloadStatus.done;
  }

  Future<Directory> _downloadsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> localPlaylistPath(DownloadItem item) async {
    final dir = await _downloadsDir();
    return '${dir.path}/${item.dirName}/playlist.m3u8';
  }

  Future<void> _persist() async {
    await _prefs.setStringList(
      _key,
      _items.map((i) => jsonEncode(i.toJson())).toList(),
    );
  }

  void _updateItem(DownloadItem updated) {
    final index = _items.indexWhere((i) => i.viewkey == updated.viewkey);
    if (index >= 0) {
      _items[index] = updated;
    } else {
      _items.insert(0, updated);
    }
    notifyListeners();
  }

  /// Download [source] (one HLS quality) for [video]. Returns true when
  /// the download started; false when another download is already running
  /// or this video is already downloaded at this quality.
  Future<bool> startDownload(VideoItem video, VideoSource source) async {
    if (_active) return false;
    final existing = downloadFor(video.viewkey);
    if (existing != null &&
        existing.status == DownloadStatus.done &&
        existing.qualityLabel == source.label) {
      return false;
    }
    _active = true;
    _cancelRequested = false;
    final dirName =
        '${video.viewkey}_${source.height > 0 ? source.height : source.label}';
    var item = DownloadItem(
      viewkey: video.viewkey,
      title: video.title,
      thumb: video.thumb,
      duration: video.duration,
      qualityLabel: source.label,
      dirName: dirName,
      totalSegments: 0,
      downloadedSegments: 0,
      sizeBytes: 0,
      downloadedAtMs: DateTime.now().millisecondsSinceEpoch,
      status: DownloadStatus.downloading,
    );
    _updateItem(item);
    await _persist();
    Directory? dir;
    try {
      final root = await _downloadsDir();
      dir = Directory('${root.path}/$dirName');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);

      final masterText = await _getText(
        source.url,
        referer: '$_base/view_video.php?viewkey=${video.viewkey}',
      );
      final variantUrl = _pickVariant(masterText, source);
      final mediaText = variantUrl == null
          ? masterText
          : await _getText(
              variantUrl,
              referer: '$_base/view_video.php?viewkey=${video.viewkey}',
            );
      final segmentUrls = _segmentUrls(mediaText, variantUrl ?? source.url);
      if (segmentUrls.isEmpty) {
        throw Exception('分片清单为空');
      }
      item = item.copyWith(totalSegments: segmentUrls.length);
      _updateItem(item);

      final lines = mediaText.split('\n');
      final localLines = <String>[];
      var segmentIndex = 0;
      var downloadedBytes = 0;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          localLines.add(line);
          continue;
        }
        if (_cancelRequested) throw _CancelledException();
        final segUrl = segmentUrls[segmentIndex];
        final fileName = _fileNameOf(segUrl, segmentIndex);
        final file = File('${dir.path}/$fileName');
        downloadedBytes += await _downloadFile(
          segUrl,
          file,
          referer: '$_base/view_video.php?viewkey=${video.viewkey}',
        );
        localLines.add(fileName);
        segmentIndex++;
        item = item.copyWith(
          downloadedSegments: segmentIndex,
          sizeBytes: downloadedBytes,
        );
        _updateItem(item);
      }
      final playlist = File('${dir.path}/playlist.m3u8');
      await playlist.writeAsString(localLines.join('\n'));
      item = item.copyWith(
        status: DownloadStatus.done,
        downloadedSegments: segmentUrls.length,
        sizeBytes: downloadedBytes,
      );
      _updateItem(item);
      await _persist();
      return true;
    } on _CancelledException {
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _items.removeWhere((i) => i.viewkey == video.viewkey);
      await _persist();
      notifyListeners();
      return false;
    } catch (e) {
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
      item = item.copyWith(status: DownloadStatus.failed, error: '$e');
      _updateItem(item);
      await _persist();
      return false;
    } finally {
      _active = false;
      notifyListeners();
    }
  }

  void cancelActive() {
    _cancelRequested = true;
  }

  Future<void> deleteDownload(DownloadItem item) async {
    final root = await _downloadsDir();
    final dir = Directory('${root.path}/${item.dirName}');
    if (await dir.exists()) await dir.delete(recursive: true);
    _items.removeWhere((i) => i.viewkey == item.viewkey);
    await _persist();
    notifyListeners();
  }

  /// Pick the variant playlist URL out of a master playlist. When the
  /// master has several variants, take the one whose RESOLUTION matches
  /// the chosen quality; a single-variant master (the usual case) is
  /// returned as-is.
  String? _pickVariant(String masterText, VideoSource source) {
    final lines = masterText.split('\n');
    String? fallback;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      if (i + 1 >= lines.length) continue;
      final uri = lines[i + 1].trim();
      if (uri.isEmpty || uri.startsWith('#')) continue;
      fallback ??= uri;
      final heightMatch = RegExp(r'RESOLUTION=\d+x(\d+)')
          .firstMatch(line)
          ?.group(1);
      final height = int.tryParse(heightMatch ?? '');
      if (height != null && height == source.height) {
        return Uri.parse(source.url).resolve(uri).toString();
      }
    }
    if (fallback == null) return null;
    return Uri.parse(source.url).resolve(fallback).toString();
  }

  List<String> _segmentUrls(String mediaText, String playlistUrl) {
    final urls = <String>[];
    final base = Uri.parse(playlistUrl);
    for (final rawLine in mediaText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      urls.add(base.resolve(line).toString());
    }
    return urls;
  }

  String _fileNameOf(String url, int index) {
    final path = Uri.parse(url).pathSegments.lastOrNull ?? '';
    final clean = path.split('?').first;
    if (clean.endsWith('.ts')) return clean;
    return 'seg-$index.ts';
  }

  Future<String> _getText(String url, {required String referer}) async {
    // v0.2.5: downloads go through the proxy when it is on.
    final client = ProxyHttp.newClient();
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      request.headers.set('Origin', _base);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response
          .transform(const Utf8Decoder())
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('HTTP ${response.statusCode}');
      }
      return body;
    } finally {
      client.close();
    }
  }

  /// Downloads one URL to [file]; returns the number of bytes written.
  Future<int> _downloadFile(
    String url,
    File file, {
    required String referer,
  }) async {
    final client = ProxyHttp.newClient(
      timeout: const Duration(seconds: 60),
    );
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      request.headers.set('Origin', _base);
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('HTTP ${response.statusCode} for segment');
      }
      final sink = file.openWrite();
      var bytes = 0;
      await for (final chunk in response) {
        bytes += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
      return bytes;
    } finally {
      client.close();
    }
  }
}

class _CancelledException implements Exception {}
