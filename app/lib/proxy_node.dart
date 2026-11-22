/// Proxy nodes (v0.2.5): vless:// / vmess:// / socks:// / http(s):// link
/// parsing, sing-box outbound JSON, and the local-proxy service config.
///
/// The user pastes links himself in Settings; nothing is hardcoded here.
/// A node link contains its own UUID/password, so nodes are stored
/// locally in SharedPreferences only (app-private storage) and are never
/// committed to the repo or uploaded anywhere.
///
/// Supported transports: ws / tcp / grpc / http / httpupgrade. kcp and
/// quic links are rejected with a clear message (sing-box supports them,
/// but this app does not generate their extra parameters yet).
library;

import 'dart:convert';

enum ProxyProtocol { vless, vmess, socks, http }

/// One proxy node, as the user added it.
class ProxyNode {
  const ProxyNode({
    required this.id,
    required this.name,
    required this.link,
    required this.protocol,
    required this.server,
    required this.port,
    this.lastLatencyMs,
    this.lastTestedAtMs,
  });

  final String id;

  /// Display name: the link's #remark, or `host:port` when absent.
  final String name;

  /// The raw pasted link, stored as-is (it carries the UUID/password).
  final String link;
  final ProxyProtocol protocol;
  final String server;
  final int port;

  /// Last measured latency in ms (null = never tested, -1 = failed).
  final int? lastLatencyMs;
  final int? lastTestedAtMs;

  ProxyNode copyWith({int? lastLatencyMs, int? lastTestedAtMs}) {
    return ProxyNode(
      id: id,
      name: name,
      link: link,
      protocol: protocol,
      server: server,
      port: port,
      lastLatencyMs: lastLatencyMs ?? this.lastLatencyMs,
      lastTestedAtMs: lastTestedAtMs ?? this.lastTestedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'link': link,
    'protocol': protocol.name,
    'server': server,
    'port': port,
    'lastLatencyMs': lastLatencyMs,
    'lastTestedAtMs': lastTestedAtMs,
  };

  static ProxyNode fromJson(Map<String, dynamic> json) {
    return ProxyNode(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      link: (json['link'] ?? '').toString(),
      protocol: ProxyProtocol.values.firstWhere(
        (p) => p.name == json['protocol'],
        orElse: () => ProxyProtocol.vless,
      ),
      server: (json['server'] ?? '').toString(),
      port: json['port'] is num ? (json['port'] as num).toInt() : 443,
      lastLatencyMs: json['lastLatencyMs'] is num
          ? (json['lastLatencyMs'] as num).toInt()
          : null,
      lastTestedAtMs: json['lastTestedAtMs'] is num
          ? (json['lastTestedAtMs'] as num).toInt()
          : null,
    );
  }
}

String _newId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rnd = (now ^ 0x5DEECE66D) & 0xFFFFFFFF;
  return '${now.toRadixString(36)}${rnd.toRadixString(36)}';
}

final _uuidRe = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

String _decodeBase64Url(String input) {
  var s = input.trim().replaceAll('-', '+').replaceAll('_', '/');
  while (s.length % 4 != 0) {
    s += '=';
  }
  return utf8.decode(base64.decode(s));
}

String _nameFrom(Uri uri, String server, int port) {
  final frag = uri.fragment.trim();
  if (frag.isNotEmpty) return Uri.decodeComponent(frag);
  return '$server:$port';
}

int _portOr(Uri uri, int fallback) {
  if (uri.hasPort) return uri.port;
  return fallback;
}

void _checkServerPort(String server, int port) {
  if (server.isEmpty) throw const FormatException('链接里没有服务器地址');
  if (port < 1 || port > 65535) throw const FormatException('端口不对（应为 1-65535）');
}

void _checkUuid(String uuid) {
  if (!_uuidRe.hasMatch(uuid)) throw const FormatException('UUID 格式不对');
}

