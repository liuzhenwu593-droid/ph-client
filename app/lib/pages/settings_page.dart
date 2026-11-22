import 'dart:async';

import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../ph_api.dart';
import '../proxy_manager.dart';
import '../proxy_node.dart';
import '../settings.dart';
import 'downloads_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.api,
    required this.onBackendChanged,
    required this.favorites,
    required this.watch,
    required this.downloads,
  });

  final AppSettings settings;
  final PhApi api;
  final void Function(String url) onBackendChanged;
  final FavoritesStore favorites;
  final WatchStore watch;
  final DownloadManager downloads;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settings.backendUrl,
  );
  String? _testResult;
  bool _testing = false;

  // In-app proxy (v0.2.5).
  late final TextEditingController _nodeController = TextEditingController();
  String? _nodeError;

  ProxyManager get _proxy => ProxyManager.instance;

  @override
  void initState() {
    super.initState();
    _proxy.addListener(_onProxyChanged);
  }

  void _onProxyChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _proxy.removeListener(_onProxyChanged);
    _controller.dispose();
    _nodeController.dispose();
    super.dispose();
  }

  Future<void> _addNode() async {
    final link = _nodeController.text.trim();
    if (link.isEmpty) {
      setState(() => _nodeError = '先粘贴一个节点链接');
      return;
    }
    try {
      await _proxy.addNode(link);
      if (!mounted) return;
      setState(() {
        _nodeError = null;
        _nodeController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('节点已添加')),
      );
    } on FormatException catch (e) {
      if (mounted) setState(() => _nodeError = e.message);
    } catch (e) {
      if (mounted) setState(() => _nodeError = e.toString());
    }
  }

  Future<void> _deleteNode(ProxyNode node) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除节点？'),
        content: Text('删除 ${node.name}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _proxy.removeNode(node.id);
  }

  String _latencyText(ProxyNode node) {
    if (_proxy.testingIds.contains(node.id)) return '测速中…';
    final ms = node.lastLatencyMs;
    if (ms == null) return '未测';
    if (ms < 0) return '超时';
    return '$ms ms';
  }

  String _proxyStatusText() {
    switch (_proxy.status) {
      case ProxyStatus.off:
        return '未开启';
      case ProxyStatus.starting:
        return '启动中…';
      case ProxyStatus.running:
        return '运行中：${_proxy.currentNode?.name ?? ''}';
      case ProxyStatus.error:
        return '启动失败：${_proxy.errorMessage ?? '未知错误'}';
    }
  }

  Future<void> _save() async {
    final url = _controller.text.trim();
    await widget.settings.setBackendUrl(url);
    widget.onBackendChanged(url);
    if (!mounted) return;
    setState(() => _testResult = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(url.isEmpty ? '已切换为 App 内嵌解析（无需后端）' : '后端地址已保存：$url'),
      ),
    );
  }

  Future<void> _test() async {
    final url = _controller.text.trim();
    if (url.isEmpty) {
      setState(() => _testResult = '没有填后端地址，当前用 App 内嵌解析。');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    widget.api.setBackendUrl(url);
    final ok = await widget.api.testBackend();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = ok ? '后端连通：$url' : '后端连不通，请检查地址或稍后再试';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '双击快进秒数',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('播放时双击左/右半屏快退/快进的时间。'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: AppSettings.seekOptions.map((seconds) {
            final selected = widget.settings.seekSeconds == seconds;
            return ChoiceChip(
              label: Text('$seconds 秒'),
              selected: selected,
              onSelected: (_) async {
                await widget.settings.setSeekSeconds(seconds);
                if (mounted) setState(() {});
              },
            );
          }).toList(),
        ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download),
          title: const Text('我的下载'),
          subtitle: const Text('离线视频管理：播放、删除'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DownloadsPage(
                  api: widget.api,
                  favorites: widget.favorites,
                  watch: widget.watch,
                  settings: widget.settings,
                  downloads: widget.downloads,
                ),
              ),
            );
          },
        ),
        const Divider(height: 32),
        const Text(
          '后端地址',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          '留空 = App 内嵌解析，直接连 Pornhub，装上就能播，不用搭服务器。'
          '填入后端地址后 App 优先走后端（改版后只改后端，不用重新发包）；'
          '后端连不上时自动回落到内嵌解析。',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://ph-parser-xxxx.cloady.io',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(onPressed: _save, child: const Text('保存')),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _testing ? null : _test,
              child: Text(_testing ? '测试中…' : '测试连接'),
            ),
          ],
        ),
        if (_testResult != null) ...[
          const SizedBox(height: 12),
          Text(_testResult!),
        ],
        const Divider(height: 32),
        const Text(
          'App 内代理',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          '只代理本 App 的流量（列表、搜索、封面、预览、视频、下载），'
          '不用系统 VPN 权限，可与沙雕 VPN 同时开。'
          '节点存在本机，不会上传。开启后不经过代理的流量一律报错，'
          '不会悄悄直连。',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('开启代理'),
          subtitle: Text(
            _proxyStatusText(),
            style: TextStyle(
              color: _proxy.status == ProxyStatus.error ? Colors.red : null,
            ),
          ),
          value: _proxy.enabled,
          onChanged: (value) async {
            await _proxy.setEnabled(value);
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nodeController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '粘贴 vless:// / vmess:// / socks:// 链接',
            border: OutlineInputBorder(),
          ),
        ),
        if (_nodeError != null) ...[
          const SizedBox(height: 8),
          Text(_nodeError!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: _addNode,
              child: const Text('添加节点'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _proxy.testingAll || _proxy.nodes.isEmpty
                  ? null
                  : () => unawaited(_proxy.testAll()),
              child: Text(_proxy.testingAll ? '测速中…' : '全部测速'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_proxy.nodes.isEmpty)
          const Text('还没有节点：粘贴一个 vless:// 或 vmess:// 链接添加。')
        else
          ..._proxy.nodes.map((node) {
            final selected = node.id == _proxy.currentId;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? Colors.amber : null,
              ),
              title: Text(node.name),
              subtitle: Text(
                '${node.protocol.name}  ${node.server}:${node.port}'
                '  ·  ${_latencyText(node)}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _proxy.testingIds.contains(node.id)
                        ? null
                        : () => unawaited(_proxy.testLatency(node)),
                    child: const Text('测速'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除节点',
                    onPressed: () => _deleteNode(node),
                  ),
                ],
              ),
              onTap: () => unawaited(_proxy.selectNode(node.id)),
            );
          }),
        const Divider(height: 32),
        const Text(
          '关于',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('PsexHub 0.2.5'),
        const Text('功能：首页、分类、搜索、收藏、离线下载、续播、播放器手势与倍速。'),
        const Text('不登录。视频地址 2 小时过期，每次播放都重新获取；重复打开 110 分钟内直接用缓存。'),
        const Text('首次打开需确认已满 18 岁。'),
      ],
    );
  }
}
