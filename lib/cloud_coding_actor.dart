import 'dart:math' as math;
import 'dart:ui';
import 'cloud_companion_reference.dart';
import 'cloud_typing_motion.dart';

/// Articulated coding scene: separate rigid head, torso, two two-bone arms,
/// rigid mittens, keyboard and foreground screen. No image/mesh warping.
class CloudCodingActor {
  static const outline = Color(0xff299cda);
  static final skin = Gradient.linear(
    const Offset(0, 280),
    const Offset(0, 346),
    const [Color(0xffe1f5ff), Color(0xfffffefa), Color(0xffc9ebfb)],
    const [0, .55, 1],
  );
  static final palm = Path()
    ..moveTo(-11, 4)
    ..cubicTo(-17, -2, -13, -13, -4, -16)
    ..cubicTo(5, -20, 17, -13, 23, -5)
    ..cubicTo(30, 5, 26, 10, 18, 10)
    ..cubicTo(5, 11, -6, 10, -11, 4)
    ..close();

  static void shape(Canvas canvas, Path path, Paint fill, {double width = 3}) {
    canvas.drawPath(path, fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round,
    );
  }

  static void paint(
    Canvas canvas,
    CloudReferenceScene scene,
    double seconds,
    bool moving,
  ) {
    final arms = [
      CloudTypingArm.sample(seconds, 0, moving: moving),
      CloudTypingArm.sample(seconds, 1, moving: moving),
    ];
    final texture = scene.texture!;
    final imagePaint = Paint()..filterQuality = FilterQuality.high;
    // A complete desk remains behind the actor, including newly uncovered areas.
    canvas.drawOval(
      const Rect.fromLTWH(34, 394, 327, 21),
      Paint()..color = const Color(0xffbddff9).withValues(alpha: .65),
    );
    final front = Path()
      ..moveTo(57, 357)
      ..lineTo(337, 357)
      ..lineTo(337, 404)
      ..quadraticBezierTo(192, 419, 57, 404)
      ..close();
    canvas.drawPath(
      front,
      Paint()
        ..shader = Gradient.linear(
          const Offset(60, 0),
          const Offset(337, 0),
          const [Color(0xffb4ddf8), Color(0xffe3f3ff), Color(0xffa7d4f5)],
          const [0, .6, 1],
        ),
    );
    canvas.drawLine(
      const Offset(57, 365),
      const Offset(57, 403),
      Paint()
        ..color = const Color(0xff83bce9)
        ..strokeWidth = 2.5,
    );
    canvas.drawLine(
      const Offset(337, 365),
      const Offset(337, 403),
      Paint()
        ..color = const Color(0xff83bce9)
        ..strokeWidth = 2.5,
    );
    final table = RRect.fromRectAndRadius(
      const Rect.fromLTWH(47, 340, 299, 28),
      const Radius.circular(13),
    );
    canvas.drawRRect(
      table,
      Paint()
        ..shader = Gradient.linear(
          const Offset(0, 340),
          const Offset(0, 368),
          const [Color(0xffedfaff), Color(0xffd4edff), Color(0xff95cbf3)],
          const [0, .57, 1],
        ),
    );
    canvas.drawRRect(
      table,
      Paint()
        ..color = const Color(0xff82bcee)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawLine(
      const Offset(62, 345),
      const Offset(330, 345),
      Paint()
        ..color = const Color(0xfff8fdff)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    final torso = Path()
      ..moveTo(144, 279)
      ..cubicTo(124, 288, 119, 315, 131, 339)
      ..quadraticBezierTo(174, 350, 228, 340)
      ..cubicTo(237, 317, 227, 289, 211, 279)
      ..close();
    shape(canvas, torso, Paint()..shader = skin);
    final star = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final radius = i.isEven ? 17.0 : 8.3;
      final x = 188 + math.cos(angle) * radius,
          y = 314 + math.sin(angle) * radius;
      if (i == 0) {
        star.moveTo(x, y);
      } else {
        star.lineTo(x, y);
      }
    }
    star.close();
    shape(canvas, star, Paint()..color = const Color(0xffffe998), width: 2.7);

    // Forearms actually bend as the wrist follows the keys. Lengths stay fixed.
    for (final arm in arms.reversed) {
      final path = Path()
        ..moveTo(arm.shoulder.dx, arm.shoulder.dy)
        ..lineTo(arm.elbow.dx, arm.elbow.dy)
        ..lineTo(arm.wrist.dx, arm.wrist.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 25
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        path,
        Paint()
          ..shader = skin
          ..style = PaintingStyle.stroke
          ..strokeWidth = 19
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Rigid head and eyelids share one neck pivot, never a displacement grid.
    final impact = math.max(arms[0].stroke.press, arms[1].stroke.press);
    final tilt = moving
        ? .008 * math.sin(seconds * math.pi / .8) + impact * .006
        : 0.0;
    canvas.save();
    canvas.translate(184, 285 + impact * .65);
    canvas.rotate(tilt);
    canvas.translate(-184, -285);
    canvas.drawImage(scene.headTexture!, Offset.zero, imagePaint);
    final blink =
        moving &&
        const [.60, 4.60].any((t) => seconds >= t && seconds < t + .13);
    if (blink && scene.lids != null)
      canvas.drawImage(scene.lids!, Offset.zero, imagePaint);
    canvas.restore();

    // A complete, stationary key deck is visible when either paw lifts away.
    final deck = Path()
      ..moveTo(134, 329)
      ..lineTo(224, 326)
      ..lineTo(255, 344)
      ..quadraticBezierTo(207, 354, 158, 347)
      ..close();
    shape(
      canvas,
      deck,
      Paint()
        ..shader = Gradient.linear(
          const Offset(0, 328),
          const Offset(0, 350),
          const [Color(0xffc3e6ff), Color(0xff7fbee9)],
        ),
      width: 2,
    );
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 7; col++) {
        final x = 148.0 + col * 10 + row * 4, y = 330.0 + row * 4.5;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 8, 3),
            const Radius.circular(1),
          ),
          Paint()..color = const Color(0xffebf8ff),
        );
      }
    }
    for (var side = 0; side < 2; side++) {
      final key = CloudTypingArm.key(side), press = arms[side].stroke.press;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: key + Offset(0, press * 1.2),
            width: 11,
            height: 4,
          ),
          const Radius.circular(1),
        ),
        Paint()
          ..color = Color.lerp(
            const Color(0xfff0faff),
            const Color(0xff3b9ed9),
            press,
          )!,
      );
    }

    for (final arm in arms.reversed) {
      final lift = math.max(0.0, arm.stroke.height);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(arm.fingertip.dx - 7, 338),
          width: 31 + lift * .3,
          height: 4 + lift * .07,
        ),
        Paint()
          ..color = const Color(
            0xff377eae,
          ).withValues(alpha: .20 - lift * .004),
      );
      canvas.save();
      canvas.translate(arm.wrist.dx, arm.wrist.dy);
      canvas.rotate(arm.pitch);
      shape(
        canvas,
        palm,
        Paint()
          ..shader = Gradient.radial(
            const Offset(0, -7),
            30,
            const [Color(0xfffffefa), Color(0xfff7fcff), Color(0xffc4e8fc)],
            const [0, .55, 1],
          ),
        width: 2.8,
      );
      // Small crease follows the rigid palm, not the body image.
      canvas.drawPath(
        Path()
          ..moveTo(-7, -9)
          ..quadraticBezierTo(0, -14, 7, -10),
        Paint()
          ..color = const Color(0xff7bc2e9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
      canvas.restore();
    }

    // Original foreground screen occludes hands correctly, like a real prop.
    canvas.save();
    canvas.clipPath(
      Path()
        ..moveTo(238, 268)
        ..lineTo(324, 264)
        ..quadraticBezierTo(334, 267, 331, 280)
        ..lineTo(313, 351)
        ..lineTo(207, 352)
        ..lineTo(223, 282)
        ..quadraticBezierTo(225, 270, 238, 268)
        ..close(),
    );
    canvas.drawImage(texture, Offset.zero, imagePaint);
    canvas.restore();
  }
}
