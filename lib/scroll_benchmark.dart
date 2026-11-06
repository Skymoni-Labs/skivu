import 'package:flutter/material.dart';

/// Local QA builds only. Exercises the real transcript and glass at the same
/// distance/duration on both builds, without sending or editing any messages.
class ScrollBenchmark extends StatefulWidget {
  const ScrollBenchmark({
    super.key,
    required this.controller,
    required this.onStart,
  });
  static const enabled = bool.fromEnvironment('SKIVU_SCROLL_BENCHMARK');
  final ScrollController controller;
  final VoidCallback onStart;
  @override
  State<ScrollBenchmark> createState() => _ScrollBenchmarkState();
}

class _ScrollBenchmarkState extends State<ScrollBenchmark> {
  bool _running = false;
  String _label = '滚动采样';
  Future<void> _run() async {
    if (_running || !widget.controller.hasClients) return;
    widget.onStart();
    setState(() {
      _running = true;
      _label = '采样中';
    });
    debugPrint('SkivuScroll benchmark begin');
    try {
      for (var i = 0; i < 4 && mounted; i++) {
        final position = widget.controller.position;
        await widget.controller.animateTo(
          i.isEven ? position.minScrollExtent : position.maxScrollExtent,
          duration: const Duration(milliseconds: 2400),
          curve: Curves.linear,
        );
        await Future<void>.delayed(const Duration(milliseconds: 240));
      }
    } finally {
      debugPrint('SkivuScroll benchmark end');
      if (mounted)
        setState(() {
          _running = false;
          _label = '采样完成';
        });
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.tonal(
    onPressed: _running ? null : _run,
    child: Text(_label),
  );
}
