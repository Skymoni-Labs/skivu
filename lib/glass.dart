import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'drawer_motion.dart';
import 'state.dart';
import 'wallpaper.dart';
import 'glass_preferences.dart';
import 'appearance.dart';
import 'video_backdrop.dart';
import 'chat_backdrop.dart';
import 'sidebar_layout.dart';

/// Web lenses refract one cached capture of the static aurora, rather than
/// capturing the whole application on every drawer animation frame.
class SkiGlassScene extends StatefulWidget {
  const SkiGlassScene({
    super.key,
    required this.child,
    required this.motion,
    this.wallpaperController,
  });
  final Widget child;
  final DrawerMotion motion;
  final WallpaperController? wallpaperController;
  @override
  State<SkiGlassScene> createState() => _SkiGlassSceneState();
}

class _SkiGlassSceneState extends State<SkiGlassScene> {
  final _capture = LiquidGlassViewController();
  final _chatBackdrop = ChatBackdropController();
  bool _dark = demo.dark;
  Size? _size;
  Size? _layoutSize;
  EdgeInsets _viewInsets = EdgeInsets.zero;
  bool _captureQueued = false;
  late bool _refracting;
  String? _paintedWallpaper;
  late String _backdropStyle = _backdropSignature;
  String get _backdropSignature =>
      '${appearance.flag('backgroundEnabled')}/${appearance.text('videoAsset')}/${appearance.number('backgroundOpacity')}/${appearance.number('videoBlur')}/${appearance.number('videoDim')}/${appearance.flag('reduceMotion')}';
  WallpaperController get _wallpaper => widget.wallpaperController ?? wallpaper;

  bool get _canRefract =>
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ||
      widget.motion.offset.abs() < .1 ||
      widget.motion.reducedMotion;

  @override
  void initState() {
    super.initState();
    _refracting = _canRefract;
    widget.motion.addListener(_updateOptics);
    _wallpaper.addListener(_updateWallpaper);
    appearance.addListener(_updateBackdropStyle);
    glassPreferences.addListener(_updateChatBlur);
    _refreshCapture();
  }

  Set<double> get _chatRadii => {
    glassPreferences.userBlur,
    glassPreferences.assistantBlur,
  };

  void _updateChatBlur() => _chatBackdrop.prepare(_chatRadii);

  void _updateBackdropStyle() {
    final next = _backdropSignature;
    if (next == _backdropStyle) return;
    _backdropStyle = next;
    setState(() {});
    _refreshCapture();
  }

  void _updateWallpaper() {
    setState(() {});
    _refreshCapture();
  }

  void _updateOptics() {
    final next = _canRefract;
    if (next != _refracting) setState(() => _refracting = next);
  }

  @override
  void dispose() {
    widget.motion.removeListener(_updateOptics);
    _wallpaper.removeListener(_updateWallpaper);
    appearance.removeListener(_updateBackdropStyle);
    glassPreferences.removeListener(_updateChatBlur);
    _chatBackdrop.dispose();
    super.dispose();
  }

