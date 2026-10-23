import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

// Cover the perspective inset plus rounded corners without resizing content.
double drawerSurfaceBleed(double height) => 20 + height * .015;

/// Independent, interruptible drawer physics. Values are physical logical pixels;
/// a new drag always starts from the current rendered position, not a stale target.
class DrawerMotion extends ChangeNotifier {
  static const double maxSettleOvershoot = 10;
  DrawerMotion({required TickerProvider vsync})
    : _position = AnimationController.unbounded(vsync: vsync) {
    _position.addListener(notifyListeners);
  }
  final AnimationController _position;
  double leftExtent = 330, rightExtent = 350;
  double _anchor = 0, _originAnchor = 0;
  int _generation = 0;
  bool dragging = false, reducedMotion = false;
  double get offset => _position.value.clamp(
    -rightExtent - maxSettleOvershoot,
    leftExtent + maxSettleOvershoot,
  );
  double get openness =>
      (offset.abs() / (offset >= 0 ? leftExtent : rightExtent)).clamp(0, 1);
  void configure(double left, double right, {bool reduced = false}) {
    leftExtent = left;
    rightExtent = right;
    reducedMotion = reduced;
  }

  void begin() {
    _generation++;
    _position.stop();
    _originAnchor = _anchor;
    dragging = true;
    notifyListeners();
  }

  void dragBy(double delta) {
    if (!dragging) return;
    final x = offset;
    // Catching a recoil must not snap back to the normal drag limit.
    _position.value = (x + delta).clamp(
      math.min(-rightExtent, x),
      math.max(leftExtent, x),
    );
  }

  void cancel() {
    if (!dragging) return;
    dragging = false;
    _settle(_originAnchor, 0);
  }

  void release(double velocity) {
    if (!dragging) return;
    dragging = false;
    final x = offset;
    final projected = x + velocity.clamp(-2400, 2400) * .13;
    final target = x > 0
        ? (velocity < -450
              ? 0.0
              : projected > leftExtent * .38
              ? leftExtent
              : 0.0)
        : (velocity > 450
              ? 0.0
              : projected < -rightExtent * .38
              ? -rightExtent
              : 0.0);
    _settle(target, velocity);
  }

  void toggle(int side) {
    final target = side > 0
        ? (offset > 1 ? 0.0 : leftExtent)
        : (offset < -1 ? 0.0 : -rightExtent);
    _settle(target, 0);
  }

  void close() => _settle(0, 0);
  Future<void> _settle(double target, double velocity) async {
    final generation = ++_generation;
    _anchor = target;
    dragging = false;
    if ((offset - target).abs() < .1) {
      _position.value = target;
      notifyListeners();
      return;
    }
    try {
      if (reducedMotion) {
        await _position
            .animateTo(
              target,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            )
            .orCancel;
      } else {
        final start = offset;
        final distance = target - start;
        final opening = target != 0;
        // Opening has a small, highly damped recoil. Closing stays critical so
        // it cannot cross the center and briefly reveal the opposite drawer.
        // Keep a release directed toward its chosen destination in both cases.
        final launchVelocity =
            distance.sign *
            math.min(
              math.max(0.0, velocity * distance.sign),
              math.min(
                2400.0,
                opening ? distance.abs() * 32 + 480 : distance.abs() * 32,
              ),
            );
        await _position
            .animateWith(
              SpringSimulation(
                SpringDescription(
                  mass: 1,
                  stiffness: 1024,
                  damping: opening ? 48 : 64,
                ),
                start,
                target,
                launchVelocity,
                tolerance: const Tolerance(distance: .4, velocity: 12),
              ),
            )
            .orCancel;
      }
      if (generation == _generation) _position.value = target;
    } on TickerCanceled {
      /* An intervening drag owns the rendered position. */
    }
  }

  @override
  void dispose() {
    _generation++;
    _position.removeListener(notifyListeners);
    _position.dispose();
    super.dispose();
  }
}

/// Drag frames only compose transforms; the content is passed as a stable child.
/// Panels remain mounted until their closing animation actually reaches zero.
class SlideDeck extends StatefulWidget {
  const SlideDeck({
    super.key,
    required this.motion,
    required this.left,
    required this.right,
    required this.child,
  });
  final DrawerMotion motion;
  final Widget left, right, child;
  @override
  State<SlideDeck> createState() => _SlideDeckState();
}

