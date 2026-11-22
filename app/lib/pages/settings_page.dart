import 'package:flutter/material.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../ph_api.dart';
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
          '关于',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('PsexHub 0.2.0'),
        const Text('功能：首页、分类、搜索、收藏、离线下载、续播、播放器手势与倍速。'),
        const Text('不登录。视频地址 2 小时过期，每次播放都重新获取；重复打开 110 分钟内直接用缓存。'),
        const Text('首次打开需确认已满 18 岁。'),
      ],
    );
  }
}
