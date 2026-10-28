import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chat_backdrop.dart';

/// Render data derived only from the approved Skivu mark, loaded once at startup.
class LaunchArtwork {
  LaunchArtwork(this.mask, List<Offset> targets)
    : particles = List.unmodifiable([
        for (var i = 0; i < targets.length; i++)
          _Particle(targets[i] - const Offset(.5, .5), i),
      ]);
  final ui.Image mask;
  final List<_Particle> particles;

  static Future<LaunchArtwork?> load() async {
    ui.Codec? codec;
    try {
      final maskFuture = rootBundle.load(
        'assets/branding/skivu-cloud-mask.png',
      );
      final targetsFuture = rootBundle.loadString(
        'assets/branding/skivu-cloud-particles.json',
      );
      final bytes = await maskFuture;
      codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      final points = (jsonDecode(await targetsFuture) as List)
          .map(
            (p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList();
      return LaunchArtwork(frame.image, points);
    } catch (error) {
      assert(() {
        debugPrint('Skivu launch artwork unavailable: $error');
        return true;
      }());
      // A decorative asset failure must never prevent access to the chat.
      return null;
    } finally {
      codec?.dispose();
    }
  }
}

class _Particle {
  _Particle(this.target, int i)
    : random = _random(i),
      direction = Offset(math.cos(i * 2.39996), math.sin(i * 2.39996)),
      blue = i % 5 == 0;
  final Offset target, direction;
  final double random;
  final bool blue;
  static double _random(int i) {
    final value = math.sin((i + 1) * 127.1) * 43758.5453;
    return value - value.floorToDouble();
  }
}

enum LaunchPart { content, toolbar, composer }

double _clamp(double v) => v.clamp(0.0, 1.0);
double _linear(double t, double a, double b) => _clamp((t - a) / (b - a));
double _ease(double t, double a, double b) {
  final v = _linear(t, a, b);
  return v * v * (3 - 2 * v);
}

class _LaunchTarget {
  GlobalKey key = GlobalKey();
  double radius = 0;
  ChatBackdropController? backdrop;
}

class _LaunchScope extends InheritedWidget {
  const _LaunchScope({
    required this.sequence,
    required this.enabled,
    required super.child,
  });
  final _LaunchSequence sequence;
  final bool enabled;
  static _LaunchSequence? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_LaunchScope>();
    return scope?.enabled == true ? scope!.sequence : null;
  }

  @override
  bool updateShouldNotify(_LaunchScope oldWidget) =>
      sequence != oldWidget.sequence || enabled != oldWidget.enabled;
}

class _LaunchSequence {
  _LaunchSequence(this.animation);
  final AnimationController animation;
  final overlayKey = GlobalKey();
  final toolbar = _LaunchTarget(),
      composer = _LaunchTarget(),
      content = _LaunchTarget();

  Rect? bounds(_LaunchTarget target) => keyBounds(target.key);

  Rect? keyBounds(GlobalKey key) {
    final origin = overlayKey.currentContext?.findRenderObject();
    final box = key.currentContext?.findRenderObject();
    if (origin is! RenderBox ||
        box is! RenderBox ||
        !box.hasSize ||
        !box.attached) {
      return null;
    }
    return box.localToGlobal(Offset.zero, ancestor: origin) & box.size;
  }
}

/// The real glass stays fully painted. A wallpaper-only overlay reveals it;
/// fading BackdropFilter widgets inside Opacity can produce black Android rims.
class LaunchReveal extends StatefulWidget {
  const LaunchReveal({
    super.key,
    required this.part,
    required this.child,
    this.radius = 0,
  });
  final LaunchPart part;
  final Widget child;
  final double radius;
  @override
  State<LaunchReveal> createState() => _LaunchRevealState();
}

class _LaunchRevealState extends State<LaunchReveal> {
  final anchor = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final sequence = _LaunchScope.of(context);
    if (sequence != null && ModalRoute.of(context)?.isCurrent != false) {
      final target = switch (widget.part) {
        LaunchPart.toolbar => sequence.toolbar,
        LaunchPart.composer => sequence.composer,
        LaunchPart.content => sequence.content,
      };
      target.key = anchor;
      target.radius = widget.radius;
      target.backdrop = ChatBackdropScope.maybeOf(context);
    }
    return KeyedSubtree(key: anchor, child: widget.child);
  }
}

