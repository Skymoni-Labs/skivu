import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'drawer_frame_diagnostics.dart';

// Extend the sheet past the viewport for rounded corners and spring recoil.
double drawerSurfaceBleed(double height) => 20 + height * .015;

/// Paint the contact on the adjacent page, above the glass sampling passes.
/// Source-over keeps it visible even when the glass uses a separate layer.
class DrawerContactShadow extends StatelessWidget {
  const DrawerContactShadow({
    super.key,
    required this.leftSide,
    required this.progress,
  });
  final bool leftSide;
  final double progress;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: leftSide ? Alignment.centerLeft : Alignment.centerRight,
          end: leftSide ? Alignment.centerRight : Alignment.centerLeft,
          stops: const [0, .4, 1],
          colors: [
            const Color(
              0xff172538,
            ).withValues(alpha: progress.clamp(0, 1) * .32),
            const Color(
              0xff172538,
            ).withValues(alpha: progress.clamp(0, 1) * .10),
            const Color(0x00172538),
          ],
        ),
      ),
    ),
  );
}

/// Independent, interruptible drawer physics. Values are physical logical pixels;
/// a new drag always starts from the current rendered position, not a stale target.
class DrawerMotion extends ChangeNotifier {
  static const _diagnostics = bool.fromEnvironment('SKIVU_DRAWER_DIAGNOSTICS');
  void _trace(String message) {
    if (_diagnostics) debugPrint('SkivuDrawer: $message');
  }

  static const double maxSettleOvershoot = 10;
  DrawerMotion({required TickerProvider vsync})
    : _position = AnimationController.unbounded(vsync: vsync) {
    _position.addListener(notifyListeners);
    if (DrawerFrameDiagnostics.enabled) addListener(_reportMotion);
  }
  final _frames = DrawerFrameDiagnostics();
  bool? _lastMoving;
  void _reportMotion() {
    if (_lastMoving == isMoving) return;
    _lastMoving = isMoving;
    _frames.motion(isMoving, offset);
  }

  final AnimationController _position;
  double leftExtent = 330, rightExtent = 350;
  double _anchor = 0, _originAnchor = 0, _dragOrigin = 0;
  int _generation = 0;
  bool dragging = false, reducedMotion = false;
  bool get isMoving => dragging || _position.isAnimating;
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
    _dragOrigin = offset;
    _trace('begin at=$_dragOrigin');
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
    _trace('cancel at=$offset return=$_originAnchor');
    dragging = false;
    _settle(_originAnchor, 0);
  }

  void release(double velocity) {
    if (!dragging) return;
    dragging = false;
    final x = offset;
    final travel = x - _dragOrigin;
    final extent = travel >= 0 ? leftExtent : rightExtent;
    final threshold = (extent * .16).clamp(28.0, 48.0);
    final flick =
        travel.abs() >= 8 &&
        velocity.abs() >= 320 &&
        velocity.sign == travel.sign;
    // Decide from this gesture's intent, not a fixed percentage of the open
    // panel. The previous absolute threshold made closing require a long drag.
    var target = _originAnchor;
    if (travel.abs() >= threshold || flick) {
      target = travel > 0
          ? (_dragOrigin < -.1 && x < threshold ? 0.0 : leftExtent)
          : (_dragOrigin > .1 && x > -threshold ? 0.0 : -rightExtent);
    }
    _trace('release travel=$travel velocity=$velocity target=$target');
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
    if (DrawerFrameDiagnostics.enabled) removeListener(_reportMotion);
    _frames.dispose();
    _position.removeListener(notifyListeners);
    _position.dispose();
    super.dispose();
  }
}

/// Operit-style retained layers: all three pages stay mounted, while Flow moves
/// only their compositor transforms. A closed panel is neither painted nor hit.
class SlideDeck extends StatefulWidget {
  const SlideDeck({
    super.key,
    required this.motion,
    required this.left,
    required this.right,
    required this.child,
    this.dragEnabled = true,
  });
  final DrawerMotion motion;
  final Widget left, right, child;
  final bool dragEnabled;
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
        onHorizontalDragStart: !widget.dragEnabled
            ? null
            : (_) {
                FocusScope.of(context).unfocus();
                motion.begin();
              },
        onHorizontalDragUpdate: !widget.dragEnabled
            ? null
            : (d) => motion.dragBy(d.delta.dx),
        onHorizontalDragCancel: !widget.dragEnabled ? null : motion.cancel,
        onHorizontalDragEnd: !widget.dragEnabled
            ? null
            : (d) {
                if (!_cancelled) motion.release(d.primaryVelocity ?? 0);
              },
        child: Flow(
          delegate: _DrawerLayers(
            motion,
            leftExtent: motion.leftExtent,
            rightExtent: motion.rightExtent,
          ),
          children: [
            Stack(
              key: const ValueKey('page-plane'),
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: -drawerSurfaceBleed(constraints.maxHeight),
                  bottom: -drawerSurfaceBleed(constraints.maxHeight),
                  left: 0,
                  right: 0,
                  child: CustomPaint(
                    key: const ValueKey('home-sheet-fill'),
                    painter: _PageSheetPaint(motion),
                  ),
                ),
                ClipRRect(
                  clipper: _PageClip(motion),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(child: child),
                      AnimatedBuilder(
                        animation: motion,
                        child: GestureDetector(
                          onTap: motion.close,
                          behavior: HitTestBehavior.opaque,
                          child: CustomPaint(painter: _PageScrimPaint(motion)),
                        ),
                        builder: (_, barrier) => IgnorePointer(
                          ignoring: motion.offset.abs() < .1,
                          child: barrier,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            _retainedSide(left, true, constraints.maxHeight),
            _retainedSide(right, false, constraints.maxHeight),
          ],
        ),
      ),
    ),
  );

