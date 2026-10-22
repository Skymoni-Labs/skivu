import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'appearance.dart';
import 'video_source.dart'
    if (dart.library.io) 'video_source_io.dart'
    as source;

class VideoBackdrop extends StatefulWidget {
  const VideoBackdrop({
    super.key,
    required this.id,
    required this.paused,
    required this.fallback,
    this.onReady,
    this.createController,
  });
  final String id;
  final bool paused;
  final Widget fallback;
  final VoidCallback? onReady;
  final Future<VideoPlayerController> Function(String)? createController;
  @override
  State<VideoBackdrop> createState() => _VideoBackdropState();
}

class _VideoBackdropState extends State<VideoBackdrop>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  bool _error = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final old = _player;
    old?.removeListener(_checkPlaybackError);
    _player = null;
    _error = false;
    await old?.dispose();
    VideoPlayerController? next;
    try {
      next = widget.createController == null
          ? source.videoController(await appearanceAssets.videoUri(widget.id))
          : await widget.createController!(widget.id);
      await next.initialize();
      await next.setVolume(0);
      await next.setLooping(true);
      if (!mounted || generation != _generation) {
        await next.dispose();
        return;
      }
      _player = next;
      next.addListener(_checkPlaybackError);
      _playback();
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) widget.onReady?.call();
      });
    } catch (_) {
      await next?.dispose();
      if (mounted && generation == _generation) setState(() => _error = true);
    }
  }

  void _checkPlaybackError() {
    if (mounted && _player?.value.hasError == true && !_error)
      setState(() => _error = true);
  }

  void _playback() {
    final player = _player;
    if (player == null) return;
    if (widget.paused ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      player.pause();
    } else {
      player.play();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _playback();
  @override
  void didUpdateWidget(covariant VideoBackdrop old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      _load();
    } else if (old.paused != widget.paused) {
      _playback();
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _player?.removeListener(_checkPlaybackError);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player == null || _error)
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.fallback,
          if (_error)
            const Center(
              child: Text('背景视频无法播放，请在外观设置中重新选择。', textAlign: TextAlign.center),
            ),
        ],
      );
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: player.value.size.width,
            height: player.value.size.height,
            child: VideoPlayer(player),
          ),
        ),
      ),
    );
  }
}