  void _refreshCapture() {
    if (_captureQueued) return;
    _captureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureQueued = false;
      if (mounted) {
        _capture.captureOnce();
        _chatBackdrop.capture(
          revision:
              '${_layoutSize?.width},${_layoutSize?.height}/${_size?.width},${_size?.height}/${_viewInsets.left},${_viewInsets.top},${_viewInsets.right},${_viewInsets.bottom}/$_dark/$_backdropStyle/$_paintedWallpaper/${_wallpaper.data?.id}/${_wallpaper.data?.blur}/${_wallpaper.data?.dim}',
          enabled:
              !kIsWeb &&
              defaultTargetPlatform == TargetPlatform.android &&
              (appearance.text('videoAsset').isEmpty ||
                  !appearance.flag('backgroundEnabled')),
          radii: _chatRadii,
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    if (_size != null && (_size != size || _viewInsets != insets))
      _refreshCapture();
    _size = size;
    _viewInsets = insets;
  }

  @override
  void didUpdateWidget(covariant SkiGlassScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousWallpaper = oldWidget.wallpaperController ?? wallpaper;
    if (previousWallpaper != _wallpaper) {
      previousWallpaper.removeListener(_updateWallpaper);
      _wallpaper.addListener(_updateWallpaper);
      _refreshCapture();
    }
    if (oldWidget.motion != widget.motion) {
      oldWidget.motion.removeListener(_updateOptics);
      widget.motion.addListener(_updateOptics);
    }
    _refracting = _canRefract;
    if (_dark != demo.dark) {
      _dark = demo.dark;
      _refreshCapture();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Scaffold consumes the keyboard inset before passing MediaQuery to its
      // body. Its actual constraints still shrink, so track those as well.
      // Otherwise lenses keep a full-height capture over a cropped wallpaper.
      if (_layoutSize != constraints.biggest) {
        _layoutSize = constraints.biggest;
        _refreshCapture();
      }
      return LiquidGlassView(
        controller: _capture,
        backgroundWidget: RepaintBoundary(
          key: _chatBackdrop.backgroundKey,
          child: _background(),
        ),
        realTimeCapture: false,
        pixelRatio: .75,
        // Each small lens stays in its own plane during the 3D drawer fold.
        batch: false,
        child: ChatBackdropScope(
          controller: _chatBackdrop,
          child: _GlassOpticsScope(
            refracting: _refracting,
            child: widget.child,
          ),
        ),
      );
    },
  );

  Widget _background() {
    final fallback = AuroraBackdrop(dark: demo.dark);
    final video = appearance.text('videoAsset');
    final visible = appearance.flag('backgroundEnabled');
    if (!visible || (video.isEmpty && _wallpaper.data == null)) return fallback;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (appearance.number('backgroundOpacity') < 1) fallback,
        if (visible)
          Opacity(
            opacity: appearance.number('backgroundOpacity'),
            child: video.isEmpty
                ? _wallpaperImage()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      ImageFiltered(
                        enabled: appearance.number('videoBlur') > 0,
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: appearance.number('videoBlur'),
                          sigmaY: appearance.number('videoBlur'),
                          tileMode: ui.TileMode.clamp,
                        ),
                        child: VideoBackdrop(
                          onReady: _refreshCapture,
                          id: video,
                          paused: appearance.flag('reduceMotion'),
                          fallback: fallback,
                        ),
                      ),
                      ColoredBox(
                        color: Colors.black.withValues(
                          alpha: appearance.number('videoDim'),
                        ),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _wallpaperImage() {
    final data = _wallpaper.data;
    if (data == null) {
      _paintedWallpaper = null;
      return AuroraBackdrop(dark: demo.dark);
    }
    return RepaintBoundary(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              enabled: data.blur > 0,
              imageFilter: ui.ImageFilter.blur(
                sigmaX: data.blur,
                sigmaY: data.blur,
                tileMode: ui.TileMode.clamp,
              ),
              child: Image.memory(
                data.bytes,
                key: const ValueKey('custom-wallpaper'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                frameBuilder: (context, image, frame, synchronous) {
                  if (frame != null && _paintedWallpaper != data.id) {
                    _paintedWallpaper = data.id;
                    _refreshCapture();
                  }
                  return image;
                },
                errorBuilder: (context, error, stack) =>
                    AuroraBackdrop(dark: demo.dark),
              ),
            ),
            ColoredBox(
              color: const Color(0xff000000).withValues(
                alpha: (data.dim + (demo.dark ? .12 : 0)).clamp(0, .8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassOpticsScope extends InheritedWidget {
  const _GlassOpticsScope({required this.refracting, required super.child});
  final bool refracting;
  @override
  bool updateShouldNotify(_GlassOpticsScope oldWidget) =>
      refracting != oldWidget.refracting;
}

LiquidGlassStyle skiLensStyle(
  BuildContext context,
  double radius, {
  bool accent = false,
  double blur = 2,
  double? opacity,
}) => LiquidGlassStyle(
  // Only the captured Web path needs the fold workaround. Android's live
  // backdrop keeps the same material across pointer-down, drag and settling.
  liteGlass:
      !(context
              .dependOnInheritedWidgetOfExactType<_GlassOpticsScope>()
              ?.refracting ??
          true),
  shape: radius >= 31
      ? const LiquidGlassShape.roundedRectangle(cornerRadius: 31)
      : LiquidGlassShape.continuousRoundedRectangle(cornerRadius: radius),
  refractionIndex: 1.08,
  refractionWidth: 16,
  blur: blur,
  saturation: 1.12,
  color: accent
      ? const Color(0xff4386aa).withValues(alpha: demo.dark ? .55 : .26)
      : Colors.white.withValues(alpha: opacity ?? (demo.dark ? .50 : .23)),
  specular: const LiquidGlassLight.specular(
    thickness: 2.3,
    intensity: 1.2,
    color: Color(0xcfffffff),
  ),
  glow: const LiquidGlassLight.glow(thickness: 7, intensity: .35),
);

/// The library owns lens optics and touch deformation; app actions stay local.
class SkiGlassButton extends StatelessWidget {
  const SkiGlassButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.label,
    this.width = 44,
    this.height = 44,
    this.accent = false,
    this.plain = false,
    this.startAligned = false,
  });
  final String tooltip;
  final String? label;
  final IconData icon;
  final VoidCallback onPressed;
  final double? width;
  final double height;
  final bool accent;
  final bool plain;
  final bool startAligned;

  Widget? get _alignedContent => !startAligned || label == null
      ? null
      : Row(
          children: [
            SizedBox(width: SidebarLayout.leading, child: Icon(icon, size: 21)),
            const SizedBox(width: SidebarLayout.gap),
            Expanded(
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
  @override
  Widget build(BuildContext context) {
    final foreground = ink;
    if (plain && label == null) {
      return SizedBox(
        width: width,
        height: height,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 21, color: foreground),
        ),
      );
    }
    if (!(demo.prefs['毛玻璃效果'] ?? true)) {
      return Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: SizedBox(
          width: width,
          height: height,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              padding: startAligned
                  ? const EdgeInsets.symmetric(horizontal: SidebarLayout.inset)
                  : EdgeInsets.zero,
            ),
            child:
                _alignedContent ??
                (label == null
                    ? Icon(icon, semanticLabel: tooltip, size: 21)
                    : Text(label!)),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        label: label == null ? tooltip : null,
        button: true,
        child: LiquidGlassButton(
          width: width,
          height: height,
          padding: EdgeInsets.symmetric(
            horizontal: startAligned
                ? SidebarLayout.inset
                : (label == null ? 0 : 18),
          ),
          style: skiLensStyle(context, height / 2, accent: accent),
          touch: (demo.prefs['减少动态效果'] ?? false)
              ? null
              : const LiquidGlassTouch.flexing(LiquidGlassFlex()),
          foregroundColor: foreground,
          label: label,
          icon: icon,
          iconSize: 21,
          fontSize: 15,
          onPressed: onPressed,
          child: _alignedContent,
        ),
      ),
    );
  }
}

/// The side sheets use the same library lens as the floating chrome, with
/// deeper frost and a broad optical rim. The fold scope selects its safe
/// perspective path; refraction is available when the sheet is planar.
class SkiGlassPanel extends StatelessWidget {
  const SkiGlassPanel({
    super.key,
    required this.child,
    this.leftSide = true,
    this.preferences,
  });
  final Widget child;
  final bool leftSide;
  final GlassPreferences? preferences;
  @override
  Widget build(BuildContext context) {
    final model = preferences ?? glassPreferences;
    return AnimatedBuilder(
      animation: Listenable.merge([model, appearance]),
      child: ClipRect(child: child),
      builder: (context, content) => LayoutBuilder(
        builder: (context, constraints) => Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Positioned(
              top: -drawerSurfaceBleed(constraints.maxHeight),
              bottom: -drawerSurfaceBleed(constraints.maxHeight),
              // Extend only past the viewport's outer edge for recoil coverage.
              // At the inner seam, align glass with its content and contact shadow.
              left: leftSide ? -DrawerMotion.maxSettleOvershoot - 6 : 0,
              right: leftSide ? 0 : -DrawerMotion.maxSettleOvershoot - 6,
              child: (demo.prefs['毛玻璃效果'] ?? true)
                  ? LiquidGlassLens(
                      key: const ValueKey('side-sheet-fill'),
                      style: skiLensStyle(context, 18).copyWith(
                        blur: leftSide ? model.leftBlur : model.rightBlur,
                        color: Colors.white.withValues(
                          alpha: appearance.number(
                            leftSide ? 'leftOpacity' : 'rightOpacity',
                          ),
                        ),
                        specular: const LiquidGlassLight.specular(
                          thickness: 2.6,
                          angle: 0,
                          spread: .85,
                          intensity: 1.1,
                          color: Color(0xd9ffffff),
                        ),
                        glow: const LiquidGlassLight.glow(
                          thickness: 12,
                          angle: 0,
                          intensity: .28,
                        ),
                      ),
                      child: const SizedBox.expand(),
                    )
                  : const GlassSurface(
                      key: ValueKey('side-sheet-fill'),
                      radius: 18,
                      opacity: .96,
                      child: SizedBox.expand(),
                    ),
            ),
            content!,
          ],
        ),
      ),
    );
  }
}

/// Repeated content cards use inexpensive translucent paint. Floating chrome
/// opts into the liquid lens; side sheets use SkiGlassPanel above.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 20,
    this.blur = 0,
    this.opacity = .62,
    this.grouped = false,
    this.liquid = false,
    this.liquidBlur = 2,
    this.liquidOpacity,
    this.outline = true,
    this.wallpaperOnly = false,
  });
  final Widget child;
  final double radius, blur, opacity;
  final bool grouped, liquid;
  final double liquidBlur;
  final double? liquidOpacity;
  final bool outline;

  /// Read the scene's wallpaper capture instead of the composited UI. A live
  /// lens can pull nearby avatars across the input's rim even when wallpaper
  /// has already covered the transcript directly underneath it.
  final bool wallpaperOnly;
  @override
  Widget build(BuildContext context) {
    final enabled = demo.prefs['毛玻璃效果'] ?? true;
    if (enabled && liquid) {
      return LiquidGlassLens(
        key: ValueKey(wallpaperOnly),
        useImpellerBackdrop: wallpaperOnly ? false : null,
        style: skiLensStyle(
          context,
          radius,
          blur: liquidBlur,
          opacity: liquidOpacity,
        ),
        child: child,
      );
    }
    final alpha = enabled ? opacity : .96;
    const base = Colors.white;
    final painted = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base.withValues(alpha: (alpha + .12).clamp(0, 1)),
            base.withValues(alpha: alpha),
          ],
        ),
        border: !outline
            ? null
            : Border.all(
                color: demo.dark
                    ? Colors.white.withValues(alpha: .12)
                    : Colors.white.withValues(alpha: .8),
                width: .9,
              ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: enabled && blur > 0
          ? grouped
                ? BackdropFilter.grouped(
                    filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: painted,
                  )
                : BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: painted,
                  )
          : painted,
    );
  }
}

