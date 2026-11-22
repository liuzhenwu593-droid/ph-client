import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'thumb_image.dart';
import '../proxy_client.dart';
import '../proxy_relay.dart';

/// Headers for preview clip requests (same browser headers as thumbs
/// and the player; clips return 200 with or without Referer, verified
/// live 2026-11-22 — the headers are belt and braces).
const _previewHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  'Referer': 'https://www.pornhub.com/',
};

/// Auto-playing muted preview for one video card (v0.2.2, mobile-site
/// style). The cover stays underneath as the poster; the clip fades in
/// once initialized and loops silently. Any failure (bad URL, expired
/// signature, no network) silently leaves the cover — a preview is a
/// bonus, never an error state. Deliberately touches no history or
/// resume state: previewing is not watching the video.
class PreviewPlayer extends StatefulWidget {
  const PreviewPlayer({
    super.key,
    required this.previewUrl,
    required this.thumbUrl,
    this.onRefreshThumb,
  });

  final String previewUrl;
  final String thumbUrl;
  final Future<String?> Function()? onRefreshThumb;

  @override
  State<PreviewPlayer> createState() => _PreviewPlayerState();
}

class _PreviewPlayerState extends State<PreviewPlayer> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // v0.2.5: previews go through the loopback relay when the proxy is
    // on (ExoPlayer has no proxy setting); direct otherwise.
    final playUrl = ProxyHttp.enabled
        ? ProxyRelay.instance.mediaUrl(widget.previewUrl)
        : widget.previewUrl;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(playUrl),
      httpHeaders: _previewHeaders,
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (_disposed) return;
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      if (_disposed || !mounted) return;
      setState(() => _ready = true);
    } catch (_) {
      // Preview failed: leave the cover showing.
      if (!_disposed) {
        if (_controller == controller) _controller = null;
        await controller.dispose();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        ThumbImage(
          url: widget.thumbUrl,
          fit: BoxFit.cover,
          width: double.infinity,
          onRefreshUrl: widget.onRefreshThumb,
        ),
        if (_ready && controller != null)
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          ),
      ],
    );
  }
}