/// One cold-start sequence. No overlays or animations are restarted on resume.
class LaunchHost extends StatefulWidget {
  const LaunchHost({
    super.key,
    required this.artwork,
    required this.child,
    required this.accent,
    required this.dark,
    this.reduceMotion = false,
    this.onComplete,
  });
  final LaunchArtwork artwork;
  final Widget child;
  final Color accent;
  final bool dark, reduceMotion;
  final VoidCallback? onComplete;
  @override
  State<LaunchHost> createState() => _LaunchHostState();
}

class _LaunchHostState extends State<LaunchHost>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _sequence = _LaunchSequence(_animation);
  bool _active = true;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced =
        widget.reduceMotion ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (reduced || !_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_active) return;
        if (reduced) {
          _finish();
        } else {
          _animation.forward();
        }
      });
    }
  }

  @override
  void didUpdateWidget(LaunchHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion && _active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finish();
      });
    }
  }

  void _finish() {
    if (!_active || !mounted) return;
    setState(() => _active = false);
    _animation.value = 1;
    widget.onComplete?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _finish();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LaunchScope(
    sequence: _sequence,
    enabled: _active,
    child: AnimatedBuilder(
      animation: _animation,
      child: Stack(
        key: _sequence.overlayKey,
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: ExcludeSemantics(excluding: _active, child: widget.child),
          ),
          if (_active)
            Positioned.fill(
              child: Semantics(
                label: 'Skivu 正在启动',
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: const ValueKey('skivu-launch-overlay'),
                    painter: _LaunchPainter(
                      _sequence,
                      widget.artwork,
                      widget.accent,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      builder: (context, child) {
        final lightBars = _animation.value < .60 || widget.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: lightBars
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: lightBars
                ? Brightness.light
                : Brightness.dark,
          ),
          child: AbsorbPointer(absorbing: _active, child: child),
        );
      },
    ),
  );
}

class _LaunchPainter extends CustomPainter {
  _LaunchPainter(this.sequence, this.artwork, this.accent)
    : super(repaint: sequence.animation);
  final _LaunchSequence sequence;
  final LaunchArtwork artwork;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final n = sequence.animation.value;
    // Blend only a stable wallpaper texture over each region. No opacity layer
    // is inserted into the live glass scene or around platform-view plugins.
    _conceal(
      canvas,
      sequence.content,
      1 - _ease(n, .67, .94),
      excludeControls: true,
    );
    _conceal(canvas, sequence.toolbar, 1 - _ease(n, .52, .79));
    _conceal(canvas, sequence.composer, 1 - _ease(n, .64, .97));
    final cover = 1 - _ease(n, .36, .69);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: cover),
    );
    final scale = (size.width / 390).clamp(.65, 1.4);
    final flight = _ease(n, .38, .69);
    final center = Offset(
      size.width / 2,
      ui.lerpDouble(size.height * .425, size.height * .32 + 25, flight)!,
    );
    final cloudSize = ui.lerpDouble(172 * scale, 50, flight)!;
    final cloudAlpha = _ease(n, .29, .40) * (1 - _ease(n, .78, .94));
    final glow = Paint()
      ..shader = ui.Gradient.radial(center, 170 * scale, [
        const Color(0xff7dbfde).withValues(alpha: .10 * cover),
        Colors.transparent,
      ]);
    canvas.drawCircle(center, 170 * scale, glow);
    final formed = _ease(n, .02, .34), fade = (1 - _ease(n, .30, .40)) * cover;
    final angle = (1 - formed) * .75,
        cos = math.cos(angle),
        sin = math.sin(angle);
    final paint = Paint();
    for (final seed in artwork.particles) {
      if (fade <= 0) break;
      final r = seed.random;
      final join = _ease(n, .01 + r * .05, .29 + r * .05);
      final v = seed.direction;
      final start = Offset(
        v.dx * cos - v.dy * sin,
        (v.dx * sin + v.dy * cos) * .74,
      );
      final point =
          center +
          start * ((140 + 110 * r) * scale * (1 - join)) +
          seed.target * (cloudSize * join);
      paint.color =
          (seed.blue ? const Color(0xffb4e1ff) : const Color(0xfff4fbff))
              .withValues(alpha: (.35 + .65 * r) * fade);
      canvas.drawCircle(point, (.7 + 1.4 * r) * scale, paint);
    }
    if (cloudAlpha > 0) {
      paint
        ..color = Colors.white.withValues(alpha: cloudAlpha)
        ..filterQuality = FilterQuality.medium;
      canvas.drawImageRect(
        artwork.mask,
        Rect.fromLTWH(
          0,
          0,
          artwork.mask.width.toDouble(),
          artwork.mask.height.toDouble(),
        ),
        Rect.fromCenter(center: center, width: cloudSize, height: cloudSize),
        paint,
      );
    }
    final top = _outline(sequence.toolbar),
        bottom = _outline(sequence.composer);
    // Equal pixel speed for the real control sizes, including compact input.
    final speed = math.max((top?.$2 ?? 0) / .27, (bottom?.$2 ?? 0) / .33);
    _wake(
      canvas,
      top,
      _clamp((n - .52) * speed / (top?.$2 ?? 1)),
      (1 - _ease(n, .79, .90)) * .85,
    );
    _wake(
      canvas,
      bottom,
      _clamp((n - .64) * speed / (bottom?.$2 ?? 1)),
      (1 - _ease(n, .96, 1)) * .85,
    );
  }

  (ui.PathMetric, double)? _outline(_LaunchTarget target) {
    final rect = sequence.bounds(target);
    if (rect == null || rect.isEmpty) return null;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(.8),
          Radius.circular(target.radius),
        ),
      );
    final metric = path.computeMetrics().first;
    return (metric, metric.length);
  }

  void _conceal(
    Canvas canvas,
    _LaunchTarget target,
    double opacity, {
    bool excludeControls = false,
  }) {
    if (opacity <= 0) return;
    final backdrop = target.backdrop;
    final image = backdrop?.wallpaperImage;
    final rect = sequence.bounds(target);
    final scene = backdrop == null
        ? null
        : sequence.keyBounds(backdrop.backgroundKey);
    if (image == null || rect == null || scene == null || rect.isEmpty) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(target.radius)),
    );
    if (excludeControls) {
      var region = Path()..addRect(rect);
      for (final control in [sequence.toolbar, sequence.composer]) {
        final bounds = sequence.bounds(control);
        if (bounds != null) {
          region = Path.combine(
            PathOperation.difference,
            region,
            Path()..addRRect(
              RRect.fromRectAndRadius(bounds, Radius.circular(control.radius)),
            ),
          );
        }
      }
      canvas.clipPath(region);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      scene,
      Paint()
        ..color = Colors.white.withValues(alpha: opacity)
        ..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  void _wake(
    Canvas canvas,
    (ui.PathMetric, double)? outline,
    double progress,
    double opacity,
  ) {
    if (outline == null || progress <= 0 || opacity <= 0) return;
    final path = outline.$1.extractPath(0, outline.$2 * progress);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = accent.withValues(alpha: opacity * .35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawPath(path, paint);
    paint
      ..strokeWidth = 1.2
      ..color = accent.withValues(alpha: opacity)
      ..maskFilter = null;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LaunchPainter oldDelegate) =>
      oldDelegate.artwork != artwork || oldDelegate.accent != accent;
}
