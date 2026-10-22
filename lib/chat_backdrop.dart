import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Captures only the wallpaper plane, never the chat or application controls.
/// Static wallpapers can be blurred once instead of reading a live Vulkan
/// backdrop from inside a moving, clipped list item on every scroll frame.
class ChatBackdropController extends ChangeNotifier {
  static const _trace = bool.fromEnvironment('SKIVU_GLASS_TRACE');
  final backgroundKey = GlobalKey();
  ui.Image? _raw;
  final _blurred = <double, ui.Image>{};
  Size logicalSize = Size.zero;
  String? _revision;
  int _generation = 0;
  bool _disposed = false;
  Set<double> _radii = {};

  /// The floating composer refracts wallpaper, not text scrolling behind it.
  ui.Image? get wallpaperImage => _raw;

  ui.Image? imageFor(double blur) {
    if (blur <= 0 || _blurred.isEmpty) return null;
    return _blurred[blur] ??
        _blurred.entries
            .reduce(
              (a, b) => (a.key - blur).abs() <= (b.key - blur).abs() ? a : b,
            )
            .value;
  }

  Future<void> capture({
    required String revision,
    required bool enabled,
    required Set<double> radii,
  }) async {
    if (_disposed) return;
    _radii = radii;
    if (!enabled) {
      if (_trace) debugPrint('Chat frost: live backdrop fallback');
      _generation++;
      _revision = null;
      _clear();
      notifyListeners();
      return;
    }
    if (_revision == revision && _raw != null) {
      await prepare(radii);
      return;
    }
    final boundary = backgroundKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.hasSize ||
        boundary.size.isEmpty)
      return;
    final generation = ++_generation;
    ui.Image? next;
    try {
      next = await boundary.toImage(pixelRatio: 1.5);
      if (_disposed || generation != _generation) {
        next.dispose();
        return;
      }
      _clear();
      _raw = next;
      logicalSize = boundary.size;
      _revision = revision;
      await prepare(_radii);
      if (_trace)
        debugPrint(
          'Chat frost: captured ${next.width}x${next.height}, radii $_radii',
        );
    } catch (error) {
      if (_trace) debugPrint('Chat frost capture: $error');
      // Keep the normal live-backdrop fallback if capture is unavailable.
      if (next != _raw) next?.dispose();
    }
  }

  Future<void> prepare(Set<double> radii) async {
    _radii = radii;
    final raw = _raw;
    if (_disposed || raw == null || logicalSize.isEmpty) return;
    final generation = _generation;
    final scale = raw.width / logicalSize.width;
    for (final radius in radii.where((r) => r > 0)) {
      if (_disposed || generation != _generation) return;
      if (_blurred.containsKey(radius)) continue;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, raw.width.toDouble(), raw.height.toDouble()),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: radius * scale,
            sigmaY: radius * scale,
            tileMode: ui.TileMode.clamp,
          ),
      );
      canvas.drawImage(raw, Offset.zero, Paint());
      canvas.restore();
      final picture = recorder.endRecording();
      ui.Image image;
      try {
        image = await picture.toImage(raw.width, raw.height);
      } finally {
        picture.dispose();
      }
      // Materialize the filtered picture as pixels. A deferred GPU picture
      // must not be re-evaluated differently during a Vulkan scroll frame.
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (pixels != null) {
        final decoded = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
          image.width,
          image.height,
          ui.PixelFormat.rgba8888,
          decoded.complete,
        );
        final raster = await decoded.future;
        image.dispose();
        image = raster;
      }
      if (_disposed || generation != _generation || !_radii.contains(radius)) {
        image.dispose();
        return;
      }
      _blurred.remove(radius)?.dispose();
      _blurred[radius] = image;
    }
    if (_disposed || generation != _generation) return;
    for (final radius in _blurred.keys.toList()) {
      if (!_radii.contains(radius)) _blurred.remove(radius)?.dispose();
    }
    notifyListeners();
  }

  void _clear() {
    _raw?.dispose();
    _raw = null;
    for (final image in _blurred.values) {
      image.dispose();
    }
    _blurred.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _clear();
    super.dispose();
  }
}

class ChatBackdropScope extends InheritedNotifier<ChatBackdropController> {
  const ChatBackdropScope({
    super.key,
    required ChatBackdropController controller,
    required super.child,
  }) : super(notifier: controller);

  static ChatBackdropController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatBackdropScope>()?.notifier;
}

/// Keep the floating input and its footer on wallpaper while the transcript
/// continues behind them. Leave the top gap open to avoid a clipped dark seam.
class ChatComposerBackdrop extends StatelessWidget {
  const ChatComposerBackdrop({
    super.key,
    required this.child,
    this.topInset = 0,
    this.sceneAnchor,
  });
  final Widget child;
  final double topInset;
  final GlobalKey? sceneAnchor;
  @override
  Widget build(BuildContext context) {
    final source = ChatBackdropScope.maybeOf(context);
    final image = source?.wallpaperImage;
    if (source == null || image == null) return child;
    return Stack(
      children: [
        Positioned.fill(
          top: topInset,
          child: ChatBackdropPaint(
            key: const ValueKey('composer-wallpaper-plane'),
            image: image,
            source: source,
            sceneAnchor: sceneAnchor,
            child: const SizedBox.expand(),
          ),
        ),
        child,
      ],
    );
  }
}

class ChatBackdropPaint extends SingleChildRenderObjectWidget {
  const ChatBackdropPaint({
    super.key,
    required this.image,
    required this.source,
    required super.child,
    this.sceneAnchor,
  });
  final ui.Image image;
  final ChatBackdropController source;
  final GlobalKey? sceneAnchor;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChatBackdrop(image, source, sceneAnchor);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderChatBackdrop renderObject,
  ) {
    renderObject.update(image, source, sceneAnchor);
  }
}

class _RenderChatBackdrop extends RenderProxyBox {
  _RenderChatBackdrop(ui.Image image, this.source, this.sceneAnchor)
    : image = image.clone(),
      logicalSize = source.logicalSize;
  ui.Image image;
  ChatBackdropController source;
  GlobalKey? sceneAnchor;
  Size logicalSize;
  void update(
    ui.Image nextImage,
    ChatBackdropController nextSource,
    GlobalKey? nextAnchor,
  ) {
    image.dispose();
    image = nextImage.clone();
    source = nextSource;
    sceneAnchor = nextAnchor;
    logicalSize = source.logicalSize;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Input wallpaper follows its pane through folds; bubbles keep fixed-scene sampling.
    final background =
        sceneAnchor?.currentContext?.findRenderObject() ??
        source.backgroundKey.currentContext?.findRenderObject();
    if (background is RenderBox && background.attached) {
      // Align the wallpaper in scene coordinates, including the viewport's
      // scroll offset and any drawer transform. It must not move with the text.
      final inverse = Matrix4.copy(getTransformTo(background));
      if (inverse.invert() != 0) {
        final canvas = context.canvas;
        canvas.save();
        canvas.translate(offset.dx, offset.dy);
        canvas.clipRect(Offset.zero & size);
        canvas.transform(inverse.storage);
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & logicalSize,
          Paint()..filterQuality = FilterQuality.low,
        );
        canvas.restore();
      }
    }
    super.paint(context, offset);
  }

  @override
  void dispose() {
    image.dispose();
    super.dispose();
  }
}
