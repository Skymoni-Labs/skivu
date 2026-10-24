import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'state.dart';
import 'ui_plugins.dart';

/// The hosted social portrait, including its original local SVG fallback.
/// Real user/role pictures always take precedence over the fallback artwork.
class NativeSocialPortrait extends StatelessWidget {
  const NativeSocialPortrait({
    super.key,
    required this.mode,
    this.persona,
    this.user = false,
    this.size = 38,
    this.large = false,
    this.square,
    this.borderRadius,
    this.bytes,
    this.store,
  });

  final ChatUiMode mode;
  final Persona? persona;
  final bool user, large;
  final double size;
  final bool? square;
  final double? borderRadius;
  final Uint8List? bytes;
  final DemoStore? store;

  @override
  Widget build(BuildContext context) {
    final picture =
        bytes ?? (user ? (store ?? demo).userAvatar : persona?.avatar);
    final radius = appearance.flag('squareAvatars') || square == true
        ? 0.0
        : borderRadius ??
              (mode == ChatUiMode.qq
                  ? size / 2
                  : large
                  ? 7.0
                  : 5.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: picture != null
            ? ColoredBox(
                color: const Color(0xffc8dce7),
                child: Image.memory(
                  picture,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _fallback(),
                ),
              )
            : _fallback(),
      ),
    );
  }

  Widget _fallback() {
    if (!user && persona != null) {
      return ColoredBox(
        color: persona!.color.withAlpha(31),
        child: Center(
          child: Icon(
            persona!.icon,
            size: large ? 43 : 25,
            color: const Color(0xff24332e),
          ),
        ),
      );
    }
    return CustomPaint(painter: _SocialSelfPortrait(user: user));
  }
}

/// Paths and colours from social.js portrait()'s 48×48 SVG. Keep separate from
/// the ordinary Flutter user avatar: the social renderer has distinct artwork.
class _SocialSelfPortrait extends CustomPainter {
  const _SocialSelfPortrait({required this.user});
  final bool user;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 48, size.height / 48);
    final paint = Paint();
    void fill(Path path, Color color) =>
        canvas.drawPath(path, paint..color = color);
    final hair = user ? const Color(0xff4d6e6a) : const Color(0xff4e6471);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 48, 48),
      paint..color = user ? const Color(0xffb2c8c6) : const Color(0xffbdd5da),
    );
    canvas.drawCircle(
      const Offset(36, 11),
      13,
      paint..color = Colors.white.withValues(alpha: .12),
    );
    fill(
      Path()
        ..moveTo(8, 48)
        ..cubicTo(8, 37, 13, 31, 24, 31)
        ..cubicTo(35, 31, 41, 37, 41, 48)
        ..close(),
      user ? const Color(0xff749b9b) : const Color(0xff8babb8),
    );
    fill(
      Path()
        ..moveTo(15, 22)
        ..cubicTo(10, 11, 15, 3, 25, 3)
        ..cubicTo(36, 3, 40, 12, 35, 25)
        ..close(),
      hair,
    );
    canvas.drawOval(
      const Rect.fromLTWH(14, 10, 20, 24),
      paint..color = const Color(0xfff4dfca),
    );
    fill(
      Path()
        ..moveTo(13, 19)
        ..cubicTo(14, 10, 18, 5, 26, 6)
        ..cubicTo(31, 6, 36, 11, 36, 19)
        ..cubicTo(31, 17, 27, 14, 24, 9)
        ..cubicTo(23, 14, 18, 17, 13, 19)
        ..close(),
      hair,
    );
    paint
      ..color = const Color(0xff4f555a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(19, 22)
        ..lineTo(20, 22)
        ..moveTo(29, 22)
        ..lineTo(30, 22),
      paint,
    );
    paint
      ..color = const Color(0xffbb8b7b)
      ..strokeWidth = 1.1;
    canvas.drawPath(
      Path()
        ..moveTo(22, 28)
        ..quadraticBezierTo(24, 30, 26, 28),
      paint,
    );
    paint.style = PaintingStyle.fill;
    fill(
      Path()
        ..moveTo(20, 35)
        ..lineTo(24, 40)
        ..lineTo(28, 35)
        ..close(),
      const Color(0xfff3dfd0),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SocialSelfPortrait oldDelegate) =>
      user != oldDelegate.user;
}