  Widget _retainedSide(Widget panel, bool isLeft, double height) =>
      AnimatedBuilder(
        animation: motion,
        child: _side(panel, isLeft, height),
        builder: (_, surface) {
          final visible = isLeft ? motion.offset > .1 : motion.offset < -.1;
          return ExcludeFocus(
            excluding: !visible,
            child: Offstage(
              offstage: !visible,
              child: TickerMode(enabled: visible, child: surface!),
            ),
          );
        },
      );

  Widget _side(Widget panel, bool isLeft, double height) => Stack(
    clipBehavior: Clip.none,
    fit: StackFit.expand,
    children: [
      RepaintBoundary(child: panel),
      Positioned(
        top: -drawerSurfaceBleed(height),
        bottom: -drawerSurfaceBleed(height),
        left: isLeft ? null : -28,
        right: isLeft ? -28 : null,
        width: 28,
        child: AnimatedBuilder(
          animation: motion,
          builder: (_, _) => DrawerContactShadow(
            key: ValueKey(
              isLeft ? 'left-contact-shadow' : 'right-contact-shadow',
            ),
            leftSide: isLeft,
            progress: motion.openness,
          ),
        ),
      ),
    ],
  );
}

/// Translation is applied in paint, not via Positioned layout on every tick.
/// Hidden panes are not painted or hit; their wrapper also excludes semantics.
class _DrawerLayers extends FlowDelegate {
  _DrawerLayers(
    this.motion, {
    required this.leftExtent,
    required this.rightExtent,
  }) : super(repaint: motion);
  final DrawerMotion motion;
  final double leftExtent, rightExtent;
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tightFor(
        width: i == 0
            ? constraints.maxWidth
            : (i == 1 ? leftExtent : rightExtent),
        height: constraints.maxHeight,
      );
  @override
  void paintChildren(FlowPaintingContext context) {
    final x = motion.offset;
    context.paintChild(0, transform: Matrix4.translationValues(x * .86, 0, 0));
    if (x > .1) {
      context.paintChild(
        1,
        transform: Matrix4.translationValues(x - leftExtent, 0, 0),
      );
    } else if (x < -.1) {
      context.paintChild(
        2,
        transform: Matrix4.translationValues(context.size.width + x, 0, 0),
      );
    }
  }

  @override
  bool shouldRepaint(_DrawerLayers oldDelegate) => motion != oldDelegate.motion;
  @override
  bool shouldRelayout(_DrawerLayers oldDelegate) =>
      leftExtent != oldDelegate.leftExtent ||
      rightExtent != oldDelegate.rightExtent;
}

class _PageClip extends CustomClipper<RRect> {
  _PageClip(this.motion) : super(reclip: motion);
  final DrawerMotion motion;
  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    Offset.zero & size,
    Radius.circular(motion.openness * 12),
  );
  @override
  bool shouldReclip(_PageClip oldClipper) => motion != oldClipper.motion;
}

class _PageSheetPaint extends CustomPainter {
  _PageSheetPaint(this.motion) : super(repaint: motion);
  final DrawerMotion motion;
  @override
  void paint(Canvas canvas, Size size) {
    final progress = motion.openness;
    if (progress < .001) return;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(progress * 12),
    );
    canvas.drawRRect(
      rect.shift(Offset(motion.offset.sign * -6, 0)),
      Paint()
        ..color = const Color(0xff3e5474).withValues(alpha: progress * .13)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14.36),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = const Color(0xfff3f7ff).withValues(alpha: progress * .30),
    );
  }

  @override
  bool shouldRepaint(_PageSheetPaint oldDelegate) =>
      motion != oldDelegate.motion;
}

class _PageScrimPaint extends CustomPainter {
  _PageScrimPaint(this.motion) : super(repaint: motion);
  final DrawerMotion motion;
  @override
  void paint(Canvas canvas, Size size) {
    final progress = motion.openness;
    if (progress < .001) return;
    final gradient = LinearGradient(
      begin: motion.offset >= 0 ? Alignment.centerLeft : Alignment.centerRight,
      end: motion.offset >= 0 ? Alignment.centerRight : Alignment.centerLeft,
      colors: [
        const Color(0xff3e5474).withValues(alpha: progress * .07),
        const Color(0xff8293b0).withValues(alpha: progress * .03),
      ],
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = gradient.createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_PageScrimPaint oldDelegate) =>
      motion != oldDelegate.motion;
}
