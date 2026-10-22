// Migrated with the user's authorization from their original Starcompanion
// water-drop module. Pinned source and adaptations: ORB-PROVENANCE.txt.
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Original water-drop shader. Repaints independently at up to 30 fps;
/// stronger deformation follows measured audio, without rebuilding controls.
class VoiceCallOrb extends StatefulWidget {
  const VoiceCallOrb({
    super.key,
    required this.level,
    required this.onTap,
    required this.dark,
    this.reducedMotion = false,
    this.semanticLabel = '水滴光球',
  });
  final ValueNotifier<double> level;
  final VoidCallback onTap;
  final bool dark;
  final bool reducedMotion;
  final String semanticLabel;
  @override
  State<VoiceCallOrb> createState() => _VoiceCallOrbState();
}

class _VoiceCallOrbState extends State<VoiceCallOrb>
    with SingleTickerProviderStateMixin {
  static final _program = ui.FragmentProgram.fromAsset(
    'shaders/voice_drop.frag',
  );
  late final _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  final _frame = ValueNotifier<double>(4);
  ui.FragmentShader? _shader;
  Duration _previousFrame = Duration.zero;
  double _energy = 0;

  @override
  void initState() {
    super.initState();
    _clock.addListener(_tick);
    if (!widget.reducedMotion) _clock.repeat();
    _loadShader();
  }

  @override
  void didUpdateWidget(covariant VoiceCallOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reducedMotion != widget.reducedMotion) {
      _previousFrame = Duration.zero;
      if (widget.reducedMotion) {
        _clock.stop();
        _energy = 0;
        _frame.value = 4;
      } else {
        _clock.repeat();
      }
    }
  }

  Future<void> _loadShader() async {
    try {
      final program = await _program;
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Preserve usable call controls on devices without runtime shader support.
      // The existing canvas material remains an explicit visual fallback.
    }
  }

  void _tick() {
    final elapsed = _clock.lastElapsedDuration ?? Duration.zero;
    final delta = elapsed - _previousFrame;
    if (delta.inMicroseconds < 1000000 / 30) return;
    _previousFrame = elapsed;
    final dt = (delta.inMicroseconds / 1000000).clamp(0.0, .1);
    final raw = widget.level.value;
    final target = raw.isFinite ? raw.clamp(0.0, 1.0) : 0.0;
    _energy += (target - _energy) * (1 - math.exp(-dt * 9));
    _frame.value += dt * (.55 + _energy * .9);
  }

  @override
  void dispose() {
    _clock.removeListener(_tick);
    _clock.dispose();
    _frame.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.semanticLabel,
    child: GestureDetector(
      onTap: widget.onTap,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _shader == null
              ? _OrbPainter(
                  _clock,
                  widget.level,
                  widget.dark,
                  widget.reducedMotion,
                )
              : _DropPainter(
                  _shader!,
                  _frame,
                  () => _energy,
                  MediaQuery.devicePixelRatioOf(context).clamp(1.0, 1.5),
                ),
          size: Size.infinite,
        ),
      ),
    ),
  );
}

class _DropPainter extends CustomPainter {
  _DropPainter(this.shader, this.clock, this.energy, this.pixelRatio)
    : super(repaint: clock);
  final ui.FragmentShader shader;
  final ValueNotifier<double> clock;
  final double Function() energy;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, clock.value)
      ..setFloat(3, energy())
      ..setFloat(4, pixelRatio);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_DropPainter oldDelegate) =>
      oldDelegate.shader != shader || oldDelegate.pixelRatio != pixelRatio;
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.clock, this.level, this.dark, this.reducedMotion)
    : super(repaint: Listenable.merge([clock, level]));
  final Animation<double> clock;
  final ValueNotifier<double> level;
  final bool dark;
  final bool reducedMotion;
  double _energy = 0;
  @override
  void paint(Canvas canvas, Size size) {
    final t = reducedMotion ? 0.0 : clock.value * math.pi * 2;
    final raw = level.value;
    final target = raw.isFinite ? raw.clamp(0.0, 1.0) : 0.0;
    _energy = reducedMotion ? 0 : _energy + (target - _energy) * .18;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * (.405 + _energy * .025);
    final bounds = Rect.fromCircle(center: center, radius: radius);
    final contour = Path();
    for (var i = 0; i <= 160; i++) {
      final angle = i / 160 * math.pi * 2;
      final wave =
          math.sin(angle * 3 + t) * .006 +
          _energy * .035 * math.sin(angle * 4 - t * 2);
      final point =
          center +
          Offset(math.cos(angle), math.sin(angle)) * radius * (1 + wave);
      if (i == 0) {
        contour.moveTo(point.dx, point.dy);
      } else {
        contour.lineTo(point.dx, point.dy);
      }
    }
    contour.close();
    canvas.drawPath(
      contour,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-.5 + math.sin(t) * .3, -.9),
          end: Alignment(.4, .9),
          colors: dark
              ? const [Color(0xff625171), Color(0xff7e698e), Color(0xff527a9b)]
              : const [Color(0xffffdcd9), Color(0xffe9c6e9), Color(0xff9aaee2)],
        ).createShader(bounds),
    );
    canvas.save();
    canvas.clipPath(contour);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                const Color(0xffffedc7).withValues(alpha: dark ? .25 : .65),
                Colors.transparent,
              ],
            ).createShader(
              bounds.translate(radius * .25 * math.sin(t), -radius * .3),
            ),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xffbc8ce8).withValues(alpha: .55),
            Colors.transparent,
          ],
        ).createShader(bounds.translate(-radius * .4, radius * .45)),
    );
    canvas.restore();
    canvas.drawPath(
      contour,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x70ffffff), Color(0x08ffffff), Color(0x25ffffff)],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) =>
      oldDelegate.reducedMotion != reducedMotion ||
      oldDelegate.dark != dark ||
      oldDelegate.level != level ||
      oldDelegate.clock != clock;
}
