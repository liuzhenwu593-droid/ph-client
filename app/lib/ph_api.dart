/// Data source routing: backend first (when configured), in-app parser
/// as fallback. The app works with NO backend at all — direct parsing is
/// the default path until the user pastes a backend URL in Settings.
///
/// Backend contract (backend/server.py): GET {base}/api/home,
/// /api/search?q=&page=, /api/video?viewkey= — all JSON, same shapes as
/// the models here. The backend only returns verified-playable HLS URLs
/// (it retries until the master playlist GETs 200), so the app can trust
/// backend sources without re-verifying them.
///
/// Pure Dart (dart:io / dart:convert only).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'ph_parse.dart' as direct;

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => 'ApiException: $message';
}

class PhApi {
  PhApi({String? backendUrl}) : _backendUrl = _clean(backendUrl);

  static String? _clean(String? url) {
    final trimmed = (url ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? null : trimmed;
  }

  void setBackendUrl(String? url) => _backendUrl = _clean(url);

  String? get backendUrl => _backendUrl;
  String? _backendUrl;

  bool get usesBackend => _backendUrl != null;

  Future<Map<String, dynamic>> _getBackendJson(String path) async {
    final base = _backendUrl;
    if (base == null) throw ApiException('no backend configured');
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw ApiException('backend HTTP ${response.statusCode}: $body');
      }
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw ApiException('backend returned unexpected JSON');
      }
      return data;
    } finally {
      client.close();
    }
  }

  List<VideoItem> _videosFrom(Map<String, dynamic> data) {
    final raw = data['videos'];
    if (raw is! List) throw ApiException('missing videos list');
    return raw
        .whereType<Map<String, dynamic>>()
        .map(VideoItem.fromJson)
        .toList();
  }

  Future<List<VideoItem>> home({int page = 1}) async {
    if (usesBackend) {
      try {
        return _videosFrom(await _getBackendJson('/api/home?page=$page'));
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    return direct.directSearch('', page: page);
  }

  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    if (usesBackend) {
      try {
        final encoded = Uri.encodeQueryComponent(query);
        return _videosFrom(
            await _getBackendJson('/api/search?q=$encoded&page=$page'));
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    return direct.directSearch(query, page: page);
  }

  Future<VideoDetail> video(String viewkey) async {
    if (usesBackend) {
      try {
        final data = await _getBackendJson(
            '/api/video?viewkey=${Uri.encodeQueryComponent(viewkey)}');
        final detail = VideoDetail.fromJson(data);
        if (detail.hlsSources.isNotEmpty) return detail;
        // Backend answered but with no playable HLS: fall through.
      } on ApiException {
        // Fall through to direct parsing below.
      }
    }
    return direct.directVideoSources(viewkey);
  }

  /// Cheap liveness check for the Settings "test connection" button.
  Future<bool> testBackend() async {
    if (!usesBackend) return false;
    try {
      final data = await _getBackendJson('/health');
      return data['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}
