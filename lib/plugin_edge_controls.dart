import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'app_platform.dart';

/// Quiet until an intentional inward pull in the right middle edge.
/// A passive parent listener leaves the content's vertical scrolling untouched.
class PluginEdgeControls extends StatefulWidget {
  const PluginEdgeControls({
    super.key,
    required this.child,
    required this.onExit,
    this.reduceMotion = false,
    this.reportEdge,
  });
  final Widget child;
  final Future<bool> Function() onExit;
  final bool reduceMotion;
  final Future<void> Function(String owner, List<int>? rect)? reportEdge;
  static Rect edgeRegion(Size size) {
    final height = math.min(144.0, size.height * .4);
    return Rect.fromLTWH(
      math.max(0, size.width - 24),
      (size.height - height) / 2,
      math.min(24, size.width),
      height,
    );
  }

  @override
  State<PluginEdgeControls> createState() => _PluginEdgeControlsState();
}

class _PluginEdgeControlsState extends State<PluginEdgeControls> {
  final _surface = GlobalKey();
  final _owner = 'plugin-edge-${DateTime.now().microsecondsSinceEpoch}';
  final _platform = AppPlatform();
  Timer? _idle;
  bool _open = false, _busy = false, _queued = false;
  int? _pointer;
  Offset? _origin;
  Size _size = Size.zero;
  List<int>? _lastEdge;
  Future<void> _report(List<int>? rect) async {
    try {
      await (widget.reportEdge ?? _platform.setPluginEdgeExclusion)(
        _owner,
        rect,
      );
    } catch (_) {
      /* Existing explicit navigation/return entries remain available. */
    }
  }

  void _queueEdge() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final box = _surface.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
      final zone = PluginEdgeControls.edgeRegion(box.size);
      final a = box.localToGlobal(zone.topLeft),
          b = box.localToGlobal(zone.bottomRight);
      final ratio = View.of(context).devicePixelRatio;
      final rect = [
        a.dx,
        a.dy,
        b.dx,
        b.dy,
      ].map((v) => (v * ratio).round()).toList();
      if (_lastEdge != null &&
          List.generate(4, (i) => _lastEdge![i] == rect[i]).every((v) => v))
        return;
      _lastEdge = rect;
      unawaited(_report(rect));
    });
  }

  void _armIdle() {
    _idle?.cancel();
    if (!MediaQuery.accessibleNavigationOf(context)) {
      _idle = Timer(const Duration(seconds: 4), _hide);
    }
  }

  void _show() {
    if (_busy) return;
    _pointer = null;
    setState(() => _open = true);
    _armIdle();
  }

  void _hide() {
    _idle?.cancel();
    if (mounted && !_busy) setState(() => _open = false);
  }

  Rect get _panel => Rect.fromLTWH(
    math.max(0, _size.width - 84),
    (_size.height - 188) / 2,
    76,
    188,
  );
  Offset _local(Offset global) =>
      (_surface.currentContext!.findRenderObject() as RenderBox).globalToLocal(
        global,
      );
  void _down(PointerDownEvent event) {
    if (_pointer != null) {
      _pointer = null;
      return;
    }
    final point = _local(event.position);
    if (_open) {
      if (_panel.contains(point)) {
        _armIdle();
      } else {
        _hide();
      }
      return;
    }
    if (PluginEdgeControls.edgeRegion(_size).contains(point)) {
      _pointer = event.pointer;
      _origin = point;
    }
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    final delta = _local(event.position) - _origin!;
    if (delta.dx > 12 ||
        (delta.dy.abs() > 12 && delta.dy.abs() > delta.dx.abs() * .65)) {
      _pointer = null;
      return;
    }
    if (delta.dx < -44 && delta.dx.abs() > delta.dy.abs() * 2) _show();
  }

  Future<void> _exit() async {
    if (_busy) return;
    _idle?.cancel();
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await widget.onExit();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _open = !ok;
    });
    if (!ok) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('界面切换未完成，请重试。')));
      _armIdle();
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    unawaited(_report(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      _queueEdge();
      final zone = PluginEdgeControls.edgeRegion(_size);
      final reduced =
          widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
      return Listener(
        key: _surface,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: (event) {
          if (_pointer == event.pointer) _pointer = null;
        },
        onPointerCancel: (event) {
          if (_pointer == event.pointer) _pointer = null;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (!_open)
              Positioned.fromRect(
                rect: zone,
                child: Semantics(
                  label: '界面控制，向内拉出',
                  onTap: _show,
                  child: const SizedBox.expand(),
                ),
              ),
            Positioned.fromRect(
              rect: _panel,
              child: IgnorePointer(
                ignoring: !_open,
                child: AnimatedSlide(
                  offset: _open ? Offset.zero : const Offset(1.25, 0),
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _open ? 1 : 0,
                    duration: reduced
                        ? Duration.zero
                        : const Duration(milliseconds: 120),
                    child: ExcludeSemantics(excluding: !_open, child: _rail()),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget _rail() => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Material(
        color: const Color(0xe6f3f5fa),
        child: Container(
          key: const ValueKey('plugin-control-rail'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white70),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 28,
                height: 3,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: const Color(0xffa4acb8),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _exit,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xff17212b),
                  minimumSize: const Size(64, 94),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.exit_to_app_rounded, size: 23),
                    SizedBox(height: 5),
                    Text(
                      '返回\n原版',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '收起界面控制',
                onPressed: _busy ? null : _hide,
                icon: const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xff17212b),
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
