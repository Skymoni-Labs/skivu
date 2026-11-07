import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A hold-to-scrub index. Taps and ordinary swipes never jump the app list.
class AppAlphabetRuler extends StatefulWidget {
  const AppAlphabetRuler({
    super.key,
    required this.letters,
    required this.onJump,
  });
  final List<String> letters;
  final ValueChanged<String> onJump;

  @override
  State<AppAlphabetRuler> createState() => _AppAlphabetRulerState();
}

class _AppAlphabetRulerState extends State<AppAlphabetRuler> {
  final surface = GlobalKey();
  bool holding = false;
  int index = 0;
  double pointerY = 0;

  @override
  void didUpdateWidget(covariant AppAlphabetRuler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.letters, widget.letters)) {
      holding = false;
      index = 0;
    }
  }

  void locate(Offset global, {bool start = false}) {
    if (widget.letters.isEmpty) return;
    final box = surface.currentContext!.findRenderObject() as RenderBox;
    final y = box.globalToLocal(global).dy.clamp(0.0, box.size.height);
    final next = ((y / box.size.height) * widget.letters.length).floor().clamp(
      0,
      widget.letters.length - 1,
    );
    final changed = start || next != index;
    setState(() {
      holding = true;
      pointerY = y;
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

  void step(int direction) {
    if (widget.letters.isEmpty) return;
    setState(
      () => index = (index + direction).clamp(0, widget.letters.length - 1),
    );
    widget.onJump(widget.letters[index]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final bubbleTop = (pointerY - 36).clamp(
          0.0,
          (constraints.maxHeight - 72).clamp(0.0, double.infinity),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Semantics(
                label: '按字母快速定位',
                value: widget.letters.isEmpty ? '' : widget.letters[index],
                increasedValue: widget.letters.isEmpty
                    ? ''
                    : widget.letters[(index + 1).clamp(
                        0,
                        widget.letters.length - 1,
                      )],
                decreasedValue: widget.letters.isEmpty
                    ? ''
                    : widget.letters[(index - 1).clamp(
                        0,
                        widget.letters.length - 1,
                      )],
                hint: '长按刻度后上下拖动选择字母',
                onIncrease: () => step(1),
                onDecrease: () => step(-1),
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
                  child: Container(
                    key: surface,
                    decoration: BoxDecoration(
                      color: holding
                          ? colors.surface.withValues(alpha: .9)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < widget.letters.length; i++)
                          Expanded(
                            child: Center(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    height: holding && i == index ? 2 : 1,
                                    width: holding && i == index
                                        ? 10
                                        : i % 3 == 0
                                        ? 8
                                        : 4,
                                    color: holding && i == index
                                        ? colors.primary
                                        : colors.onSurface.withValues(
                                            alpha: .34,
                                          ),
                                  ),
                                  if (holding || i % 3 == 0) ...[
                                    const SizedBox(width: 3),
                                    Text(
                                      widget.letters[i],
                                      textScaler: TextScaler.noScaling,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: holding && i == index
                                            ? colors.primary
                                            : colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (holding && widget.letters.isNotEmpty)
              Positioned(
                key: const ValueKey('engine-app-letter-preview'),
                left: 44,
                top: bubbleTop,
                child: IgnorePointer(
                  child: Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: colors.primary.withValues(alpha: .2),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .12),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Text(
                      widget.letters[index],
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
