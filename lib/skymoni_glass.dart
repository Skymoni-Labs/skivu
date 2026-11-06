import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

enum SkymoniGlassKind { control, readable, navigation }

class SkymoniGlassProgram {
  static ui.FragmentProgram? program;
  static Future<void>? _pending;
  static Future<void> load() => _pending ??= () async {
    try {
      program = await ui.FragmentProgram.fromAsset(
        'shaders/skymoni_glass.frag',
      );
    } catch (_) {
      program = null;
    }
  }();
  static bool get available =>
      program != null && ui.ImageFilter.isShaderFilterSupported;
}

/// Shares motion without rebuilding every lens and its child on each drag tick.
/// Shader render objects listen directly and only invalidate their paint.
class SkymoniGlassMotionScope extends InheritedWidget {
  const SkymoniGlassMotionScope({
    super.key,
    required this.motion,
    required super.child,
  });
  final Listenable motion;
  @override
  bool updateShouldNotify(SkymoniGlassMotionScope oldWidget) =>
      motion != oldWidget.motion;
}

class SkymoniGlassSurface extends StatelessWidget {
  const SkymoniGlassSurface({
    super.key,
    required this.child,
    required this.radius,
    required this.dark,
    this.kind = SkymoniGlassKind.control,
  });
  final Widget child;
  final double radius;
  final bool dark;
  final SkymoniGlassKind kind;
  @override
  Widget build(BuildContext context) {
    final motionScope = context
        .dependOnInheritedWidgetOfExactType<SkymoniGlassMotionScope>();
    return SkymoniGlassFrame(
      radius: radius,
      dark: dark,
      kind: kind,
      optics: _SkymoniFilter(
        program: SkymoniGlassProgram.program!,
        radius: radius,
        dark: dark,
        kind: kind,
        dpr: MediaQuery.devicePixelRatioOf(context),
        motion: motionScope?.motion,
        child: const SizedBox.expand(),
      ),
      child: child,
    );
  }
}

/// One optical layer for idle, scroll and drawer motion. The frame never swaps
/// backends or remounts its foreground, and creates no Android platform views.
class SkymoniGlassFrame extends StatelessWidget {
  const SkymoniGlassFrame({
    super.key,
    required this.radius,
    required this.dark,
    required this.kind,
    required this.optics,
    required this.child,
  });
  final double radius;
  final bool dark;
  final SkymoniGlassKind kind;
  final Widget optics, child;
  @override
  Widget build(BuildContext context) => CustomPaint(
    // Paint the shadow LAST and outside the lens. A BoxShadow behind a
    // transparent backdrop lens fills its interior and feeds its own dark
    // paint into the optical sampler, producing a gray sheet while moving.
    foregroundPainter: _SkymoniOuterShadow(radius, dark),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        children: [
          Positioned.fill(child: IgnorePointer(child: optics)),
          SkymoniGlassCoating(
            dark: dark,
            radius: radius,
            kind: kind,
            child: child,
          ),
        ],
      ),
    ),
  );
}

class _SkymoniOuterShadow extends CustomPainter {
  const _SkymoniOuterShadow(this.radius, this.dark);
  final double radius;
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final lens = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(48))
      ..addRRect(lens);
    canvas.save();
    canvas.clipPath(outside);
    canvas.drawRRect(
      lens.shift(const Offset(0, 6)),
      Paint()
        ..color = const Color(0xff142839).withValues(alpha: dark ? .14 : .06)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 13.202),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SkymoniOuterShadow oldDelegate) =>
      radius != oldDelegate.radius || dark != oldDelegate.dark;
}

/// Skymoni's original coating: only its subtle gradient and hairline rim.
class SkymoniGlassCoating extends StatelessWidget {
  const SkymoniGlassCoating({
    super.key,
    required this.dark,
    required this.radius,
    required this.kind,
    required this.child,
  });
  final bool dark;
  final double radius;
  final SkymoniGlassKind kind;
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: dark ? .047 : .106),
          Colors.transparent,
          Colors.white.withValues(alpha: dark ? .024 : .039),
        ],
      ),
      border: Border.all(
        color: Colors.white.withValues(alpha: dark ? .161 : .38),
        width: .55,
      ),
    ),
    child: child,
  );
}

class _SkymoniFilter extends SingleChildRenderObjectWidget {
  const _SkymoniFilter({
    required this.program,
    required this.radius,
    required this.dark,
    required this.kind,
    required this.dpr,
    required this.motion,
    required super.child,
  });
  final ui.FragmentProgram program;
  final double radius, dpr;
  final bool dark;
  final SkymoniGlassKind kind;
  final Listenable? motion;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSkymoniFilter(program, radius, dpr, dark, kind, motion);
  @override
  void updateRenderObject(BuildContext context, _RenderSkymoniFilter r) =>
      r.update(radius, dpr, dark, kind, motion);
}

