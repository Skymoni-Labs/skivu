import 'dart:async';
import 'package:flutter/widgets.dart';
import 'drawer_frame_diagnostics.dart';

/// Keeps the optical compositor in its direct-rendered path for a complete
/// touch/ballistic/wheel sequence. Quiet time bridges brief stops and reversals.
/// Only activity edges notify lenses; scroll offsets never rebuild the scene.
class ScrollGlassActivity extends ChangeNotifier {
  ScrollGlassActivity({this.quietTime = const Duration(milliseconds: 300)});
  final Duration quietTime;
  final _sources = <Object>{};
  final _frames = DrawerFrameDiagnostics(scope: 'scroll');
  Timer? _restore;
  bool _busy = false, _disposed = false;
  bool get busy => _busy;

  void begin(Object source) {
    if (_disposed) return;
    _sources.add(source);
    _restore?.cancel();
    _restore = null;
    if (_busy) return;
    _busy = true;
    _frames.motion(true, 0);
    notifyListeners();
  }

  void end(Object source) {
    if (_disposed || !_sources.remove(source) || _sources.isNotEmpty) return;
    _restore?.cancel();
    _restore = Timer(quietTime, () {
      if (_disposed || _sources.isNotEmpty) return;
      _restore = null;
      _busy = false;
      _frames.motion(false, 0);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _restore?.cancel();
    _sources.clear();
    _frames.dispose();
    super.dispose();
  }
}

/// Activity is deliberately not an InheritedNotifier: scrolling must not
/// invalidate the transcript, paragraphs, editable draft or module widgets.
class ScrollGlassScope extends InheritedWidget {
  const ScrollGlassScope({
    super.key,
    required this.activity,
    required super.child,
  });
  final ScrollGlassActivity activity;
  static ScrollGlassActivity? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScrollGlassScope>()?.activity;
  @override
  bool updateShouldNotify(ScrollGlassScope oldWidget) =>
      activity != oldWidget.activity;
}

/// Only actual scroll displacement switches the optical backend. Taps, holds,
/// touch jitter and a zero-distance drag leave the resting glass unchanged.
/// Ballistic scrolling retains activity until ScrollEnd; disposal releases it.
class ScrollGlassSurface extends StatefulWidget {
  const ScrollGlassSurface({super.key, required this.child});
  final Widget child;
  @override
  State<ScrollGlassSurface> createState() => _ScrollGlassSurfaceState();
}

class _ScrollGlassSurfaceState extends State<ScrollGlassSurface> {
  ScrollGlassActivity? _activity;
  final _scrollToken = Object();
  bool _scrolling = false;
  double _scrollStart = 0;
  int _updates = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ScrollGlassScope.maybeOf(context);
    if (next == _activity) return;
    if (_scrolling) {
      _activity?.end(_scrollToken);
      next?.begin(_scrollToken);
    }
    _activity = next;
  }

  bool _scroll(ScrollNotification event) {
    if (event.depth != 0 || event.metrics.axis != Axis.vertical) return false;
    if (event is ScrollStartNotification) {
      if (DrawerFrameDiagnostics.enabled) {
        _scrollStart = event.metrics.pixels;
        _updates = 0;
      }
    } else if (event is ScrollUpdateNotification &&
        (event.scrollDelta?.abs() ?? 0) > .01) {
      if (!_scrolling) {
        _scrolling = true;
        _activity?.begin(_scrollToken);
      }
      if (DrawerFrameDiagnostics.enabled) _updates++;
    } else if (event is ScrollEndNotification && _scrolling) {
      _scrolling = false;
      if (DrawerFrameDiagnostics.enabled) {
        debugPrint(
          'SkivuScroll start=$_scrollStart end=${event.metrics.pixels} updates=$_updates',
        );
      }
      _activity?.end(_scrollToken);
    }
    return false;
  }

  @override
  void dispose() {
    if (_scrolling) _activity?.end(_scrollToken);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scroll,
        child: widget.child,
      );
}
