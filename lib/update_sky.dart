import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// One cached still image. Only the small meteor overlay can repaint.
class UpdateSky extends StatelessWidget {
  const UpdateSky({super.key, required this.meteorsEnabled});
  final bool meteorsEnabled;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      RepaintBoundary(
        child: Image.asset(
          'assets/branding/skivu-update-night-20261028.png',
          fit: BoxFit.cover,
          excludeFromSemantics: true,
        ),
      ),
      Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: double.infinity,
          height: math.min(MediaQuery.sizeOf(context).height * .42, 320),
          child: UpdateMeteors(enabled: meteorsEnabled),
        ),
      ),
    ],
  );
}

/// No repeating ticker: a one-shot timer starts a 1.1s flight, then rests.
/// Pausing, covering the route or disabling motion cancels both timer and flight.
class UpdateMeteors extends StatefulWidget {
  const UpdateMeteors({super.key, required this.enabled});
  final bool enabled;

  @override
  State<UpdateMeteors> createState() => _UpdateMeteorsState();
}

class _UpdateMeteorsState extends State<UpdateMeteors>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _flight;
  final _random = math.Random();
  Timer? _rest;
  bool _running = false;
  late bool _foreground;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _flight =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1100),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && _running) {
            _schedule(Duration(seconds: 24 + _random.nextInt(17)));
          }
        });
  }

  void _schedule(Duration delay) {
    _rest?.cancel();
    _rest = Timer(delay, () {
      _rest = null;
      if (!_running || !mounted) return;
      setState(() => _sequence++);
      _flight.forward(from: 0);
    });
  }

  void _sync() {
    final active =
        widget.enabled &&
        _foreground &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (active == _running) return;
    _running = active;
    if (active) {
      _schedule(const Duration(seconds: 8));
    } else {
      _rest?.cancel();
      _rest = null;
      _flight.stop();
      _flight.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant UpdateMeteors oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    _rest?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: ClipRect(
          child: CustomPaint(
            key: const ValueKey('update-meteor-overlay'),
            painter: _MeteorPainter(_flight, _sequence),
          ),
        ),
      ),
    ),
  );
}

class _MeteorPainter extends CustomPainter {
  _MeteorPainter(this.flight, this.sequence) : super(repaint: flight);
  final Animation<double> flight;
  final int sequence;

  @override
  void paint(Canvas canvas, Size size) {
    final t = flight.value;
    if (t <= 0 || t >= 1 || size.isEmpty) return;
    final fade = math.sin(t * math.pi) * .72;
    final start = Offset(
      size.width * (sequence.isEven ? .16 : .6),
      size.height * .4,
    );
    final distance = math.min(size.width * .3, size.height * .8);
    const direction = Offset(1, .65);
    final head = start + direction * (distance * t);
    final tail = head - direction * 46;
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(tail, head, [
          const Color(0x00c1dfff),
          Color.fromRGBO(216, 234, 255, fade),
        ]),
    );
    canvas.drawCircle(
      head,
      1.25,
      Paint()..color = Color.fromRGBO(238, 246, 255, fade),
    );
  }

  @override
  bool shouldRepaint(covariant _MeteorPainter oldDelegate) =>
      oldDelegate.flight != flight || oldDelegate.sequence != sequence;
}
