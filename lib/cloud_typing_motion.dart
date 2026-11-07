import 'dart:math' as math;

/// One wrist stroke: lift, accelerate onto a key, compress, rebound, settle.
/// Coordinates are in the original artwork, not widget/screen pixels.
class CloudTypingStroke {
  const CloudTypingStroke({
    this.height = 0,
    this.roll = 0,
    this.reach = 0,
    this.press = 0,
  });
  final double height, roll, reach, press;
  static const period = 1.6;

  static CloudTypingStroke sample(double seconds, int side) {
    final time = seconds % period;
    final beats = side == 0 ? const [.22, .62, 1.02] : const [.42, .82, 1.22];
    var height = 0.0, press = 0.0;
    for (final beat in beats) {
      final t = time - (beat - .16);
      if (t < 0 || t > .32) continue;
      if (t < .10) {
        final p = t / .10;
        height = 6.5 * (1 - math.pow(1 - p, 3));
      } else if (t < .16) {
        final p = (t - .10) / .06;
        height = 6.5 * (1 - p * p);
      } else if (t < .185) {
        press = math.sin((t - .16) / .025 * math.pi);
        height = -1.15 * press;
      } else if (t < .235) {
        height = 2.3 * math.sin((t - .185) / .05 * math.pi / 2);
      } else {
        final p = (t - .235) / .085;
        height = 2.3 * (1 - p) * (1 - p);
      }
      break;
    }
    // The mostly occluded far wrist has a smaller travel, like the reference.
    final scale = side == 0 ? 1.0 : .45;
    return CloudTypingStroke(
      height: height * scale,
      roll: (-height / 6.5 * .065 + press * .012) * scale,
      reach: (height > 0 ? -.6 * height / 6.5 : press * 1.8) * scale,
      press: press,
    );
  }
}
