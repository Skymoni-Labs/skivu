import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A section index with Skivu's hold gate, live section highlight, and normal scrolling.
class AppAlphabetRuler extends StatefulWidget {
  const AppAlphabetRuler({
    super.key,
    required this.letters,
    required this.onJump,
    this.currentLetter = '',
    this.onBrowseStart,
    this.onBrowseUpdate,
    this.onBrowseEnd,
    this.onBrowseCancel,
  });
  final List<String> letters;
  final String currentLetter;
  final ValueChanged<String> onJump;
  final GestureDragStartCallback? onBrowseStart;
  final GestureDragUpdateCallback? onBrowseUpdate;
  final GestureDragEndCallback? onBrowseEnd;
  final GestureDragCancelCallback? onBrowseCancel;
  @override
  State<AppAlphabetRuler> createState() => _AppAlphabetRulerState();
}

class _AppAlphabetRulerState extends State<AppAlphabetRuler> {
  final surface = GlobalKey();
  bool holding = false;
  int index = 0;
  double pointerY = 0;
  int get current => math.max(0, widget.letters.indexOf(widget.currentLetter));
  @override
  void initState() {
    super.initState();
    index = current;
  }

  @override
  void didUpdateWidget(covariant AppAlphabetRuler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.letters, widget.letters)) holding = false;
    if (!holding) index = current;
  }

  void locate(Offset global, {bool start = false}) {
    if (widget.letters.isEmpty) return;
    final box = surface.currentContext!.findRenderObject() as RenderBox;
    final localY = box.globalToLocal(global).dy.clamp(0.0, box.size.height);
    final height = math.max(1.0, box.size.height - 12);
    final y = (localY - 6).clamp(0.0, height);
    final cell = height / widget.letters.length;
    var next = (y / cell).floor().clamp(0, widget.letters.length - 1);
    if (!start && next != index) {
      final margin = math.min(3.0, cell * .18);
      if (next > index && y < (index + 1) * cell + margin ||
          next < index && y > index * cell - margin)
        next = index;
    }
    final changed = start
        ? widget.currentLetter != widget.letters[next]
        : next != index;
    setState(() {
      holding = true;
      pointerY = localY;
      index = next;
    });
    if (changed) {
      HapticFeedback.selectionClick();
      widget.onJump(widget.letters[next]);
    }
  }

  void end() {
    if (holding) setState(() => holding = false);
  }

  void step(int delta) {
    if (widget.letters.isEmpty) return;
    widget.onJump(
      widget.letters[((holding ? index : current) + delta).clamp(
        0,
        widget.letters.length - 1,
      )],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.letters.isEmpty
        ? 0
        : (holding ? index : current).clamp(0, widget.letters.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = math.min(
          constraints.maxHeight,
          widget.letters.length * 20.0 + 12,
        );
        final top = (constraints.maxHeight - trackHeight) / 2;
        final bubbleTop = (top + pointerY - 36).clamp(
          0.0,
          math.max(0.0, constraints.maxHeight - 72),
        );
        final cellHeight = math.max(
          1.0,
          (trackHeight - 12) / math.max(1, widget.letters.length),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: top,
              height: trackHeight,
              left: 0,
              right: 0,
              child: Semantics(
                label: '按字母快速定位',
                value: widget.letters.isEmpty ? '' : widget.letters[selected],
                increasedValue: widget.letters.isEmpty
                    ? ''
                    : widget.letters[(selected + 1).clamp(
                        0,
                        widget.letters.length - 1,
                      )],
                decreasedValue: widget.letters.isEmpty
                    ? ''
                    : widget.letters[(selected - 1).clamp(
                        0,
                        widget.letters.length - 1,
                      )],
                hint: '长按启用字母定位，普通上下滑动滚动列表',
                onIncrease: widget.letters.isEmpty ? null : () => step(1),
                onDecrease: widget.letters.isEmpty ? null : () => step(-1),
                child: Listener(
                  onPointerCancel: (_) => end(),
                  child: GestureDetector(
                    key: const ValueKey('engine-app-alphabet-ruler'),
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onLongPressStart: (event) =>
                        locate(event.globalPosition, start: true),
                    onLongPressMoveUpdate: (event) =>
                        locate(event.globalPosition),
                    onLongPressEnd: (_) => end(),
                    onLongPressCancel: end,
                    onVerticalDragStart: widget.onBrowseStart,
                    onVerticalDragUpdate: widget.onBrowseUpdate,
                    onVerticalDragEnd: widget.onBrowseEnd,
                    onVerticalDragCancel: widget.onBrowseCancel,
                    child: AnimatedContainer(
                      key: surface,
                      duration: const Duration(milliseconds: 100),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: colors.surface.withValues(
                          alpha: holding ? .96 : .42,
                        ),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: colors.outlineVariant.withValues(
                            alpha: holding ? .5 : .16,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < widget.letters.length; i++)
                            Expanded(
                              child: DecoratedBox(
                                key: i == selected
                                    ? const ValueKey('engine-app-ruler-current')
                                    : null,
                                decoration: BoxDecoration(
                                  color: i == selected
                                      ? colors.primary
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    widget.letters[i],
                                    textScaler: TextScaler.noScaling,
                                    style: TextStyle(
                                      fontSize: math.min(11.0, cellHeight * .8),
                                      height: 1,
                                      fontWeight: i == selected
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                      color: i == selected
                                          ? colors.onPrimary
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (holding && widget.letters.isNotEmpty)
              Positioned(
                key: const ValueKey('engine-app-letter-preview'),
                left: 44,
                top: bubbleTop.toDouble(),
                child: IgnorePointer(
                  child: Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .1),
                          blurRadius: 18,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Text(
                      widget.letters[selected],
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.w600,
                        color: colors.onPrimaryContainer,
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