/// Parse a pasted proxy link into a node. Throws [FormatException] with
/// a user-readable reason when the link is not supported.
ProxyNode parseProxyLink(String rawLink) {
  final link = rawLink.trim();
  if (link.isEmpty) throw const FormatException('链接是空的');
  final lower = link.toLowerCase();
  if (lower.startsWith('vless://')) return _parseVless(link);
  if (lower.startsWith('vmess://')) return _parseVmess(link);
  if (lower.startsWith('socks://') ||
      lower.startsWith('socks5://') ||
      lower.startsWith('socks4://') ||
      lower.startsWith('socks4a://')) {
    return _parseSocks(link);
  }
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return _parseHttp(link);
  }
  throw const FormatException('只支持 vless://、vmess://、socks://、http(s):// 链接');
}

ProxyNode _parseVless(String link) {
  final uri = Uri.parse(link);
  final uuid = Uri.decodeComponent(uri.userInfo);
  _checkUuid(uuid);
  final server = uri.host;
  final port = _portOr(uri, 443);
  _checkServerPort(server, port);
  return ProxyNode(
    id: _newId(),
    name: _nameFrom(uri, server, port),
    link: link,
    protocol: ProxyProtocol.vless,
    server: server,
    port: port,
  );
}

ProxyNode _parseVmess(String link) {
  final body = link.substring('vmess://'.length).trim();
  // Classic format: vmess://base64(JSON).
  if (!body.contains('@')) {
    final decoded = _decodeBase64Url(body);
    final trimmed = decoded.trimLeft();
    if (!trimmed.startsWith('{')) {
      throw const FormatException('VMess 链接解码后不是 JSON');
    }
    final data = jsonDecode(trimmed);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('VMess 链接解码后不是 JSON');
    }
    final uuid = (data['id'] ?? '').toString();
    _checkUuid(uuid);
    final server = (data['add'] ?? '').toString();
    final port = data['port'] is num
        ? (data['port'] as num).toInt()
        : int.tryParse((data['port'] ?? '').toString()) ?? 0;
    _checkServerPort(server, port);
    final name = (data['ps'] ?? '').toString().trim();
    return ProxyNode(
      id: _newId(),
      name: name.isEmpty ? '$server:$port' : name,
      link: link,
      protocol: ProxyProtocol.vmess,
      server: server,
      port: port,
    );
  }
  // New-style URI format: vmess://uuid@host:port?params#name.
  final uri = Uri.parse(link);
  final uuid = Uri.decodeComponent(uri.userInfo);
  _checkUuid(uuid);
  final server = uri.host;
  final port = _portOr(uri, 443);
  _checkServerPort(server, port);
  return ProxyNode(
    id: _newId(),
    name: _nameFrom(uri, server, port),
    link: link,
    protocol: ProxyProtocol.vmess,
    server: server,
    port: port,
  );
}

ProxyNode _parseSocks(String link) {
  final uri = Uri.parse(link);
  final server = uri.host;
  final port = _portOr(uri, 1080);
  _checkServerPort(server, port);
  return ProxyNode(
    id: _newId(),
    name: _nameFrom(uri, server, port),
    link: link,
    protocol: ProxyProtocol.socks,
    server: server,
    port: port,
  );
}

ProxyNode _parseHttp(String link) {
  final uri = Uri.parse(link);
  final server = uri.host;
  final port = _portOr(uri, uri.scheme == 'https' ? 443 : 8080);
  _checkServerPort(server, port);
  return ProxyNode(
    id: _newId(),
    name: _nameFrom(uri, server, port),
    link: link,
    protocol: ProxyProtocol.http,
    server: server,
    port: port,
  );
}

// ---------------------------------------------------------------------------
// sing-box outbound JSON (field-for-field compatible with the proven
// shadiao SingBoxConfigGenerator for the same libbox build).
// ---------------------------------------------------------------------------

