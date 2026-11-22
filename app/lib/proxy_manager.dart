/// In-app proxy manager (v0.2.5): node list, enable switch, sing-box
/// lifecycle, and per-node latency tests.
///
/// The user pastes vless:// / vmess:// / socks:// / http(s):// links;
/// nodes live in SharedPreferences only, one node is active at a time,
/// and switching restarts the service with the new node immediately.
/// The proxy switch defaults OFF; when ON, ProxyHttp routes ALL app
/// traffic through the local sing-box mixed inbound (127.0.0.1:10808)
/// and the loopback relay serves ExoPlayer. When the service fails to
/// start, ProxyHttp stays ON so requests fail visibly instead of
/// silently going direct.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'proxy_client.dart';
import 'proxy_node.dart';
import 'proxy_relay.dart';

enum ProxyStatus { off, starting, running, error }

/// Latency target: a real request through the node to the site itself,
/// timed to response headers. NOT a TCP handshake to the node.
const String _latencyTarget = 'https://www.pornhub.com/';

class ProxyManager extends ChangeNotifier {
  ProxyManager._(this._prefs);

  static ProxyManager? _instance;

  /// Set by [load] in main(); pages use the singleton directly.
  static ProxyManager get instance => _instance!;

  static const MethodChannel _channel = MethodChannel('com.liu.phclient/proxy');

  static const _enabledKey = 'proxy_enabled';
  static const _nodesKey = 'proxy_nodes';
  static const _currentKey = 'proxy_current_id';

  /// Per-request timeout for latency tests (task requirement: 5s cap).
  static const Duration latencyTimeout = Duration(seconds: 5);

  final SharedPreferences _prefs;

