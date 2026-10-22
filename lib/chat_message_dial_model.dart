// User-authorized original module migration; see MODULE-MIGRATION.md.
import 'dart:math' as math;

enum DialScale { fine, medium, fast }

/// Relative, multi-turn navigation. A slow full turn always means 24 messages,
/// independent of history size. Reversal clears acceleration immediately.
class MessageDial {
  MessageDial({required this.count, required int index, required double angle})
    : position = index.toDouble(),
      _angle = angle;
  final int count;
  double position, _angle;
  double rotation = 0, _speed = 0, _directionAge = 0;
  int _direction = 0;
  DialScale scale = DialScale.fine;
  int get index => position.round().clamp(0, math.max(0, count - 1));
  double get messagesPerTurn => switch (scale) {
    DialScale.fine => 24,
    DialScale.medium => math.max(240, count * .02),
    DialScale.fast => math.max(2400, count * .5),
  };

  void reanchor(double angle) {
    _angle = angle;
    _direction = 0;
    _directionAge = 0;
    _speed = 0;
    scale = DialScale.fine;
  }

  void move(double angle, Duration elapsed) {
    var delta = angle - _angle;
    _angle = angle;
    if (delta > math.pi) delta -= math.pi * 2;
    if (delta < -math.pi) delta += math.pi * 2;
    if (delta.abs() < .0001) return;
    final direction = delta.sign.toInt();
    final seconds = elapsed.inMicroseconds / 1000000;
    if (seconds <= 0) return;
    if (_direction != direction || seconds > .3) {
      _speed = 0;
      _directionAge = 0;
      scale = DialScale.fine;
      position = index.toDouble();
    }
    _direction = direction;
    _directionAge += math.min(seconds, .1);
    final blend = 1 - math.exp(-seconds / .08);
    _speed += (delta.abs() / seconds - _speed) * blend;
    if (_directionAge >= .12) {
      scale = switch (scale) {
        DialScale.fine when _speed > 1.8 => DialScale.medium,
        DialScale.medium when _speed > 4.5 => DialScale.fast,
        DialScale.medium when _speed < 1.1 => DialScale.fine,
        DialScale.fast when _speed < 3 => DialScale.medium,
        _ => scale,
      };
    }
    rotation += delta;
    // Clamp the accumulator too: no hidden turns to unwind at either edge.
    position = (position + delta / (2 * math.pi) * messagesPerTurn).clamp(
      0.0,
      math.max(0, count - 1).toDouble(),
    );
  }
}
