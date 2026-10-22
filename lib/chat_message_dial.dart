// User-authorized original module migration; see MODULE-MIGRATION.md.
// ignore_for_file: file_names
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

import 'chat_message_dial_model.dart';

/// Native navigation chrome. Only lightweight locator previews are held during
/// a gesture; transcript hydration remains owned by ChatArea and Core.
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
  });
  final bool visible;
  final double viewportHeight;
  final int? currentTimestamp;
  final Future<List<ChatMessageLocatorPreview>> Function() loadEntries;
  final VoidCallback onOpenLocator, onHidden;
  final VoidCallback? onLatest;
  final bool showLatest;
  final ValueChanged<int> onJump;
  final String Function(String) senderName;
  @override
  State<ChatMessageDial> createState() => _ChatMessageDialState();
}

class _ChatMessageDialState extends State<ChatMessageDial> {
  final _surfaceKey = GlobalKey();
  Timer? _lingerTimer;
  bool _holding = false,
      _pressed = false,
      _linger = false,
      _loading = false,
      _deadZone = false;
  int _generation = 0;
  MessageDial? _dial;
  List<ChatMessageLocatorPreview> _entries = const [];
  Offset _center = Offset.zero;
  double _angle = 0;
  Duration _pointerTime = Duration.zero, _lastMove = Duration.zero;

  Offset _local(Offset global) =>
      (_surfaceKey.currentContext!.findRenderObject() as RenderBox)
          .globalToLocal(global);

