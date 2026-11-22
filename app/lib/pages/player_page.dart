import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../ph_api.dart';

/// Video detail + player. HLS (m3u8) is played by ExoPlayer under the hood.
/// The player gets Origin + Referer headers: yt-dlp's extractor notes
/// manifest requests need them to avoid HTTP 412.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.video, required this.api});

  final VideoItem video;
  final PhApi api;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoDetail? _detail;
  VideoPlayerController? _controller;
  VideoSource? _currentSource;
  String? _error;
  bool _loadingDetail = true;
  bool _initializing = false;
  bool _isFullscreen = false;
  int _lastSecond = -1;

  static const _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Referer': 'https://www.pornhub.com/',
    'Origin': 'https://www.pornhub.com',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadingDetail = true;
      _error = null;
    });
    try {
      final detail = await widget.api.video(widget.video.viewkey);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loadingDetail = false;
      });
      final best = detail.bestSource;
      if (best != null) {
        await _initController(best, startAt: Duration.zero);
      } else {
        setState(() => _error = '这个视频没有可播放的地址');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDetail = false;
        _error = '播放地址获取失败：$e';
      });
    }
  }

  Future<void> _initController(VideoSource source, {required Duration startAt}) async {
    // Swap first, dispose old afterwards: the VideoPlayer widget must stop
    // referencing the old controller before it is disposed.
    final old = _controller;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(source.url),
      httpHeaders: _headers,
    );
    controller.addListener(_onTick);
    setState(() {
      _controller = controller;
      _currentSource = source;
      _initializing = true;
    });
    try {
      await controller.initialize();
      if (startAt > Duration.zero) {
        await controller.seekTo(startAt);
      }
      await controller.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '播放器启动失败：$e');
    }
    if (old != null) {
      old.removeListener(_onTick);
      await old.dispose();
    }
    if (!mounted) return;
    setState(() => _initializing = false);
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final second = controller.value.position.inSeconds;
    if (second != _lastSecond) {
      _lastSecond = second;
      if (mounted) setState(() {});
    }
  }

  Future<void> _switchQuality(VideoSource source) async {
    if (_currentSource?.url == source.url) return;
    final position = _controller?.value.position ?? Duration.zero;
    await _initController(source, startAt: position);
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    setState(() => _isFullscreen = !_isFullscreen);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final detail = _detail;
    final videoArea = _loadingDetail
        ? const AspectRatio(
            aspectRatio: 16 / 9,
            child: Center(child: CircularProgressIndicator()),
          )
        : _error != null && controller == null
            ? AspectRatio(
                aspectRatio: 16 / 9,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 40),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : controller != null && controller.value.isInitialized
                ? AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        VideoPlayer(controller),
                        _ControlsOverlay(
                          controller: controller,
                          onFullscreen: _toggleFullscreen,
                          isFullscreen: _isFullscreen,
                        ),
                      ],
                    ),
                  )
                : const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(child: CircularProgressIndicator()),
                  );

    final body = ListView(
      children: [
        videoArea,
        if (_initializing)
          const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detail?.title ?? widget.video.title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.video.viewsLabel}'
                '${widget.video.rating > 0 ? '  •  ${widget.video.rating.toStringAsFixed(0)}% 好评' : ''}'
                '${detail != null && detail.durationLabel.isNotEmpty ? '  •  ${detail.durationLabel}' : ''}',
                style: TextStyle(color: Colors.grey.shade400),
              ),
              if (detail != null && detail.sources.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('清晰度：'),
                    const SizedBox(width: 8),
                    PopupMenuButton<VideoSource>(
                      initialValue: _currentSource,
                      onSelected: _switchQuality,
                      itemBuilder: (context) => detail.hlsSources
                          .map((s) => PopupMenuItem(
                                value: s,
                                child: Text(
                                    '${s.label}${s.isDefault ? '（默认）' : ''}'),
                              ))
                          .toList(),
                      child: Chip(
                        label: Text(_currentSource?.label ?? '选择'),
                        deleteIcon: const Icon(Icons.arrow_drop_down, size: 18),
                        onDeleted: () {},
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.video.tags.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.video.tags
                      .take(12)
                      .map((t) => Chip(
                            label: Text(t),
                            visualDensity: VisualDensity.compact,
                          ))
                      .toList(),
                ),
              ],
              if (_error != null && controller != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ],
    );

    if (_isFullscreen) {
      return Scaffold(body: SafeArea(child: body));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('播放')),
      body: body,
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.onFullscreen,
    required this.isFullscreen,
  });

  final VideoPlayerController controller;
  final VoidCallback onFullscreen;
  final bool isFullscreen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
            onPressed: () {
              if (controller.value.isPlaying) {
                controller.pause();
              } else {
                controller.play();
              }
            },
          ),
          Expanded(
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Colors.redAccent,
                bufferedColor: Colors.white38,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            onPressed: onFullscreen,
          ),
        ],
      ),
    );
  }
}