class _RenderSkymoniFilter extends RenderProxyBox {
  _RenderSkymoniFilter(
    ui.FragmentProgram program,
    this.radius,
    this.dpr,
    this.dark,
    this.kind,
    this.motion,
  ) : shader = program.fragmentShader();
  final ui.FragmentShader shader;
  final LayerHandle<BackdropFilterLayer> _blurLayer = LayerHandle();
  ui.ImageFilter? _frostFilter;
  double? _frostSigma;
  double radius, dpr;
  bool dark;
  SkymoniGlassKind kind;
  Listenable? motion;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    motion?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    motion?.removeListener(markNeedsPaint);
    super.detach();
  }

  void update(
    double r,
    double density,
    bool isDark,
    SkymoniGlassKind variant,
    Listenable? nextMotion,
  ) {
    if (radius == r &&
        dpr == density &&
        dark == isDark &&
        kind == variant &&
        motion == nextMotion)
      return;
    if (motion != nextMotion) {
      if (attached) motion?.removeListener(markNeedsPaint);
      motion = nextMotion;
      if (attached) motion?.addListener(markNeedsPaint);
    }
    radius = r;
    dpr = density;
    dark = isDark;
    kind = variant;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;
  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    // ImageFiltered introduces a separate coordinate surface while scrolling.
    // Its composited layer, rather than a private widget type, identifies it.
    RenderObject? subpass;
    for (RenderObject? node = parent; node != null; node = node.parent) {
      // ignore: invalid_use_of_protected_member
      if (node.layer is ImageFilterLayer) {
        subpass = node;
        break;
      }
    }
    // Map the local plane projectively, including ancestor transforms.
    final t = getTransformTo(subpass), plane = Matrix4.identity();
    for (final row in [0, 1, 3])
      for (final col in [0, 1, 3]) plane.setEntry(row, col, t.entry(row, col));
    final inverse = Matrix4.copy(plane);
    if (inverse.invert() == 0) {
      super.paint(context, offset);
      return;
    }
    shader.setFloat(2, size.width * dpr);
    shader.setFloat(3, size.height * dpr);
    var index = 4;
    for (final matrix in [plane, inverse])
      for (final col in [0, 1, 3])
        for (final row in [0, 1, 3])
          shader.setFloat(index++, matrix.entry(row, col));
    final readable = kind == SkymoniGlassKind.readable,
        navigation = kind == SkymoniGlassKind.navigation;
    shader.setFloat(22, 0);
    shader.setFloat(23, 0);
    shader.setFloat(24, dpr);
    shader.setFloat(25, radius.clamp(0, size.shortestSide / 2) * dpr);
    shader.setFloat(26, (navigation ? 15 : 11) * dpr);
    shader.setFloat(27, (navigation ? 29 : 19) * dpr);
    shader.setFloat(28, dark ? 1 : 0);
    shader.setFloat(
      29,
      (dark ? (readable ? 95 : 55) : (readable ? 108 : 32)) / 255,
    );
    shader.setFloat(30, (dark ? 16 : 36) / 255);
    // Skymoni's exact regular-material blur: quantized physical pixels,
    // blurAmount .20 for readable input and .025 for navigation/control.
    final blurPhysical =
        (((dark ? 4 : 12) + (readable ? .20 : .025) * 32) * 2).floor() / 2;
    // Separate sibling passes keep the shader in screen/subpass coordinates.
    // ImageFilter.compose rebases fragments onto a cropped blur intermediate,
    // which otherwise moves the lens mask away from the widget's actual clip.
    final frost = _blurLayer.layer ??= BackdropFilterLayer();
    final sigma = blurPhysical / dpr;
    if (_frostSigma != sigma) {
      _frostSigma = sigma;
      _frostFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.clamp,
      );
    }
    frost.filter = _frostFilter;
    context.pushLayer(frost, (context, offset) {}, offset);
    final backdrop = layer is BackdropFilterLayer
        ? layer! as BackdropFilterLayer
        : BackdropFilterLayer();
    backdrop.filter = ui.ImageFilter.shader(shader);
    backdrop.blendMode = BlendMode.srcOver;
    layer = backdrop;
    context.pushLayer(backdrop, super.paint, offset);
  }

  @override
  void dispose() {
    _blurLayer.layer = null;
    shader.dispose();
    super.dispose();
  }
}