  Future<void> _start(LongPressStartDetails event) async {
    final generation = ++_generation;
    _lingerTimer?.cancel();
    final vector = _local(event.globalPosition) - _center;
    _angle = math.atan2(vector.dy, vector.dx);
    final timestamp = widget.currentTimestamp;
    setState(() {
      _holding = true;
      _linger = false;
      _loading = true;
      _dial = null;
      _deadZone = false;
    });
    try {
      final entries = await widget.loadEntries();
      if (!mounted || !_holding || generation != _generation) return;
      final index = entries.indexWhere((entry) => entry.timestamp == timestamp);
      setState(() {
        _entries = entries;
        _loading = false;
        if (entries.isNotEmpty) {
          _dial = MessageDial(
            count: entries.length,
            index: math.max(0, index),
            angle: _angle,
          );
        }
        _lastMove = _pointerTime;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _end(cancel: true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(const _DialStrings().chatDialLoadFailed)),
      );
    }
  }

  void _move(LongPressMoveUpdateDetails event) {
    if (!_holding) return;
    final vector = _local(event.globalPosition) - _center;
    if (vector.distance < 24) {
      _deadZone = true;
      return;
    }
    _angle = math.atan2(vector.dy, vector.dx);
    if (_loading || _dial == null) return;
    if (_deadZone) {
      _dial!.reanchor(_angle);
      _lastMove = _pointerTime;
      _deadZone = false;
      return;
    }
    setState(() => _dial!.move(_angle, _pointerTime - _lastMove));
    _lastMove = _pointerTime;
  }

  void _end({bool cancel = false}) {
    if (!_holding) return;
    final target = _dial == null ? null : _entries[_dial!.index].timestamp;
    _generation++;
    setState(() {
      _holding = false;
      _loading = false;
      _linger = true;
      _dial = null;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme, l10n = const _DialStrings();
    return LayoutBuilder(
      builder: (context, constraints) {
        // The overlay ends at the composer, so both controls track its height.
        final y = (widget.viewportHeight - 88)
            .clamp(84.0, math.max(84.0, constraints.maxHeight - 88))
            .toDouble();
        _center = Offset(math.max(82.0, constraints.maxWidth - 92), y);
        final center = _holding
            ? _center
            : Offset(constraints.maxWidth - 26, y);
        final entry = _dial == null ? null : _entries[_dial!.index];
        return Stack(
          key: _surfaceKey,
          fit: StackFit.expand,
          children: [
            if (!_holding &&
                widget.onLatest != null &&
                (widget.visible || widget.showLatest))
              Positioned(
                right: 4,
                top: y + 30,
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Material(
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: .58,
                      ),
                      shape: const CircleBorder(),
                      child: IconButton(
                        key: const ValueKey('chat-jump-latest'),
                        tooltip: '回到最新消息',
                        onPressed: widget.onLatest,
                        icon: const Icon(
                          Icons.keyboard_double_arrow_down_rounded,
                        ),
                        iconSize: 23,
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_holding)
              Positioned(
                left: _center.dx - 82,
                top: _center.dy - 82,
                width: 164,
                height: 164,
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('chat-message-dial-ring'),
                    painter: _ChatDialPainter(
                      progress: ((_dial?.rotation ?? 0) / (2 * math.pi)) % 1,
                      index: _dial?.index ?? 0,
                      count: _entries.length,
                      colors: colors,
                    ),
                  ),
                ),
              ),
            if (_holding)
              Positioned(
                left: 12,
                right: 12,
                top: _center.dy + 91 < constraints.maxHeight - 110
                    ? _center.dy + 91
                    : null,
                bottom: _center.dy + 91 < constraints.maxHeight - 110
                    ? null
                    : 8,
                child: IgnorePointer(
                  child: Material(
                    key: const ValueKey('chat-message-dial-target'),
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_loading)
                            Text(l10n.loading)
                          else if (entry == null)
                            Text(l10n.messageLocatorNoMatches)
                          else ...[
                            Text(
                              l10n.chatDialTarget(
                                (entry.messageIndex ?? _dial!.index) + 1,
                                _entries.length,
                                widget.senderName(entry.sender),
                              ),
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              entry.previewContent,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${switch (_dial!.scale) {
                                DialScale.fine => l10n.chatDialFine,
                                DialScale.medium => l10n.chatDialBrowse,
                                DialScale.fast => l10n.chatDialFast,
                              }} · ${l10n.chatDialScale(_dial!.messagesPerTurn.round())}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.visible || _pressed || _holding || _linger)
              AnimatedPositioned(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                left: center.dx - 22,
                top: center.dy - 22,
                width: 44,
                height: 44,
                child: Semantics(
                  container: true,
                  child: Semantics(
                    label: l10n.chatDialHint,
                    button: true,
                    child: Listener(
                      onPointerDown: (event) {
                        _pointerTime = event.timeStamp;
                        setState(() => _pressed = true);
                      },
                      onPointerUp: (_) => setState(() => _pressed = false),
                      onPointerMove: (event) => _pointerTime = event.timeStamp,
                      onPointerCancel: (_) {
                        setState(() => _pressed = false);
                        _end(cancel: true);
                      },
                      child: GestureDetector(
                        key: const ValueKey('chat-message-navigation-ball'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _lingerTimer?.cancel();
                          setState(() => _linger = false);
                          widget.onHidden();
                          widget.onOpenLocator();
                        },
                        onLongPressStart: _start,
                        onLongPressMoveUpdate: _move,
                        onLongPressEnd: (_) => _end(),
                        onLongPressCancel: () => _end(cancel: true),
                        child: Center(
                          child: ClipOval(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.surfaceContainerHighest
                                      .withValues(alpha: .58),
                                  border: Border.all(
                                    color: colors.outlineVariant.withValues(
                                      alpha: .12,
                                    ),
                                  ),
                                ),
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
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChatDialPainter extends CustomPainter {
  const _ChatDialPainter({
    required this.progress,
    required this.count,
    required this.index,
    required this.colors,
  });
  final double progress;
  final int count;
  final int index;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final disc = Path()..addOval(Rect.fromCircle(center: center, radius: 79));
    canvas.drawShadow(disc, Colors.black.withValues(alpha: .12), 12, true);
    canvas.drawCircle(
      center,
      79,
      Paint()..color = colors.surface.withValues(alpha: .93),
    );
    canvas.drawCircle(
      center,
      79,
      Paint()
        ..color = Colors.white.withValues(alpha: .95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final track = Rect.fromCircle(center: center, radius: 72);
    canvas.drawArc(
      track,
      -math.pi / 2,
      2 * math.pi,
      false,
      Paint()
        ..color = colors.primary.withValues(alpha: .08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawArc(
      track,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = colors.primary.withValues(alpha: .4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < 60; i++) {
      final angle = -math.pi / 2 + i / 60 * math.pi * 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final active = (i - progress * 59).abs() < .7;
      canvas.drawLine(
        center + direction * (i % 5 == 0 ? 50 : 57),
        center + direction * 64,
        Paint()
          ..color = active
              ? colors.primary
              : colors.onSurfaceVariant.withValues(alpha: i % 5 == 0 ? .5 : .24)
          ..strokeWidth = active ? 2.4 : 1.2
          ..strokeCap = StrokeCap.round,
      );
    }
    final angle = -math.pi / 2 + progress * math.pi * 2;
    canvas.drawCircle(
      center + Offset(math.cos(angle), math.sin(angle)) * 72,
      3,
      Paint()..color = colors.primary,
    );
    final label = TextPainter(
      text: TextSpan(
        text: count == 0 ? '…' : '${index + 1} / $count',
        style: TextStyle(
          color: colors.primary.withValues(alpha: .8),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(center.dx - label.width / 2, center.dy + 20));
  }

  @override
  bool shouldRepaint(_ChatDialPainter old) =>
      old.progress != progress ||
      old.index != index ||
      old.count != count ||
      old.colors != colors;
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

class _DialStrings {
  const _DialStrings();
  String get chatDialLoadFailed => '暂时无法读取消息';
  String get loading => '正在读取';
  String get messageLocatorNoMatches => '没有匹配的消息';
  String get chatDialFine => '精细定位';
  String get chatDialBrowse => '浏览';
  String get chatDialFast => '快速浏览';
  String get chatDialHint => '消息导航：点击定位，长按环形导航';
  String chatDialScale(int count) => '每圈 $count 条';
  String chatDialTarget(int index, int total, String sender) =>
      '$index / $total · $sender';
}
