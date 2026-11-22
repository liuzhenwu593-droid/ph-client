import 'package:flutter/material.dart';

import '../ph_api.dart';
import '../settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.api,
    required this.onBackendChanged,
  });

  final AppSettings settings;
  final PhApi api;
  final void Function(String url) onBackendChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.settings.backendUrl);
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
        content: Text(
          url.isEmpty ? '已切换为 App 内嵌解析（无需后端）' : '后端地址已保存：$url',
        ),
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
        const Text('PH Player 0.1.0（最小版）'),
        const Text('功能：首页、搜索、播放。不登录、不下载、不收藏。'),
        const Text('首次打开需确认已满 18 岁。'),
        const Text('视频地址 2 小时过期，每次播放都重新获取。'),
      ],
    );
  }
}
