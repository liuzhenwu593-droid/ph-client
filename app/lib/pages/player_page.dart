import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';

import '../downloads.dart';
import '../local_store.dart';
import '../models.dart';
import '../ph_api.dart';
import '../ph_parse.dart' as direct;
import '../settings.dart';
import '../widgets/thumb_image.dart';
import '../widgets/video_list.dart';
import 'author_page.dart';

/// Playback speeds offered in the player menu (shared by the state and
/// the controls overlay below).
const _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// Video detail + player. HLS (m3u8) is played by ExoPlayer under the hood.
/// The player gets Origin + Referer headers: yt-dlp's extractor notes
/// manifest requests need them to avoid HTTP 412.
///
/// Gestures (on the video area):
/// - single tap: show/hide controls
/// - double-tap right half: forward N seconds, left half: back N seconds
///   (N = Settings "双击快进秒数", 5/10/15/30)
/// - long-press: 2x speed while held
/// - vertical swipe right side: volume, left side: brightness
/// Lock button hides and disables all of the above; only the lock icon
/// stays, tap it to unlock.
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.video,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.settings,
    required this.downloads,
    this.localFile,
  });

  final VideoItem video;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final AppSettings settings;
  final DownloadManager downloads;

  /// When set, plays this local file (an offline download) instead of
  /// fetching playable URLs. No parsing, no network.
  final File? localFile;

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
  bool _controlsVisible = true;
  bool _locked = false;
  bool _triedFresh = false;
  int _lastSecond = -1;
  int _lastRecordedSecond = -1;

  double _speed = 1.0;
  bool _longPress2x = false;
  double _volume = 1.0;
  double _brightness = 1.0;
  double? _initialBrightness;

  String? _seekFlash;
  bool _seekFlashRight = true;
  String? _swipeFlash;
  Timer? _flashTimer;
  Timer? _hideTimer;
  double? _dragStartX;
  double _dragStartVolume = 1.0;
  double _dragStartBrightness = 1.0;

  List<VideoItem> _related = [];
  bool _loadingRelated = false;

  static const _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Referer': 'https://www.pornhub.com/',
    'Origin': 'https://www.pornhub.com',
  };

  bool get _isLocal => widget.localFile != null;

  @override
  void initState() {
    super.initState();
    _initBrightness();
    _load();
  }

  Future<void> _initBrightness() async {
    try {
      _initialBrightness = await ScreenBrightness().application;
      if (mounted) setState(() => _brightness = _initialBrightness ?? 1.0);
    } catch (_) {
      // Brightness control unavailable: swipe still adjusts volume.
    }
  }

  Future<void> _load({bool fresh = false}) async {
    setState(() {
      _loadingDetail = true;
      _error = null;
    });
    try {
      if (_isLocal) {
        final ok = await _initController(
          file: widget.localFile,
          startAt: Duration.zero,
        );
        if (!mounted) return;
        setState(() => _loadingDetail = false);
        if (!ok) setState(() => _error = '本地视频打不开，可能下载不完整，请删除后重新下载');
        return;
      }
      final detail = await widget.api.video(
        widget.video.viewkey,
        forceRefresh: fresh,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loadingDetail = false;
      });
      _loadRelated();
      final start = detail.startSource ?? detail.bestSource;
      if (start != null) {
        final ok = await _initController(source: start, startAt: Duration.zero);
        if (!ok && mounted) {
          if (!_triedFresh) {
            // Cached URLs may have expired early: drop the cache and retry once.
            _triedFresh = true;
            await widget.api.invalidateVideo(widget.video.viewkey);
            await _load(fresh: true);
          } else {
            setState(() => _error = '播放器启动失败，请重试');
          }
        }
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

  Future<void> _loadRelated() async {
    final tags = widget.video.tags;
    final categories = widget.video.categories;
    final keyword = tags.isNotEmpty
        ? tags.first
        : (categories.isNotEmpty ? categories.first : '');
    if (keyword.isEmpty || _loadingRelated) return;
    _loadingRelated = true;
    try {
      final items = await widget.api.search(keyword, page: 1);
      if (!mounted) return;
      setState(() {
        _related = items
            .where((v) => v.viewkey != widget.video.viewkey)
            .take(6)
            .toList();
      });
    } catch (_) {
      // Related videos are a bonus: never fail playback for them.
    }
  }

  /// "357 Videos  •  2.1M Subscribers", or '' when neither is known.
  String _authorMeta(AuthorInfo author) {
    return [
      if (author.videosText.isNotEmpty) author.videosText,
      if (author.subscribersText.isNotEmpty) author.subscribersText,
    ].join('  •  ');
  }

  void _openAuthor(AuthorInfo author) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthorPage(
          author: author,
          api: widget.api,
          favorites: widget.favorites,
          watch: widget.watch,
          settings: widget.settings,
          downloads: widget.downloads,
        ),
      ),
    );
  }

  /// Pornstar chip (v0.2.8 bonus): the API already carries
  /// pornstars[].pornstar_name, so tapping one opens that pornstar's
  /// video list at `/pornstar/<slug>/videos`.
  void _openPornstar(String name) {
    _openAuthor(
      AuthorInfo(name: name, path: '/pornstar/${direct.pornstarSlug(name)}'),
    );
  }

  /// Creates and initialises a controller. Returns true on success.
  /// On failure the old controller keeps playing untouched.
  Future<bool> _initController({
    VideoSource? source,
    File? file,
    required Duration startAt,
  }) async {
    final controller = file != null
        ? VideoPlayerController.file(file)
        : VideoPlayerController.networkUrl(
            Uri.parse(source!.url),
            httpHeaders: _headers,
          );
    controller.addListener(_onTick);
    final previous = _controller;
    setState(() {
      _controller = controller;
      if (source != null) _currentSource = source;
      _initializing = true;
    });
    try {
      await controller.initialize();
      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_speed);
      Duration resumeAt = startAt;
      if (resumeAt == Duration.zero) {
        final resume = widget.watch.resumeFor(widget.video.viewkey);
        if (resume != null && resume.canResume) {
          resumeAt = Duration(seconds: resume.positionSec);
        }
      }
      if (resumeAt > Duration.zero) {
        await controller.seekTo(resumeAt);
      }
      await controller.play();
      if (resumeAt > Duration.zero && mounted) {
        _showResumeSnack(resumeAt);
      }
      if (previous != null) {
        previous.removeListener(_onTick);
        await previous.dispose();
      }
      if (!mounted) return true;
      setState(() => _initializing = false);
      _resetHideTimer();
      return true;
    } catch (e) {
      controller.removeListener(_onTick);
      await controller.dispose();
      if (!mounted) return false;
      // Keep the previous controller on screen.
      setState(() {
        _controller = previous;
        _initializing = false;
      });
      return false;
    }
  }

  void _showResumeSnack(Duration at) {
    final label =
        '${at.inMinutes.toString().padLeft(2, '0')}:${(at.inSeconds % 60).toString().padLeft(2, '0')}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已从 $label 继续播放'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '从头开始',
          onPressed: () {
            _controller?.seekTo(Duration.zero);
            _recordPosition(force: true);
          },
        ),
      ),
    );
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final second = controller.value.position.inSeconds;
    if (second != _lastSecond) {
      _lastSecond = second;
      if (mounted) setState(() {});
      if (second % 10 == 0 && second != _lastRecordedSecond) {
        _recordPosition();
      }
    }
  }

  void _recordPosition({bool force = false}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final position = controller.value.position.inSeconds;
    if (!force && position == _lastRecordedSecond) return;
    _lastRecordedSecond = position;
    final duration = controller.value.duration.inSeconds;
    widget.watch.record(widget.video, position, duration);
  }

  Future<void> _switchQuality(VideoSource source) async {
    if (_currentSource?.url == source.url) return;
    final position = _controller?.value.position ?? Duration.zero;
    final ok = await _initController(source: source, startAt: position);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${source.label} 暂时播不了，已保持当前清晰度')));
    }
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    await _controller?.setPlaybackSpeed(speed);
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
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

  void _resetHideTimer() {
    _hideTimer?.cancel();
    final controller = _controller;
    if (controller != null && controller.value.isPlaying && _controlsVisible) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && !_locked) setState(() => _controlsVisible = false);
      });
    }
  }

  void _showFlash(String text, {bool right = true}) {
    _flashTimer?.cancel();
    setState(() {
      _seekFlash = text;
      _seekFlashRight = right;
      _swipeFlash = null;
    });
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFlash = null);
    });
  }

  void _showSwipeFlash(String text) {
    _flashTimer?.cancel();
    setState(() {
      _swipeFlash = text;
      _seekFlash = null;
    });
    _flashTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _swipeFlash = null);
    });
  }

  Future<void> _seekBy(int seconds) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = controller.value.position + Duration(seconds: seconds);
    final duration = controller.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (duration != Duration.zero && target > duration ? duration : target);
    await controller.seekTo(clamped);
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_locked) return;
    final width = context.size?.width ?? 0;
    final step = widget.settings.seekSeconds;
    if (details.localPosition.dx > width / 2) {
      _seekBy(step);
      _showFlash('+$step 秒', right: true);
    } else {
      _seekBy(-step);
      _showFlash('-$step 秒', right: false);
    }
  }

  void _onLongPressStart(LongPressStartDetails _) async {
    if (_locked) return;
    _longPress2x = true;
    await _controller?.setPlaybackSpeed(2.0);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('长按 2 倍速播放中'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _onLongPressEnd(LongPressEndDetails _) async {
    if (!_longPress2x) return;
    _longPress2x = false;
    await _controller?.setPlaybackSpeed(_speed);
    if (mounted) setState(() {});
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_locked) return;
    _dragStartX = details.localPosition.dx;
    _dragStartVolume = _volume;
    _dragStartBrightness = _brightness;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_locked || _dragStartX == null) return;
    final width = context.size?.width ?? 1;
    final delta = -details.delta.dy * 0.005;
    if (_dragStartX! > width / 2) {
      _volume = (_dragStartVolume + delta).clamp(0.0, 1.0);
      _controller?.setVolume(_volume);
      _showSwipeFlash('音量 ${(_volume * 100).round()}%');
    } else {
      _brightness = (_dragStartBrightness + delta).clamp(0.1, 1.0);
      ScreenBrightness()
          .setApplicationScreenBrightness(_brightness)
          .catchError((_) {});
      _showSwipeFlash('亮度 ${(_brightness * 100).round()}%');
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleLock() async {
    setState(() {
      _locked = !_locked;
      if (_locked) _controlsVisible = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locked ? '已锁定，点右上角锁图标解锁' : '已解锁'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _download() async {
    final detail = _detail;
    if (detail == null || detail.hlsSources.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('还没有可下载的地址，请等视频加载出来')));
      return;
    }
    if (widget.downloads.isDownloaded(widget.video.viewkey)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已下载，可在设置 - 我的下载里查看')));
      return;
    }
    if (widget.downloads.hasActiveDownload) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已有下载进行中，完成后才能下载下一个')));
      return;
    }
    final chosen = await showDialog<VideoSource>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('下载画质'),
        children: detail.hlsSources
            .map(
              (s) => SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(s),
                child: Text(
                  '${s.label}${_currentSource?.url == s.url ? '（当前）' : ''}',
                ),
              ),
            )
            .toList(),
      ),
    );
    if (chosen == null) return;
    final started = await widget.downloads.startDownload(widget.video, chosen);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started ? '开始下载 ${chosen.label}，后台进行中' : '下载没开始：已有下载进行中或已下载',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _recordPosition(force: true);
    if (_initialBrightness != null) {
      ScreenBrightness()
          .setApplicationScreenBrightness(_initialBrightness!)
          .catchError((_) {});
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      controller.dispose();
    }
    super.dispose();
  }

  Widget _buildVideoStack() {
    final controller = _controller;
    final child = _loadingDetail
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在获取播放地址…', style: TextStyle(color: Colors.white70)),
              ],
            ),
          )
        : _error != null && controller == null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 40,
                    color: Colors.white70,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => _load(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          )
        : controller != null && controller.value.isInitialized
        ? Stack(
            alignment: Alignment.center,
            children: [
              AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
              if (_seekFlash != null)
                Positioned(
                  left: _seekFlashRight ? null : 48,
                  right: _seekFlashRight ? 48 : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      _seekFlash!,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              if (_swipeFlash != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      _swipeFlash!,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              if (_controlsVisible &&
                  !_locked &&
                  controller.value.isInitialized)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _ControlsOverlay(
                    controller: controller,
                    speed: _longPress2x ? 2.0 : _speed,
                    onSpeedChanged: _setSpeed,
                    onFullscreen: _toggleFullscreen,
                    isFullscreen: _isFullscreen,
                    onLock: _toggleLock,
                  ),
                ),
              if (_locked)
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.lock, color: Colors.white),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                    ),
                    onPressed: _toggleLock,
                    tooltip: '解锁',
                  ),
                ),
            ],
          )
        : const Center(child: CircularProgressIndicator());

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_locked) return;
        setState(() => _controlsVisible = !_controlsVisible);
        _resetHideTimer();
      },
      onDoubleTapDown: _onDoubleTapDown,
      onLongPressStart: _onLongPressStart,
      onLongPressEnd: _onLongPressEnd,
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      child: Container(
        color: Colors.black,
        child: AspectRatio(aspectRatio: 16 / 9, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final author = detail?.author;
    final controller = _controller;

    if (_isFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: Center(child: _buildVideoStack())),
      );
    }

    final isFav = widget.favorites.isFavorite(widget.video.viewkey);
    final body = ListView(
      children: [
        _buildVideoStack(),
        if (_initializing) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      detail?.title ?? widget.video.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav ? Colors.amber : null,
                    ),
                    tooltip: isFav ? '取消收藏' : '收藏',
                    onPressed: () async {
                      await widget.favorites.toggle(widget.video);
                      if (mounted) setState(() {});
                    },
                  ),
                  if (!_isLocal)
                    IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: '下载离线看',
                      onPressed: _download,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.video.viewsLabel}'
                '${widget.video.rating > 0 ? '  •  ${widget.video.rating.toStringAsFixed(0)}% 好评' : ''}'
                '${detail != null && detail.durationLabel.isNotEmpty ? '  •  ${detail.durationLabel}' : ''}'
                '${_isLocal ? '  •  本地视频' : ''}',
                style: TextStyle(color: Colors.grey.shade400),
              ),
              // Author row (v0.2.8): from the detail page's about tab.
              // Hidden when the detail has no author (backend, old
              // cache, or a page without the block) — never a crash.
              if (author != null) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => _openAuthor(author),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        if (author.avatarUrl.isNotEmpty)
                          ClipOval(
                            child: ThumbImage(
                              url: author.avatarUrl,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              compact: true,
                            ),
                          )
                        else
                          const CircleAvatar(
                            radius: 20,
                            child: Icon(Icons.person),
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                author.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_authorMeta(author).isNotEmpty)
                                Text(
                                  _authorMeta(author),
                                  style: TextStyle(
                                    color: Colors.grey.shade400,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
              ],
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
                          .map(
                            (s) => PopupMenuItem(
                              value: s,
                              child: Text(
                                '${s.label}${s.isDefault ? '（默认）' : ''}',
                              ),
                            ),
                          )
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
                      .map(
                        (t) => Chip(
                          label: Text(t),
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                      .toList(),
                ),
              ],
              // Performers (v0.2.8 bonus): only API-sourced videos carry
              // pornstars; site-parsed lists leave this empty and the
              // row is simply hidden. Tapping one opens that
              // pornstar's video list.
              if (widget.video.pornstars.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.video.pornstars
                      .take(8)
                      .map(
                        (p) => ActionChip(
                          avatar: const Icon(Icons.person, size: 16),
                          label: Text(p),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _openPornstar(p),
                        ),
                      )
                      .toList(),
                ),
              ],
              if (_error != null && controller != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              if (_related.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text(
                  '相关视频',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ..._related.map(
                  (video) => VideoCard(
                    video: video,
                    onTap: () {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => PlayerPage(
                            video: video,
                            api: widget.api,
                            favorites: widget.favorites,
                            watch: widget.watch,
                            settings: widget.settings,
                            downloads: widget.downloads,
                          ),
                        ),
                      );
                    },
                    isFavorite: widget.favorites.isFavorite(video.viewkey),
                    onToggleFavorite: () async {
                      await widget.favorites.toggle(video);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: Text(_isLocal ? '本地播放' : '播放')),
      body: body,
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.speed,
    required this.onSpeedChanged,
    required this.onFullscreen,
    required this.isFullscreen,
    required this.onLock,
  });

  final VideoPlayerController controller;
  final double speed;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onFullscreen;
  final bool isFullscreen;
  final VoidCallback onLock;

  String _format(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final position = controller.value.position;
    final duration = controller.value.duration;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                _format(position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(width: 6),
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
              const SizedBox(width: 6),
              Text(
                _format(duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          Row(
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
              PopupMenuButton<double>(
                initialValue: speed,
                onSelected: onSpeedChanged,
                itemBuilder: (context) => _speedOptions
                    .map((s) => PopupMenuItem(value: s, child: Text('${s}x')))
                    .toList(),
                child: Chip(
                  label: Text('${speed}x'),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.lock_outline, color: Colors.white),
                tooltip: '锁屏防误触',
                onPressed: onLock,
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
        ],
      ),
    );
  }
}