/// Updating optical parameters leaves editable foreground state intact.
class ConfigurableGlassSurface extends StatelessWidget {
  const ConfigurableGlassSurface({
    super.key,
    required this.area,
    required this.child,
    this.radius = 24,
    this.preferences,
  });
  final String area;
  final Widget child;
  final double radius;
  final AppearancePreferences? preferences;
  @override
  Widget build(BuildContext context) {
    final model = preferences ?? appearance;
    return AnimatedBuilder(
      animation: model,
      child: child,
      builder: (context, content) => GlassSurface(
        radius: radius,
        liquid: radius > 0,
        outline: radius > 0,
        blur: model.number(area),
        opacity: model.number(area.replaceFirst('Blur', 'Opacity')),
        liquidBlur: model.number(area),
        liquidOpacity: model.number(area.replaceFirst('Blur', 'Opacity')),
        wallpaperOnly:
            area == 'inputBlur' &&
            ChatBackdropScope.maybeOf(context)?.wallpaperImage != null,
        child: content!,
      ),
    );
  }
}

class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key, required this.dark});
  final bool dark;
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _AuroraPainter(dark),
      child: const SizedBox.expand(),
    ),
  );
}

class _AuroraPainter extends CustomPainter {
  const _AuroraPainter(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  const Color(0xff152033),
                  const Color(0xff202b43),
                  const Color(0xff142738),
                ]
              : [
                  const Color(0xffe7effc),
                  const Color(0xfff2f0fc),
                  const Color(0xffeaf5fa),
                ],
        ).createShader(bounds),
    );
    void glow(Offset center, double radius, Color color) => canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    glow(
      Offset(size.width * .02, size.height * .27),
      size.width * .9,
      dark
          ? const Color(0xff304e78).withValues(alpha: .32)
          : const Color(0xffa8c9ef).withValues(alpha: .36),
    );
    glow(
      Offset(size.width * .95, size.height * .6),
      size.width * .83,
      dark
          ? const Color(0xff604e7a).withValues(alpha: .22)
          : const Color(0xffd3bde9).withValues(alpha: .26),
    );
    glow(
      Offset(size.width * .1, size.height * .93),
      size.width * .8,
      dark
          ? const Color(0xff226f7e).withValues(alpha: .18)
          : const Color(0xffb5e2e7).withValues(alpha: .32),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => dark != old.dark;
}
