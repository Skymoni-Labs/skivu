import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'native_social_media.dart';
import 'native_social_icons.dart';
import 'native_social_video_source.dart'
    if (dart.library.io) 'native_social_video_source_io.dart'
    as source;

/// Local media stays inside the chat. No autoplay, remote URLs or model calls.
class NativeSocialMediaPreview extends StatefulWidget {
  const NativeSocialMediaPreview({
    super.key,
    required this.event,
    this.expanded = false,
    this.onReady,
    this.active = true,
    this.pauseToken,
    this.createController,
  });
  final Map<String, dynamic> event;
  final bool expanded;
  final VoidCallback? onReady;
  final bool active;
  final Object? pauseToken;
  final Future<(VideoPlayerController, Future<void> Function())> Function(
    NativeChatAttachment,
  )?
  createController;
  @override
  State<NativeSocialMediaPreview> createState() =>
      _NativeSocialMediaPreviewState();
}

class _NativeSocialMediaPreviewState extends State<NativeSocialMediaPreview>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Future<void> Function()? _cleanup;
  bool _busy = false;
  String? _error;
  int _generation = 0;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _controller?.pause();
  }

  @override
  void didUpdateWidget(NativeSocialMediaPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active || oldWidget.pauseToken != widget.pauseToken)
      _controller?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _release();
    super.dispose();
  }

  Future<void> _release() async {
    final controller = _controller, cleanup = _cleanup;
    _controller = null;
    _cleanup = null;
    if (controller != null) {
      controller.removeListener(_refresh);
      await controller.dispose();
    }
    await cleanup?.call();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _play() async {
    if (_busy || !widget.active || !_foreground) return;
    final token = ++_generation;
    if (_controller != null) {
      if (_controller!.value.isPlaying) {
        await _controller!.pause();
      } else {
        if (_controller!.value.position >= _controller!.value.duration)
          await _controller!.seekTo(Duration.zero);
        await _controller!.play();
      }
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final attachment = NativeChatAttachment.parse(widget.event);
      final (controller, cleanup) =
          await (widget.createController?.call(attachment) ??
              source.socialMediaController(attachment.bytes, attachment.mime));
      if (!mounted || token != _generation) {
        await controller.dispose();
        await cleanup();
        return;
      }
      _controller = controller;
      _cleanup = cleanup;
      await controller.initialize();
      if (!mounted || token != _generation || !widget.active || !_foreground)
        return;
      controller.addListener(_refresh);
      await controller.play();
    } catch (_) {
      await _release();
      if (mounted) setState(() => _error = '此附件暂时无法内览，可使用系统打开或另存。');
    } finally {
      if (mounted && token == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = NativeChatAttachment.parse(widget.event);
    final displayName = widget.event['payload']['name'] as String? ?? data.name;
    final video = widget.event['kind'] == 'video';
    final image = widget.event['kind'] == 'image';
    if (image)
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.expanded ? 600 : 220,
          maxHeight: widget.expanded
              ? MediaQuery.sizeOf(context).height * .7
              : 280,
        ),
        child: Image.memory(
          data.bytes,
          frameBuilder: (_, child, frame, _) {
            if (frame != null) widget.onReady?.call();
            return child;
          },
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Text('图片无法显示'),
        ),
      );
    if (widget.event['kind'] == 'file') {
      return Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.all(14),
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const NativeSocialIcon(
                  'folder',
                  size: 32,
                  color: Color(0xffdbb366),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xff191919),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${(data.bytes.length / 1024).toStringAsFixed(1)} KB',
              style: const TextStyle(fontSize: 10, color: Color(0xff999999)),
            ),
            if (data.mime == 'text/plain' ||
                displayName.toLowerCase().endsWith('.txt'))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  utf8.decode(
                    data.bytes.take(widget.expanded ? 30000 : 1500).toList(),
                    allowMalformed: true,
                  ),
                  maxLines: widget.expanded ? null : 7,
                  overflow: widget.expanded ? null : TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.7,
                    color: Color(0xff191919),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final value = _controller?.value;
    return Container(
      width: widget.expanded
          ? 600
          : video
          ? 240
          : 270,
      decoration: BoxDecoration(
        color: video ? const Color(0xff222222) : Colors.white,
        borderRadius: BorderRadius.circular(video ? 8 : 6),
      ),
      padding: video
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (video)
            AspectRatio(
              aspectRatio:
                  value?.isInitialized == true && value!.aspectRatio > 0
                  ? value.aspectRatio
                  : 16 / 9,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (value?.isInitialized == true) VideoPlayer(_controller!),
                  IconButton(
                    tooltip: value?.isPlaying == true ? '暂停视频' : '播放视频',
                    onPressed: _play,
                    icon: _busy
                        ? const SizedBox(
                            width: 25,
                            height: 25,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : NativeSocialIcon(
                            value?.isPlaying == true ? 'pause' : 'play',
                            size: 32,
                            color: Colors.white,
                          ),
                  ),
                ],
              ),
            )
          else
            Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xff191919)),
            ),
          Row(
            children: [
              if (!video)
                IconButton(
                  tooltip: value?.isPlaying == true ? '暂停音频' : '播放音频',
                  onPressed: _play,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : NativeSocialIcon(
                          value?.isPlaying == true ? 'pause' : 'play',
                          size: 22,
                        ),
                ),
              Expanded(
                child: Slider(
                  value: value == null || value.duration.inMilliseconds == 0
                      ? 0
                      : value.position.inMilliseconds.clamp(
                              0,
                              value.duration.inMilliseconds,
                            ) /
                            value.duration.inMilliseconds,
                  onChanged: value?.isInitialized == true
                      ? (v) => _controller!.seekTo(
                          Duration(
                            milliseconds: (value!.duration.inMilliseconds * v)
                                .round(),
                          ),
                        )
                      : null,
                ),
              ),
              Text(
                _duration(value?.position ?? Duration.zero),
                style: TextStyle(
                  fontSize: 10,
                  color: video ? Colors.white70 : const Color(0xff777777),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: 11,
                  color: video ? Colors.white70 : const Color(0xff999999),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _duration(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}
