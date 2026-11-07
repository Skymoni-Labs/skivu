import 'dart:math' as math;
import 'dart:ui';

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
        height = 24.0 * (1 - math.pow(1 - p, 3));
      } else if (t < .16) {
        final p = (t - .10) / .06;
        height = 24 * (1 - p * p);
      } else if (t < .185) {
        press = math.sin((t - .16) / .025 * math.pi);
        height = -1.4 * press;
      } else if (t < .235) {
        height = 6 * math.sin((t - .185) / .05 * math.pi / 2);
      } else {
        final p = (t - .235) / .085;
        height = 6 * (1 - p) * (1 - p);
      }
      break;
    }
    final scale = side == 0 ? 1.0 : .92;
    return CloudTypingStroke(
      height: height * scale,
      roll: (-height / 24 * .28 + press * .025) * scale,
      reach: (height > 0 ? -3 * height / 24 : press * .7) * scale,
      press: press,
    );
  }
}

/// A two-bone arm with a rigid mitten. Every hand point shares one transform;
/// neither the hand nor the character image is stretched to simulate a tap.
class CloudTypingArm {
  const CloudTypingArm({
    required this.shoulder,
    required this.elbow,
    required this.wrist,
    required this.fingertip,
    required this.pitch,
    required this.stroke,
  });
  final Offset shoulder, elbow, wrist, fingertip;
  final double pitch;
  final CloudTypingStroke stroke;
  static const upperLength = 27.0, foreLength = 31.0;
  static const localTip = Offset(18, 10);
  static Offset key(int side) =>
      side == 0 ? const Offset(170, 334) : const Offset(204, 330);

  static CloudTypingArm sample(double seconds, int side, {bool moving = true}) {
    final stroke = moving
        ? CloudTypingStroke.sample(seconds, side)
        : const CloudTypingStroke();
    final pitch = stroke.roll;
    final fingertip = key(side) + Offset(stroke.reach, -stroke.height);
    final c = math.cos(pitch), s = math.sin(pitch);
    final wrist =
        fingertip -
        Offset(
          localTip.dx * c - localTip.dy * s,
          localTip.dx * s + localTip.dy * c,
        );
    final shoulder = side == 0
        ? const Offset(133, 285)
        : const Offset(215, 285);
    final delta = wrist - shoulder;
    final distance = delta.distance;
    final along =
        (upperLength * upperLength -
            foreLength * foreLength +
            distance * distance) /
        (2 * distance);
    final height = math.sqrt(
      math.max(0, upperLength * upperLength - along * along),
    );
    final unit = delta / distance;
    final bend = side == 0 ? 1.0 : -1.0;
    final elbow =
        shoulder + unit * along + Offset(-unit.dy, unit.dx) * height * bend;
    return CloudTypingArm(
      shoulder: shoulder,
      elbow: elbow,
      wrist: wrist,
      fingertip: fingertip,
      pitch: pitch,
      stroke: stroke,
    );
  }
}