class _SlideDeckState extends State<SlideDeck> {
  bool _cancelled = false;
  DrawerMotion get motion => widget.motion;
  Widget get left => widget.left;
  Widget get right => widget.right;
  Widget get child => widget.child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Listener(
      onPointerDown: (_) => _cancelled = false,
      onPointerCancel: (_) {
        _cancelled = true;
        motion.cancel();
      },
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          FocusScope.of(context).unfocus();
          motion.begin();
        },
        onHorizontalDragUpdate: (d) => motion.dragBy(d.delta.dx),
        onHorizontalDragCancel: motion.cancel,
        onHorizontalDragEnd: (d) {
          if (!_cancelled) motion.release(d.primaryVelocity ?? 0);
        },
        child: AnimatedBuilder(
          animation: motion,
          child: RepaintBoundary(child: child),
          builder: (context, content) {
            final x = motion.offset, progress = motion.openness;
            final extent = x >= 0 ? motion.leftExtent : motion.rightExtent;
            final sideAngle = motion.reducedMotion
                ? 0.0
                : .075 * math.sin(progress * math.pi);
            // Keep the inward fold while moving; a fully open panel rests
            // flat so its text baselines, cards and bottom actions stay level.
            // A shallow inward fold keeps both pages nearly full-height. The
            // translucent side panel overlaps the home page across the seam.
            final hingeDepth = extent * math.sin(sideAngle);
            final pageAngle = math.asin(
              (hingeDepth / constraints.maxWidth).clamp(0.0, .8),
            );
            final bleed = drawerSurfaceBleed(constraints.maxHeight);
            Matrix4 fold(double angle) => Matrix4.identity()
              ..setEntry(3, 2, .0007)
              ..translateByDouble(0, 0, hingeDepth, 1)
              ..rotateY(angle);
            Widget side(Widget panel, bool isLeft) => Transform(
              alignment: isLeft ? Alignment.centerRight : Alignment.centerLeft,
              transform: fold(isLeft ? -sideAngle : sideAngle),
              // Paint outside the sheet, toward the home page. The glass must
              // not clip or refract its own shadow into a dark interior band.
              // The library's contact ring is thick along its horizontal rim.
              // Rotate the shadow's layout and counter-rotate the content so
              // that broad, soft contact runs vertically beside the tall sheet.
              child: OverflowBox(
                minHeight: constraints.maxHeight + bleed * 2,
                maxHeight: constraints.maxHeight + bleed * 2,
                child: RotatedBox(
                  quarterTurns: 1,
                  child: LiquidGlassShadow(
                    blur: 22,
                    opacity: progress * .34,
                    color: const Color(0xff172538),
                    offset: Offset(0, isLeft ? -12 : 12),
                    cornerRadius: 18,
                    insideGlass: false,
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: bleed),
                        child: panel,
                      ),
                    ),
                  ),
                ),
              ),
            );
            // Stack only detects layout overflow. An explicit clip also stops
            // extended paint from covering the phone's separate status bar.
            return ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                fit: StackFit.expand,
                children: [
                  Transform.translate(
                    offset: Offset(x * .86, 0),
                    child: Transform(
                      key: const ValueKey('page-tilt'),
                      alignment: x >= 0
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      transform: fold(x.sign * pageAngle),
                      child: Stack(
                        key: const ValueKey('page-plane'),
                        clipBehavior: Clip.none,
                        fit: StackFit.expand,
                        children: [
                          Positioned(
                            top: -drawerSurfaceBleed(constraints.maxHeight),
                            bottom: -drawerSurfaceBleed(constraints.maxHeight),
                            left: 0,
                            right: 0,
                            child: DecoratedBox(
                              key: const ValueKey('home-sheet-fill'),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xfff3f7ff,
                                ).withValues(alpha: progress * .30),
                                borderRadius: BorderRadius.circular(
                                  progress * 12,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xff3e5474,
                                    ).withValues(alpha: progress * .13),
                                    blurRadius: 24,
                                    offset: Offset(x.sign * -6, 0),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(progress * 12),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                content!,
                                if (progress > .001)
                                  GestureDetector(
                                    onTap: motion.close,
                                    behavior: HitTestBehavior.opaque,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: x >= 0
                                              ? Alignment.centerLeft
                                              : Alignment.centerRight,
                                          end: x >= 0
                                              ? Alignment.centerRight
                                              : Alignment.centerLeft,
                                          colors: [
                                            const Color(
                                              0xff3e5474,
                                            ).withValues(alpha: progress * .07),
                                            const Color(
                                              0xff8293b0,
                                            ).withValues(alpha: progress * .03),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (x > .1)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: motion.leftExtent,
                      child: Transform.translate(
                        // Move the whole sheet, including its contact shadow.
                        // Its glass extends outward to cover the recoil.
                        offset: Offset(x - motion.leftExtent, 0),
                        child: side(left, true),
                      ),
                    ),
                  if (x < -.1)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: motion.rightExtent,
                      child: Transform.translate(
                        offset: Offset(x + motion.rightExtent, 0),
                        child: side(right, false),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