  /// Serialize start/stop/switch/test ops so two taps cannot race.
  Future<void> _pending = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final run = _pending.then((_) => op());
    _pending = run.then((_) {}, onError: (_) {});
    return run;
  }

  ProxyStatus status = ProxyStatus.off;
  String? errorMessage;

  bool _enabled = false;
  bool get enabled => _enabled;

  List<ProxyNode> nodes = [];
  String? currentId;

  ProxyNode? get currentNode {
    final id = currentId;
    if (id == null) return null;
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  /// Node ids currently being latency-tested (UI shows "测速中…").
  final Set<String> testingIds = {};

  bool testingAll = false;

  static Future<ProxyManager> load() async {
    final prefs = await SharedPreferences.getInstance();
    final manager = ProxyManager._(prefs);
    manager._enabled = prefs.getBool(_enabledKey) ?? false;
    manager.currentId = prefs.getString(_currentKey);
    final raw = prefs.getString(_nodesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          manager.nodes = decoded
              .whereType<Map<String, dynamic>>()
              .map(ProxyNode.fromJson)
              .where((n) => n.id.isNotEmpty && n.link.isNotEmpty)
              .toList();
        }
      } catch (_) {
        manager.nodes = [];
      }
    }
    if (manager.currentNode == null && manager.nodes.isNotEmpty) {
      manager.currentId = manager.nodes.first.id;
    }
    _instance = manager;
    // The switch reflects user intent: if it was left ON, route through
    // the local proxy from the start (requests fail visibly until the
    // service is up) and bring the service up in the background.
    ProxyHttp.enabled = manager._enabled;
    if (manager._enabled && manager.currentNode != null) {
      unawaited(manager._applyState());
    }
    return manager;
  }

  Future<void> _persist() async {
    await _prefs.setBool(_enabledKey, _enabled);
    await _prefs.setString(
      _nodesKey,
      jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
    final id = currentId;
    if (id == null) {
      await _prefs.remove(_currentKey);
    } else {
      await _prefs.setString(_currentKey, id);
    }
  }

  void _setStatus(ProxyStatus next, [String? error]) {
    status = next;
    errorMessage = error;
    notifyListeners();
  }

  /// (Re)start the service with the current node, or stop it when the
  /// switch is off / no node is selected. Called under [_enqueue].
  Future<void> _applyState() async {
    if (!_enabled) {
      await _stopService();
      _setStatus(ProxyStatus.off);
      return;
    }
    final node = currentNode;
    if (node == null) {
      await _stopService();
      _setStatus(ProxyStatus.error, '请先添加一个节点');
      return;
    }
    _setStatus(ProxyStatus.starting);
    try {
      final config = buildProxyConfig(
        node,
        mixedPort: ProxyHttp.mixedPort,
      );
      await _channel.invokeMethod<String>('start', {'config': config});
      await ProxyRelay.instance.start();
      _setStatus(ProxyStatus.running);
    } on PlatformException catch (e) {
      _setStatus(
        ProxyStatus.error,
        '代理启动失败：${e.message ?? e.code}，请检查节点或关闭代理',
      );
    } catch (e) {
      _setStatus(ProxyStatus.error, '代理启动失败：$e');
    }
  }

  Future<void> _stopService() async {
    try {
      await ProxyRelay.instance.stop();
    } catch (_) {}
    try {
      await _channel.invokeMethod<String>('stop');
    } on PlatformException catch (_) {
      // Stopping a dead service is not an error worth surfacing.
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    ProxyHttp.enabled = value;
    await _persist();
    notifyListeners();
    await _enqueue(_applyState);
  }

  /// Parse + add a pasted link. Throws [FormatException] when the link
  /// is not a supported node link. An already-added link just selects it.
  Future<ProxyNode> addNode(String link) async {
    final node = parseProxyLink(link);
    for (final existing in nodes) {
      if (existing.link == node.link) {
        await selectNode(existing.id);
        return existing;
      }
    }
    nodes = [...nodes, node];
    currentId ??= node.id;
    await _persist();
    notifyListeners();
    return node;
  }

  Future<void> removeNode(String id) async {
    final wasCurrent = id == currentId;
    nodes = nodes.where((n) => n.id != id).toList();
    if (wasCurrent) {
      currentId = nodes.isEmpty ? null : nodes.first.id;
    }
    await _persist();
    notifyListeners();
    if (wasCurrent && _enabled) {
      await _enqueue(_applyState);
    }
  }

  /// Switch the active node. Takes effect immediately: a running service
  /// is restarted with the new node.
  Future<void> selectNode(String id) async {
    if (!nodes.any((n) => n.id == id)) return;
    if (id == currentId) return;
    currentId = id;
    await _persist();
    notifyListeners();
    if (_enabled) {
      await _enqueue(_applyState);
    }
  }

  /// Measure one node's latency: a real GET through that node to
  /// pornhub.com, timed to response headers (TTFB). Returns ms, or -1
  /// on failure/timeout. The current node is tested through the running
  /// service; any other node gets a throwaway test service on its own
  /// mixed port, so testing never disturbs active playback.
  Future<int> testLatency(ProxyNode node) async {
    if (testingIds.contains(node.id)) return node.lastLatencyMs ?? -1;
    return _enqueue(() async {
      testingIds.add(node.id);
      notifyListeners();
      try {
        final useMainService =
            node.id == currentId && status == ProxyStatus.running;
        int? ms;
        if (useMainService) {
          ms = await _timeThroughProxy(ProxyHttp.newClient());
        } else {
          final config = buildProxyConfig(
            node,
            mixedPort: ProxyHttp.testMixedPort,
          );
          await _channel.invokeMethod<String>('startTest', {'config': config});
          try {
            ms = await _timeThroughProxy(ProxyHttp.newTestClient());
          } finally {
            try {
              await _channel.invokeMethod<String>('stopTest');
            } catch (_) {}
          }
        }
        final value = ms ?? -1;
        _recordLatency(node.id, value);
        return value;
      } catch (_) {
        _recordLatency(node.id, -1);
        return -1;
      } finally {
        testingIds.remove(node.id);
        notifyListeners();
      }
    });
  }

  /// Time a GET to [_latencyTarget] through [client] (already routed to
  /// a mixed inbound by its findProxy). Returns ms to response headers,
  /// or null on failure/timeout.
  Future<int?> _timeThroughProxy(HttpClient client) async {
    final stopwatch = Stopwatch()..start();
    try {
      final request = await client
          .getUrl(Uri.parse(_latencyTarget))
          .timeout(latencyTimeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
      );
      request.headers.set(HttpHeaders.refererHeader, _latencyTarget);
      final response = await request.close().timeout(latencyTimeout);
      stopwatch.stop();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.movedPermanently &&
          response.statusCode != HttpStatus.found) {
        return null;
      }
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  void _recordLatency(String id, int ms) {
    nodes = nodes
        .map(
          (n) => n.id == id
              ? n.copyWith(
                  lastLatencyMs: ms,
                  lastTestedAtMs: DateTime.now().millisecondsSinceEpoch,
                )
              : n,
        )
        .toList();
    unawaited(_persist());
    notifyListeners();
  }

  /// Test every node in turn (sequential — one throwaway service at a
  /// time). Never blocks the list: each node updates in place as its
  /// result lands, and a failure just shows 超时 for that node.
  Future<void> testAll() async {
    if (testingAll || nodes.isEmpty) return;
    testingAll = true;
    notifyListeners();
    try {
      for (final node in List<ProxyNode>.of(nodes)) {
        await testLatency(node);
      }
    } finally {
      testingAll = false;
      notifyListeners();
    }
  }
}
