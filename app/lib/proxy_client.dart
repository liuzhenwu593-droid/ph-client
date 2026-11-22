/// Central HTTP-client factory for all app traffic (v0.2.5).
///
/// When the in-app proxy switch is ON, every client routes through the
/// local sing-box mixed inbound (127.0.0.1:10808) via an HTTP proxy;
/// when OFF, clients go direct. `findProxy` is a closure that reads the
/// live switch, so a client created once keeps following toggle changes.
///
/// IMPORTANT: when the switch is ON, this never returns DIRECT for a
/// remote host — if the local proxy is down, requests fail with a
/// connection error instead of silently leaking the real IP direct.
/// Only loopback itself is DIRECT (the video relay lives there).
library;

import 'dart:io';

class ProxyHttp {
  /// Set by ProxyManager from the persisted switch. This is user intent,
  /// not the running state: ON means "route everything via the local
  /// proxy", even if the service failed to start — requests then fail
  /// visibly instead of going direct.
  static bool enabled = false;

  static const String localHost = '127.0.0.1';

  /// Mixed (HTTP + SOCKS5) inbound of the main sing-box service.
  static const int mixedPort = 10808;

  /// Mixed inbound of the throwaway latency-test service.
  static const int testMixedPort = 10809;

  static String findProxy(Uri uri) {
    if (!enabled) return 'DIRECT';
    if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
      return 'DIRECT';
    }
    return 'PROXY $localHost:$mixedPort';
  }

  static String findProxyForTest(Uri uri) {
    if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
      return 'DIRECT';
    }
    return 'PROXY $localHost:$testMixedPort';
  }

  /// A client for normal app traffic (API / site pages / thumbs /
  /// downloads / relay fetches). Closed by the caller after use, as
  /// before — the proxy decision is made per request by [findProxy].
  static HttpClient newClient({
    Duration timeout = const Duration(seconds: 10),
  }) {
    final client = HttpClient();
    client.findProxy = findProxy;
    client.connectionTimeout = timeout;
    return client;
  }

  /// A client that routes through the throwaway latency-test service.
  static HttpClient newTestClient({
    Duration timeout = const Duration(seconds: 5),
  }) {
    final client = HttpClient();
    client.findProxy = findProxyForTest;
    client.connectionTimeout = timeout;
    return client;
  }

  /// User-facing message for a network failure: when the proxy switch
  /// is ON, say plainly it is a proxy failure so the user checks the
  /// node instead of assuming Pornhub is down.
  static String wrapError(Object e) {
    if (!enabled) return e.toString();
    return '代理连接失败：本地代理无响应，节点可能离线；'
        '请检查节点是否在线，或关闭代理后重试（$e）';
  }
}
