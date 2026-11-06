import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'chat_message_dial_model.dart';

/// History chrome only loads lightweight local previews while held.
class ChatMessageDial extends StatefulWidget {
  const ChatMessageDial({
    super.key,
    required this.visible,
    required this.viewportHeight,
    required this.currentTimestamp,
    required this.loadEntries,
    required this.onOpenLocator,
    required this.onJump,
    required this.onHidden,
    required this.senderName,
    this.onLatest,
    this.showLatest = false,
    this.resolveCurrentTimestamp,
  });
  final bool visible, showLatest;
  final double viewportHeight;
  final int? currentTimestamp;
  // Resolving the nearest message can walk layout boxes. Do it only on hold.
  final int? Function()? resolveCurrentTimestamp;
  final Future<List<ChatMessageLocatorPreview>> Function() loadEntries;
  final VoidCallback onOpenLocator, onHidden;
  final VoidCallback? onLatest;
  final ValueChanged<int> onJump;
  final String Function(String) senderName;
  @override
  State<ChatMessageDial> createState() => _ChatMessageDialState();
}

class _ChatMessageDialState extends State<ChatMessageDial> {
  final _surfaceKey = GlobalKey();
  Timer? _lingerTimer, _edgeTimer;
  bool _holding = false, _pressed = false, _linger = false, _loading = false;
  int _generation = 0;
  MessageRuler? _ruler;
  List<ChatMessageLocatorPreview> _entries = const [];
  Offset _pointer = Offset.zero;
  double _lastY = 0, _buttonX = 0, _top = 0, _bottom = 0;
  Offset _local(Offset global) =>
      (_surfaceKey.currentContext!.findRenderObject() as RenderBox)
          .globalToLocal(global);
  Future<void> _start(LongPressStartDetails event) async {
    final generation = ++_generation;
    _lingerTimer?.cancel();
    _pointer = _local(event.globalPosition);
    _lastY = _pointer.dy;
    final timestamp =
        widget.resolveCurrentTimestamp?.call() ?? widget.currentTimestamp;
    setState(() {
      _holding = true;
      _linger = false;
      _loading = true;
      _ruler = null;
    });
    try {
      final entries = await widget.loadEntries();
      if (!mounted || !_holding || generation != _generation) return;
      final index = entries.indexWhere((entry) => entry.timestamp == timestamp);
      setState(() {
        _entries = entries;
        _loading = false;
        _lastY = _pointer.dy;
        if (entries.isNotEmpty)
          _ruler = MessageRuler(
            count: entries.length,
            index: math.max(0, index),
          );
      });
      _edgeTimer?.cancel();
      _edgeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        if (!mounted || !_holding || _ruler == null) return;
        final direction = _pointer.dy < _top + 12
            ? -1
            : _pointer.dy > _bottom - 12
            ? 1
            : 0;
        if (direction == 0) return;
        final before = _ruler!.position;
        _ruler!.advance(direction * math.max(1, _entries.length / 200));
        if (before != _ruler!.position) setState(() {});
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _end(cancel: true);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('暂时无法读取消息')));
    }
  }

  void _move(LongPressMoveUpdateDetails event) {
    if (!_holding) return;
    _pointer = _local(event.globalPosition);
    if (!_loading && _ruler != null) {
      setState(
        () => _ruler!.move(
          _pointer.dy - _lastY,
          leftwardDistance: _buttonX - _pointer.dx,
          extent: _bottom - _top,
        ),
      );
    }
    _lastY = _pointer.dy;
  }

  void _end({bool cancel = false}) {
    if (!_holding) return;
    final target = _ruler == null ? null : _entries[_ruler!.index].timestamp;
    _generation++;
    _edgeTimer?.cancel();
    setState(() {
      _holding = false;
      _loading = false;
      _linger = true;
      _ruler = null;
      _entries = const [];
    });
    widget.onHidden();
    if (!cancel && target != null) widget.onJump(target);
    _lingerTimer?.cancel();
    _lingerTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _linger = false);
    });
  }

  @override
  void dispose() {
    _generation++;
    _lingerTimer?.cancel();
    _edgeTimer?.cancel();
    super.dispose();
  }

  Widget _surface({
    required Key key,
    required ColorScheme colors,
    required Widget child,
  }) => ClipOval(
    key: key,
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Material(
          color: colors.surfaceContainerHighest.withValues(alpha: .58),
          shape: CircleBorder(
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .12),
            ),
          ),
          child: child,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, bounds) {
        final y = (widget.viewportHeight - 88)
            .clamp(84.0, math.max(84.0, bounds.maxHeight - 88))
            .toDouble();
        _buttonX = bounds.maxWidth - 26;
        _top = math.min(104.0, math.max(12.0, bounds.maxHeight * .18));
        _bottom = math.max(_top + 24, bounds.maxHeight - 10);
        final marker = _pointer.dy.clamp(_top, _bottom).toDouble();
        final entry = _ruler == null ? null : _entries[_ruler!.index];
        final maxPreviewHeight = math.min(
          180.0,
          math.max(0.0, bounds.maxHeight - 24),
        );
        return Stack(
          key: _surfaceKey,
          fit: StackFit.expand,
          children: [
            if (!_holding &&
                widget.onLatest != null &&
                (widget.visible || widget.showLatest))
              Positioned(
                key: const ValueKey('chat-latest-control-anchor'),
                right: 4,
                top: y + 30,
                child: SizedBox(
                  key: const ValueKey('chat-jump-latest'),
                  width: 44,
                  height: 44,
                  child: Center(
                    child: _surface(
                      key: const ValueKey('chat-message-latest-surface'),
                      colors: colors,
                      child: IconButton(
                        tooltip: '回到底部',
                        onPressed: widget.onLatest,
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.standard,
                        ),
                        icon: const Icon(
                          Icons.keyboard_double_arrow_down_rounded,
                        ),
                        color: colors.primary.withValues(alpha: .92),
                        iconSize: 24,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_holding) ...[
              Positioned(
                key: const ValueKey('chat-ruler-track-anchor'),
                right: 8,
                top: _top,
                bottom: math.max(0, bounds.maxHeight - _bottom),
                width: 32,
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('chat-message-ruler'),
                    painter: _MessageRulerPainter(
                      position: _ruler?.position ?? 0,
                      count: _entries.length,
                      marker: marker - _top,
                    ),
                  ),
                ),
              ),
              Positioned(
                key: const ValueKey('chat-ruler-preview-anchor'),
                right: 52,
                left: math.max(8, bounds.maxWidth - 292),
                top: (marker - 56)
                    .clamp(
                      8.0,
                      math.max(8, bounds.maxHeight - maxPreviewHeight - 8),
                    )
                    .toDouble(),
                child: IgnorePointer(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxPreviewHeight),
                    child: Material(
                      key: const ValueKey('chat-message-ruler-target'),
                      color: const Color(0xff242b35).withValues(alpha: .96),
                      borderRadius: BorderRadius.circular(13),
                      elevation: 3,
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_loading)
                                const Text(
                                  '正在读取',
                                  style: TextStyle(color: Color(0xffedf3fc)),
                                )
                              else if (entry == null)
                                const Text(
                                  '没有匹配的消息',
                                  style: TextStyle(color: Color(0xffedf3fc)),
                                )
                              else ...[
                                Text(
                                  '${(_ruler!.index) + 1} / ${_entries.length} · ${widget.senderName(entry.sender)}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: Color(0xffbbcadb),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  entry.previewContent,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: Color(0xfff3f6fc),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '上下拖动查看 · 松开定位',
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1.4,
                                    color: Color(0xffb7c7db),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (widget.visible || _pressed || _holding || _linger)
              Positioned(
                key: const ValueKey('chat-history-control-anchor'),
                right: 4,
                top: y - 22,
                width: 44,
                height: 44,
                child: Semantics(
                  label: '历史消息：长按并上下拖动查看',
                  button: true,
                  customSemanticsActions: {
                    CustomSemanticsAction(label: '搜索历史消息'):
                        widget.onOpenLocator,
                  },
                  child: Listener(
                    onPointerDown: (_) => setState(() => _pressed = true),
                    onPointerUp: (_) => setState(() => _pressed = false),
                    onPointerCancel: (_) {
                      setState(() => _pressed = false);
                      _end(cancel: true);
                    },
                    child: GestureDetector(
                      key: const ValueKey('chat-message-navigation-ball'),
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: _start,
                      onLongPressMoveUpdate: _move,
                      onLongPressEnd: (_) => _end(),
                      onLongPressCancel: () => _end(cancel: true),
                      child: Opacity(
                        opacity: _holding ? 0 : 1,
                        child: Center(
                          child: _surface(
                            key: const ValueKey('chat-message-history-surface'),
                            colors: colors,
                            child: Icon(
                              Icons.keyboard_arrow_left_rounded,
                              size: 28,
                              color: colors.primary.withValues(alpha: .92),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MessageRulerPainter extends CustomPainter {
  const _MessageRulerPainter({
    required this.position,
    required this.count,
    required this.marker,
  });
  final double position, marker;
  final int count;
  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 9.0;
    final selected = position.round();
    final first = math.max(0, (position - marker / spacing).floor() - 1);
    final last = math.min(
      count - 1,
      (position + (size.height - marker) / spacing).ceil() + 1,
    );
    for (var i = first; i <= last; i++) {
      final y = marker + (i - position) * spacing;
      if (y < 0 || y > size.height) continue;
      final active = i == selected;
      final width = active
          ? 27.0
          : i % 5 == 0
          ? 17.0
          : 8.0;
      final a = Offset(size.width - width, y), b = Offset(size.width, y);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = Colors.black.withValues(alpha: .40)
          ..strokeWidth = active ? 3.5 : 2.5,
      );
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = Colors.white.withValues(
            alpha: active
                ? .98
                : i % 5 == 0
                ? .65
                : .30,
          )
          ..strokeWidth = active ? 2 : 1,
      );
    }
  }

  @override
  bool shouldRepaint(_MessageRulerPainter old) =>
      old.position != position || old.count != count || old.marker != marker;
}

class ChatMessageLocatorPreview {
  const ChatMessageLocatorPreview({
    required this.timestamp,
    required this.sender,
    required this.previewContent,
    this.messageIndex,
  });
  final int timestamp;
  final String sender, previewContent;
  final int? messageIndex;
}