List<String> _csv(String? raw) {
  if (raw == null) return const [];
  return raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

String? _firstParam(Uri uri, List<String> keys) {
  for (final key in keys) {
    final value = uri.queryParameters[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

bool _paramEnabled(Uri uri, List<String> keys) {
  for (final key in keys) {
    final value = uri.queryParameters[key];
    if (value != null) {
      final v = value.trim().toLowerCase();
      return v.isEmpty || v == '1' || v == 'true' || v == 'yes';
    }
  }
  return false;
}

Map<String, dynamic> _tlsObject({
  required String serverName,
  List<String>? alpn,
  bool insecure = false,
  String? fingerprint,
}) {
  final tls = <String, dynamic>{
    'enabled': true,
    'server_name': serverName,
  };
  if (alpn != null && alpn.isNotEmpty) tls['alpn'] = alpn;
  if (insecure) tls['insecure'] = true;
  if (fingerprint != null && fingerprint.isNotEmpty) {
    tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
  }
  return tls;
}

/// Transport object for ws / grpc / http / httpupgrade. Returns null for
/// plain tcp (sing-box default) — the caller omits the key then.
Map<String, dynamic>? _transportFromUri(Uri uri) {
  var type = (_firstParam(uri, ['type', 'network']) ?? 'tcp').toLowerCase();
  if (type == 'none') type = 'tcp';
  if (type == 'tcp') {
    final headerType = _firstParam(uri, ['headerType', 'header_type']);
    if (headerType?.toLowerCase() == 'http') type = 'http';
  }
  if (type == 'tcp') return null;
  if (type != 'ws' && type != 'grpc' && type != 'http' && type != 'httpupgrade') {
    throw FormatException('不支持的传输方式：$type，仅支持 ws / tcp / grpc / http');
  }
  final hostValues = _csv(_firstParam(uri, ['host']));
  final transport = <String, dynamic>{'type': type};
  switch (type) {
    case 'ws':
      transport['path'] = uri.queryParameters['path'] ?? '/';
      if (hostValues.isNotEmpty) {
        transport['headers'] = {'Host': hostValues.first};
      }
      final ed = int.tryParse(
        _firstParam(uri, ['ed', 'maxEarlyData', 'max_early_data']) ?? '',
      );
      if (ed != null && ed > 0) transport['max_early_data'] = ed;
      final eh = _firstParam(uri, ['eh', 'earlyDataHeaderName', 'early_data_header_name']);
      if (eh != null) transport['early_data_header_name'] = eh;
    case 'grpc':
      transport['service_name'] =
          _firstParam(uri, ['serviceName', 'service_name', 'path']) ?? '';
    case 'http':
      transport['path'] = uri.queryParameters['path'] ?? '/';
      if (hostValues.isNotEmpty) transport['host'] = hostValues;
    case 'httpupgrade':
      transport['path'] = uri.queryParameters['path'] ?? '/';
      if (hostValues.isNotEmpty) transport['host'] = hostValues.first;
  }
  return transport;
}

Map<String, dynamic> _vlessOutbound(ProxyNode node) {
  final uri = Uri.parse(node.link);
  final uuid = Uri.decodeComponent(uri.userInfo);
  final out = <String, dynamic>{
    'type': 'vless',
    'server': node.server,
    'server_port': node.port,
    'uuid': uuid,
  };
  final flow = _firstParam(uri, ['flow']);
  if (flow != null && flow.isNotEmpty) out['flow'] = flow;
  final packetEncoding = _firstParam(uri, ['packetEncoding', 'packet_encoding']);
  if (packetEncoding != null && packetEncoding.isNotEmpty) {
    out['packet_encoding'] = packetEncoding;
  }
  final security = _firstParam(uri, ['security']) ?? '';
  if (security == 'tls' || security == 'reality') {
    final sni = _firstParam(uri, ['sni', 'host']) ?? node.server;
    final tls = _tlsObject(
      serverName: sni,
      alpn: _csv(_firstParam(uri, ['alpn'])),
      insecure: _paramEnabled(uri, [
        'allowInsecure',
        'allow_insecure',
        'insecure',
        'skip-cert-verify',
      ]),
      fingerprint: _firstParam(uri, ['fp', 'fingerprint', 'client-fingerprint']),
    );
    if (security == 'reality') {
      tls['reality'] = {
        'enabled': true,
        'public_key': _firstParam(uri, ['pbk']) ?? '',
        'short_id': _firstParam(uri, ['sid']) ?? '',
      };
    }
    out['tls'] = tls;
  }
  final transport = _transportFromUri(uri);
  if (transport != null) out['transport'] = transport;
  return out;
}

String _jsonString(dynamic value) {
  if (value == null) return '';
  return value.toString();
}

int _jsonInt(dynamic value, int fallback) {
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? fallback;
}

List<String> _jsonStringList(dynamic value) {
  if (value is List) {
    return value.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }
  if (value is String && value.isNotEmpty) return _csv(value);
  return const [];
}

Map<String, dynamic>? _vmessTransportFromJson(
  String network,
  Map<String, dynamic> config,
) {
  var type = network.toLowerCase();
  if (type == 'none') type = 'tcp';
  if (type == 'tcp') {
    final headerType =
        _jsonString(config['headerType']).isNotEmpty
            ? _jsonString(config['headerType'])
            : _jsonString(config['type']);
    if (headerType.toLowerCase() == 'http') type = 'http';
  }
  if (type == 'tcp') return null;
  if (type != 'ws' && type != 'grpc' && type != 'http' && type != 'httpupgrade') {
    throw FormatException('不支持的传输方式：$type，仅支持 ws / tcp / grpc / http');
  }
  final hostValues = _jsonStringList(config['host']);
  final transport = <String, dynamic>{'type': type};
  switch (type) {
    case 'ws':
      transport['path'] = _jsonString(config['path']).isEmpty
          ? '/'
          : _jsonString(config['path']);
      if (hostValues.isNotEmpty) {
        transport['headers'] = {'Host': hostValues.first};
      }
    case 'grpc':
      transport['service_name'] = _jsonString(config['serviceName']).isEmpty
          ? _jsonString(config['path'])
          : _jsonString(config['serviceName']);
    case 'http':
      transport['path'] = _jsonString(config['path']).isEmpty
          ? '/'
          : _jsonString(config['path']);
      if (hostValues.isNotEmpty) transport['host'] = hostValues;
    case 'httpupgrade':
      transport['path'] = _jsonString(config['path']).isEmpty
          ? '/'
          : _jsonString(config['path']);
      if (hostValues.isNotEmpty) transport['host'] = hostValues.first;
  }
  return transport;
}

Map<String, dynamic> _vmessOutboundFromJson(
  ProxyNode node,
  Map<String, dynamic> config,
) {
  final out = <String, dynamic>{
    'type': 'vmess',
    'server': _jsonString(config['add']).isEmpty
        ? node.server
        : _jsonString(config['add']),
    'server_port': _jsonInt(config['port'], node.port),
    'uuid': _jsonString(config['id']),
    'alter_id': _jsonInt(config['aid'], 0),
    'security': _jsonString(config['scy']).isEmpty
        ? (_jsonString(config['security']).isEmpty
              ? 'auto'
              : _jsonString(config['security']))
        : _jsonString(config['scy']),
  };
  final tls = _jsonString(config['tls']);
  if (tls == 'tls') {
    final sni = _jsonString(config['sni']).isEmpty
        ? (_jsonStringList(config['host']).isNotEmpty
              ? _jsonStringList(config['host']).first
              : node.server)
        : _jsonString(config['sni']);
    final alpnRaw = config['alpn'];
    final alpn = alpnRaw is List
        ? alpnRaw.map((e) => e.toString()).toList()
        : _csv(alpnRaw?.toString());
    final insecureField = config['allowInsecure'] ?? config['allow_insecure'];
    out['tls'] = _tlsObject(
      serverName: sni,
      alpn: alpn,
      insecure: insecureField == true,
      fingerprint: _jsonString(config['fp']).isEmpty
          ? null
          : _jsonString(config['fp']),
    );
  }
  final network = _jsonString(config['net']).isEmpty
      ? _jsonString(config['network'])
      : _jsonString(config['net']);
  final transport = _vmessTransportFromJson(network, config);
  if (transport != null) out['transport'] = transport;
  return out;
}

Map<String, dynamic> _vmessOutbound(ProxyNode node) {
  final body = node.link.substring('vmess://'.length).trim();
  if (!body.contains('@')) {
    final decoded = _decodeBase64Url(body);
    final data = jsonDecode(decoded.trimLeft());
    if (data is! Map<String, dynamic>) {
      throw const FormatException('VMess 链接解码后不是 JSON');
    }
    return _vmessOutboundFromJson(node, data);
  }
  final uri = Uri.parse(node.link);
  final out = <String, dynamic>{
    'type': 'vmess',
    'server': node.server,
    'server_port': node.port,
    'uuid': Uri.decodeComponent(uri.userInfo),
    'alter_id': 0,
    'security': _firstParam(uri, ['encryption', 'security']) ?? 'auto',
  };
  if (_firstParam(uri, ['security']) == 'tls') {
    out['tls'] = _tlsObject(
      serverName: _firstParam(uri, ['sni', 'host']) ?? node.server,
      alpn: _csv(_firstParam(uri, ['alpn'])),
      insecure: _paramEnabled(uri, [
        'allowInsecure',
        'allow_insecure',
        'insecure',
        'skip-cert-verify',
      ]),
      fingerprint: _firstParam(uri, ['fp', 'fingerprint', 'client-fingerprint']),
    );
  }
  final transport = _transportFromUri(uri);
  if (transport != null) out['transport'] = transport;
  return out;
}

Map<String, dynamic> _socksOutbound(ProxyNode node) {
  final uri = Uri.parse(node.link);
  final scheme = uri.scheme.toLowerCase();
  final version = scheme == 'socks4'
      ? '4'
      : scheme == 'socks4a'
      ? '4a'
      : '5';
  final out = <String, dynamic>{
    'type': 'socks',
    'server': node.server,
    'server_port': node.port,
    'version': version,
  };
  if (uri.userInfo.isNotEmpty) {
    final parts = Uri.decodeComponent(uri.userInfo).split(':');
    if (parts.isNotEmpty && parts.first.isNotEmpty) {
      out['username'] = parts.first;
    }
    if (parts.length > 1) out['password'] = parts.sublist(1).join(':');
  }
  return out;
}

Map<String, dynamic> _httpOutbound(ProxyNode node) {
  final uri = Uri.parse(node.link);
  final out = <String, dynamic>{
    'type': 'http',
    'server': node.server,
    'server_port': node.port,
  };
  if (uri.userInfo.isNotEmpty) {
    final parts = Uri.decodeComponent(uri.userInfo).split(':');
    if (parts.isNotEmpty && parts.first.isNotEmpty) {
      out['username'] = parts.first;
    }
    if (parts.length > 1) out['password'] = parts.sublist(1).join(':');
  }
  if (uri.scheme.toLowerCase() == 'https') {
    out['tls'] = {'enabled': true, 'server_name': node.server};
  }
  return out;
}

/// sing-box outbound JSON for one node (tag is always "proxy").
Map<String, dynamic> nodeOutbound(ProxyNode node) {
  final out = switch (node.protocol) {
    ProxyProtocol.vless => _vlessOutbound(node),
    ProxyProtocol.vmess => _vmessOutbound(node),
    ProxyProtocol.socks => _socksOutbound(node),
    ProxyProtocol.http => _httpOutbound(node),
  };
  out['tag'] = 'proxy';
  return out;
}

/// Full sing-box service config: a mixed (HTTP + SOCKS5) inbound on
/// 127.0.0.1:<[mixedPort]> and everything routed to the node.
///
/// DNS deliberately goes direct (shadiao does the same): resolving the
/// node server's own hostname through the proxy would be a bootstrap
/// loop. Content connections still go through the node; only the DNS
/// lookups for the node hostname itself use the local resolver.
String buildProxyConfig(ProxyNode node, {required int mixedPort}) {
  final config = <String, dynamic>{
    'log': {'level': 'warning'},
    'dns': {
      'servers': [
        {'tag': 'dns-direct', 'address': '223.5.5.5', 'detour': 'direct'},
        {'tag': 'dns-backup', 'address': '1.1.1.1', 'detour': 'direct'},
      ],
      'final': 'dns-direct',
    },
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      },
    ],
    'outbounds': [
      nodeOutbound(node),
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
    ],
    'route': {
      'rules': [
        {'port': 53, 'outbound': 'direct'},
      ],
      'final': 'proxy',
    },
  };
  return jsonEncode(config);
}
