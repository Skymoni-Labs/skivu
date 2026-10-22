import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'package:characters/characters.dart';

/// Decouples network packet boundaries from display frames. The complete
/// received prefix is retained on stop; only its presentation is paced.
class StreamReveal {
  StreamReveal(this.onReveal);
  final void Function(String text, String thinking) onReveal;
  final _pending = Queue<(String, bool)>();
  Timer? _timer;
  Completer<void>? _drained;
  bool _disposed = false;

  void add(String text, String thinking) {
    if (_disposed) return;
    _pending.addAll(thinking.characters.map((c) => (c, true)));
    _pending.addAll(text.characters.map((c) => (c, false)));
    if (_pending.isNotEmpty) {
      _timer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _tick(),
      );
    }
  }

  void _tick({bool all = false}) {
    if (_disposed) return;
    final count = all
        ? _pending.length
        : math.min(16, math.max(1, (_pending.length / 30).ceil()));
    final text = StringBuffer(), thinking = StringBuffer();
    for (var i = 0; i < count && _pending.isNotEmpty; i++) {
      final (value, reason) = _pending.removeFirst();
      (reason ? thinking : text).write(value);
    }
    if (text.isNotEmpty || thinking.isNotEmpty)
      onReveal(text.toString(), thinking.toString());
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
      if (_drained?.isCompleted == false) _drained!.complete();
    }
  }

  Future<void> finish() {
    if (_pending.isEmpty || _disposed) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  void flush() => _tick(all: true);
  void dispose() {
    _timer?.cancel();
    _pending.clear();
    _disposed = true;
    if (_drained?.isCompleted == false) _drained!.complete();
  }
}
