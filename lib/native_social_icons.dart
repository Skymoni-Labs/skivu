// Generated from the project's preserved SVG icon definitions.
// Regenerate: python tool/generate_native_social_icons.py
import 'package:flutter/material.dart';

class NativeSocialIcon extends StatelessWidget {
  const NativeSocialIcon(
    this.name, {
    super.key,
    this.size = 24,
    this.color,
    this.filled = false,
    this.strokeWidth,
  });
  final String name;
  final double size;
  final Color? color;
  final bool filled;
  final double? strokeWidth;
  static List<String> get names => _socialPaths.keys.toList(growable: false);
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _SocialIconPainter(
        name,
        color ?? IconTheme.of(context).color ?? const Color(0xff191919),
        filled,
        strokeWidth,
      ),
    ),
  );
}

class _SocialStroke {
  _SocialStroke(this.path, this.width);
  final Path path;
  final double width;
}

class _SocialIconPainter extends CustomPainter {
  _SocialIconPainter(this.name, this.color, this.filled, this.strokeWidth);
  final String name;
  final Color color;
  final bool filled;
  final double? strokeWidth;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    for (final stroke in _socialPaths[name] ?? _socialPaths['chat']!) {
      if (filled)
        canvas.drawPath(
          stroke.path,
          Paint()
            ..color = color
            ..style = PaintingStyle.fill,
        );
      canvas.drawPath(
        stroke.path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth ?? stroke.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SocialIconPainter old) =>
      old.name != name ||
      old.color != color ||
      old.filled != filled ||
      old.strokeWidth != strokeWidth;
}

final _socialPaths = <String, List<_SocialStroke>>{
  "cloud": [
    _SocialStroke(
      Path()
        ..moveTo(7, 18)
        ..cubicTo(
          5.0944434,
          17.9980849,
          3.3556436,
          16.9132065,
          2.5162527,
          15.2024837,
        )
        ..cubicTo(
          1.6768618,
          13.4917609,
          1.8828323,
          11.4526527,
          3.0473775,
          9.9443477,
        )
        ..cubicTo(4.2119228, 8.4360427, 6.1325526, 7.7208036, 8, 8.1)
        ..cubicTo(
          9.2810467,
          5.9953269,
          11.7185633,
          4.8877571,
          14.1464962,
          5.3071273,
        )
        ..cubicTo(16.5744291, 5.7264975, 18.4991836, 7.5875505, 19, 10)
        ..cubicTo(21.209139, 10.2761424, 22.7761424, 12.290861, 22.5, 14.5)
        ..cubicTo(22.2238576, 16.709139, 20.209139, 18.2761424, 18, 18)
        ..lineTo(7, 18)
        ..close(),
      1.8,
    ),
  ],
  "menu": [
    _SocialStroke(
      Path()
        ..moveTo(4, 6)
        ..lineTo(20, 6)
        ..moveTo(4, 12)
        ..lineTo(20, 12)
        ..moveTo(4, 18)
        ..lineTo(20, 18),
      1.8,
    ),
  ],
  "phone": [
    _SocialStroke(
      Path()
        ..moveTo(8, 3)
        ..lineTo(10, 8)
        ..lineTo(7, 10)
        ..cubicTo(9, 14, 10, 15, 14, 17)
        ..lineTo(16, 14)
        ..lineTo(21, 16)
        ..lineTo(20, 21)
        ..cubicTo(10, 22, 2, 14, 3, 4)
        ..lineTo(8, 3)
        ..close(),
      1.8,
    ),
  ],
  "panel": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(4, 4, 16, 16),
          Radius.circular(1),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(12, 4)
        ..lineTo(12, 20)
        ..moveTo(12, 12)
        ..lineTo(20, 12),
      1.8,
    ),
  ],
  "plus": [
    _SocialStroke(
      Path()
        ..moveTo(12, 4)
        ..lineTo(12, 20)
        ..moveTo(4, 12)
        ..lineTo(20, 12),
      1.8,
    ),
  ],
  "close": [
    _SocialStroke(
      Path()
        ..moveTo(6, 6)
        ..lineTo(18, 18)
        ..moveTo(6, 18)
        ..lineTo(18, 6),
      1.8,
    ),
  ],
  "down": [
    _SocialStroke(
      Path()
        ..moveTo(7, 10)
        ..lineTo(12, 15)
        ..lineTo(17, 10),
      1.8,
    ),
  ],
  "right": [
    _SocialStroke(
      Path()
        ..moveTo(9, 6)
        ..lineTo(15, 12)
        ..lineTo(9, 18),
      1.8,
    ),
  ],
  "sparkles": [
    _SocialStroke(
      Path()
        ..moveTo(9, 3)
        ..lineTo(11.5, 9.5)
        ..lineTo(18, 12)
        ..lineTo(11.5, 14.5)
        ..lineTo(9, 21)
        ..lineTo(6.5, 14.5)
        ..lineTo(0, 12)
        ..lineTo(6.5, 9.5)
        ..lineTo(9, 3)
        ..close()
        ..moveTo(20, 2)
        ..lineTo(21, 5)
        ..lineTo(24, 6)
        ..lineTo(21, 7)
        ..lineTo(20, 10)
        ..lineTo(19, 7)
        ..lineTo(16, 6)
        ..lineTo(19, 5)
        ..lineTo(20, 2)
        ..close(),
      1.8,
    ),
  ],
  "smile": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(8, 14)
        ..cubicTo(8, 16.209139, 9.790861, 18, 12, 18)
        ..cubicTo(14.209139, 18, 16, 16.209139, 16, 14)
        ..moveTo(8, 9)
        ..lineTo(8.01, 9)
        ..moveTo(16, 9)
        ..lineTo(16.01, 9),
      1.8,
    ),
  ],
  "chat": [
    _SocialStroke(
      Path()
        ..moveTo(20, 11)
        ..cubicTo(
          20.0181033,
          13.306927,
          19.0394288,
          15.5093656,
          17.315157,
          17.0420517,
        )
        ..cubicTo(15.5908852, 18.5747377, 13.2888947, 19.2884458, 11, 19)
        ..lineTo(5, 21)
        ..lineTo(6, 16)
        ..cubicTo(
          3.6259219,
          13.3028062,
          3.3413999,
          9.3536504,
          5.3043203,
          6.3439919,
        )
        ..cubicTo(
          7.2672407,
          3.3343334,
          10.9959661,
          2.0026458,
          14.4213579,
          3.087907,
        )
        ..cubicTo(17.8467497, 4.1731683, 20.1283268, 7.4090902, 20, 11)
        ..close(),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(8, 10)
        ..lineTo(8.01, 10)
        ..moveTo(12, 10)
        ..lineTo(12.01, 10)
        ..moveTo(16, 10)
        ..lineTo(16.01, 10),
      1.8,
    ),
  ],
  "user": [
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 8), width: 8, height: 8)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(5, 21)
        ..lineTo(5, 19)
        ..cubicTo(5.0000001, 15.1340068, 8.1340068, 12.0000001, 12, 12.0000001)
        ..cubicTo(15.8659932, 12.0000001, 18.9999999, 15.1340068, 19, 19)
        ..lineTo(19, 21),
      1.8,
    ),
  ],
  "role": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(4, 10)
        ..cubicTo(8, 10, 10, 8, 12, 5)
        ..cubicTo(14, 8, 16, 10, 20, 10)
        ..moveTo(8, 12)
        ..lineTo(8.01, 12)
        ..moveTo(16, 12)
        ..lineTo(16.01, 12)
        ..moveTo(9, 16)
        ..cubicTo(9.7593322, 16.8610017, 10.8519977, 17.3542487, 12, 17.3542487)
        ..cubicTo(13.1480023, 17.3542487, 14.2406678, 16.8610017, 15, 16),
      1.8,
    ),
  ],
  "users": [
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(9, 8), width: 6, height: 6)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(3, 21)
        ..lineTo(3, 18)
        ..cubicTo(3, 14.6862915, 5.6862915, 12, 9, 12)
        ..cubicTo(12.3137085, 12, 15, 14.6862915, 15, 18)
        ..lineTo(15, 21)
        ..moveTo(16, 5)
        ..cubicTo(17.6568542, 5, 19, 6.3431458, 19, 8)
        ..cubicTo(19, 9.6568542, 17.6568542, 11, 16, 11)
        ..moveTo(18, 15)
        ..cubicTo(19.968909, 15.8507058, 21.1759227, 17.8623952, 21, 20),
      1.8,
    ),
  ],
  "search": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(10, 10), width: 12, height: 12),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(15, 15)
        ..lineTo(20, 20),
      1.8,
    ),
  ],
  "grid": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(4, 4, 6, 6), Radius.circular(1)),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(14, 4, 6, 6), Radius.circular(1)),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(4, 14, 6, 6), Radius.circular(1)),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(14, 14, 6, 6),
          Radius.circular(1),
        ),
      ),
      1.8,
    ),
  ],
  "settings": [
    _SocialStroke(
      Path()
        ..moveTo(9, 3)
        ..lineTo(8, 6)
        ..lineTo(5, 7)
        ..lineTo(3, 11)
        ..lineTo(5, 13)
        ..lineTo(4, 17)
        ..lineTo(8, 20)
        ..lineTo(11, 19)
        ..lineTo(14, 21)
        ..lineTo(18, 19)
        ..lineTo(19, 15)
        ..lineTo(22, 13)
        ..lineTo(21, 9)
        ..lineTo(18, 8)
        ..lineTo(17, 5)
        ..lineTo(9, 3)
        ..close(),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 12), width: 6, height: 6)),
      1.8,
    ),
  ],
  "box": [
    _SocialStroke(
      Path()
        ..moveTo(3, 7)
        ..lineTo(21, 7)
        ..lineTo(21, 11)
        ..lineTo(3, 11)
        ..lineTo(3, 7)
        ..close()
        ..moveTo(5, 11)
        ..lineTo(5, 21)
        ..lineTo(19, 21)
        ..lineTo(19, 11)
        ..moveTo(9, 16)
        ..lineTo(15, 16)
        ..moveTo(3, 7)
        ..lineTo(6, 3)
        ..lineTo(18, 3)
        ..lineTo(21, 7),
      1.8,
    ),
  ],
  "folder": [
    _SocialStroke(
      Path()
        ..moveTo(3, 6)
        ..lineTo(10, 6)
        ..lineTo(12, 9)
        ..lineTo(21, 9)
        ..lineTo(21, 21)
        ..lineTo(3, 21)
        ..lineTo(3, 6)
        ..close(),
      1.8,
    ),
  ],
  "tools": [
    _SocialStroke(
      Path()
        ..moveTo(4, 4)
        ..lineTo(20, 20)
        ..moveTo(16, 3)
        ..lineTo(12, 7)
        ..lineTo(17, 12)
        ..lineTo(21, 8)
        ..moveTo(3, 17)
        ..lineTo(8, 12)
        ..lineTo(12, 16)
        ..lineTo(7, 21)
        ..lineTo(3, 17)
        ..close(),
      1.8,
    ),
  ],
  "globe": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 8, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(3, 12)
        ..lineTo(21, 12),
      1.8,
    ),
  ],
  "terminal": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, 4, 18, 16),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(6, 8)
        ..lineTo(10, 12)
        ..lineTo(6, 16)
        ..moveTo(13, 16)
        ..lineTo(18, 16),
      1.8,
    ),
  ],
  "expand": [
    _SocialStroke(
      Path()
        ..moveTo(9, 3)
        ..lineTo(3, 3)
        ..lineTo(3, 9)
        ..moveTo(3, 3)
        ..lineTo(10, 10)
        ..moveTo(15, 21)
        ..lineTo(21, 21)
        ..lineTo(21, 15)
        ..moveTo(21, 21)
        ..lineTo(14, 14),
      1.8,
    ),
  ],
  "sliders": [
    _SocialStroke(
      Path()
        ..moveTo(4, 6)
        ..lineTo(20, 6)
        ..moveTo(4, 12)
        ..lineTo(20, 12)
        ..moveTo(4, 18)
        ..lineTo(20, 18)
        ..moveTo(8, 3)
        ..lineTo(8, 9)
        ..moveTo(15, 9)
        ..lineTo(15, 15)
        ..moveTo(10, 15)
        ..lineTo(10, 21),
      1.8,
    ),
  ],
  "image": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, 3, 18, 18),
          Radius.circular(3),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(8, 8), width: 4, height: 4)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(3, 17)
        ..lineTo(8, 12)
        ..lineTo(12, 16)
        ..lineTo(16, 10)
        ..lineTo(21, 17),
      1.8,
    ),
  ],
  "mic": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(9, 2, 6, 12), Radius.circular(3)),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(5, 9)
        ..lineTo(5, 11)
        ..cubicTo(5.0000001, 14.8659932, 8.1340068, 17.9999999, 12, 17.9999999)
        ..cubicTo(15.8659932, 17.9999999, 18.9999999, 14.8659932, 19, 11)
        ..lineTo(19, 9)
        ..moveTo(12, 18)
        ..lineTo(12, 22)
        ..moveTo(8, 22)
        ..lineTo(16, 22),
      1.8,
    ),
  ],
  "voice": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(8, 10)
        ..cubicTo(9.018576, 11.1388026, 9.018576, 12.8611974, 8, 14)
        ..moveTo(11, 8)
        ..cubicTo(13.0371521, 10.2776052, 13.0371521, 13.7223948, 11, 16)
        ..moveTo(14, 6)
        ..cubicTo(17.0557281, 9.4164079, 17.0557281, 14.5835921, 14, 18),
      1.8,
    ),
  ],
  "plus-circle": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(12, 7)
        ..lineTo(12, 17)
        ..moveTo(7, 12)
        ..lineTo(17, 12),
      1.8,
    ),
  ],
  "arrow-up": [
    _SocialStroke(
      Path()
        ..moveTo(12, 20)
        ..lineTo(12, 4)
        ..moveTo(5, 11)
        ..lineTo(12, 4)
        ..lineTo(19, 11),
      1.8,
    ),
  ],
  "chevrons-down": [
    _SocialStroke(
      Path()
        ..moveTo(6, 6)
        ..lineTo(12, 12)
        ..lineTo(18, 6)
        ..moveTo(6, 13)
        ..lineTo(12, 19)
        ..lineTo(18, 13),
      1.8,
    ),
  ],
  "history": [
    _SocialStroke(
      Path()
        ..moveTo(4, 10)
        ..cubicTo(
          5.2279972,
          6.2672116,
          8.9852145,
          3.9789658,
          12.865293,
          4.6007995,
        )
        ..cubicTo(
          16.7453715,
          5.2226332,
          19.5993421,
          8.5704089,
          19.5993421,
          12.5,
        )
        ..cubicTo(
          19.5993421,
          16.4295911,
          16.7453715,
          19.7773668,
          12.865293,
          20.3992005,
        )
        ..cubicTo(8.9852145, 21.0210342, 5.2279972, 18.7327884, 4, 15)
        ..moveTo(4, 4)
        ..lineTo(4, 10)
        ..lineTo(10, 10)
        ..moveTo(12, 7)
        ..lineTo(12, 12)
        ..lineTo(15, 14),
      1.8,
    ),
  ],
  "gauge": [
    _SocialStroke(
      Path()
        ..moveTo(3, 18)
        ..cubicTo(
          0.9639178,
          13.7960165,
          2.109454,
          8.7425085,
          5.7592977,
          5.8274185,
        )
        ..cubicTo(
          9.4091413,
          2.9123286,
          14.5908587,
          2.9123286,
          18.2407023,
          5.8274185,
        )
        ..cubicTo(21.890546, 8.7425085, 23.0360822, 13.7960165, 21, 18)
        ..moveTo(5, 18)
        ..lineTo(19, 18)
        ..moveTo(12, 14)
        ..lineTo(17, 7),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 14), width: 2, height: 2)),
      1.8,
    ),
  ],
  "database": [
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 5), width: 16, height: 6)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(4, 5)
        ..lineTo(4, 19)
        ..cubicTo(4, 23, 20, 23, 20, 19)
        ..lineTo(20, 5)
        ..moveTo(4, 12)
        ..cubicTo(4, 16, 20, 16, 20, 12),
      1.8,
    ),
  ],
  "circle": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 16, height: 16),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(12, 4)
        ..cubicTo(16.418278, 4, 20, 7.581722, 20, 12),
      3,
    ),
  ],
  "signal": [
    _SocialStroke(
      Path()
        ..moveTo(4, 20)
        ..lineTo(4, 17)
        ..moveTo(9, 20)
        ..lineTo(9, 13)
        ..moveTo(14, 20)
        ..lineTo(14, 9)
        ..moveTo(19, 20)
        ..lineTo(19, 4),
      3,
    ),
  ],
  "battery": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(2, 6, 18, 12),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(22, 10)
        ..lineTo(22, 14)
        ..moveTo(5, 9)
        ..lineTo(5, 15)
        ..lineTo(16, 15)
        ..lineTo(16, 9)
        ..lineTo(5, 9)
        ..close(),
      1.8,
    ),
  ],
  "check": [
    _SocialStroke(
      Path()
        ..moveTo(5, 12)
        ..lineTo(9, 16)
        ..lineTo(19, 6),
      1.8,
    ),
  ],
  "more": [
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(5, 12), width: 2, height: 2)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 12), width: 2, height: 2)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(19, 12), width: 2, height: 2)),
      1.8,
    ),
  ],
  "copy": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(8, 8, 12, 13),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(16, 8)
        ..lineTo(16, 3)
        ..lineTo(3, 3)
        ..lineTo(3, 16)
        ..lineTo(8, 16),
      1.8,
    ),
  ],
  "stop": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(6, 6, 12, 12),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
  ],
  "wallet": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, 5, 18, 15),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(15, 10)
        ..lineTo(21, 10)
        ..lineTo(21, 16)
        ..lineTo(15, 16)
        ..lineTo(15, 10)
        ..close(),
      1.8,
    ),
  ],
  "shop": [
    _SocialStroke(
      Path()
        ..moveTo(3, 9)
        ..lineTo(21, 9)
        ..lineTo(19, 4)
        ..lineTo(5, 4)
        ..lineTo(3, 9)
        ..close()
        ..moveTo(4, 10)
        ..lineTo(4, 21)
        ..lineTo(20, 21)
        ..lineTo(20, 10)
        ..moveTo(9, 21)
        ..lineTo(9, 13)
        ..lineTo(15, 13)
        ..lineTo(15, 21),
      1.8,
    ),
  ],
  "heart": [
    _SocialStroke(
      Path()
        ..moveTo(20.8, 5.6)
        ..cubicTo(18.7415907, 3.5929776, 15.4584093, 3.5929776, 13.4, 5.6)
        ..lineTo(12, 7)
        ..lineTo(10.6, 5.6)
        ..cubicTo(
          8.4799726,
          3.9243523,
          5.4387393,
          4.1120152,
          3.5408065,
          6.0355958,
        )
        ..cubicTo(1.6428737, 7.9591763, 1.4960478, 11.0026545, 3.2, 13.1)
        ..lineTo(12, 22)
        ..lineTo(20.8, 13.1)
        ..cubicTo(
          21.7953714,
          12.105868,
          22.3546696,
          10.7567916,
          22.3546696,
          9.35,
        )
        ..cubicTo(22.3546696, 7.9432084, 21.7953714, 6.594132, 20.8, 5.6)
        ..close(),
      1.8,
    ),
  ],
  "book": [
    _SocialStroke(
      Path()
        ..moveTo(3, 4)
        ..lineTo(10, 4)
        ..lineTo(12, 6)
        ..lineTo(14, 4)
        ..lineTo(21, 4)
        ..lineTo(21, 20)
        ..lineTo(14, 20)
        ..lineTo(12, 22)
        ..lineTo(10, 20)
        ..lineTo(3, 20)
        ..lineTo(3, 4)
        ..close()
        ..moveTo(12, 6)
        ..lineTo(12, 22),
      1.8,
    ),
  ],
  "camera": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, 6, 18, 15),
          Radius.circular(3),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(7, 6)
        ..lineTo(9, 3)
        ..lineTo(15, 3)
        ..lineTo(17, 6),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 13), width: 8, height: 8)),
      1.8,
    ),
  ],
  "compass": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(16, 8)
        ..lineTo(13, 13)
        ..lineTo(8, 16)
        ..lineTo(11, 11)
        ..lineTo(16, 8)
        ..close(),
      1.8,
    ),
  ],
  "pin": [
    _SocialStroke(
      Path()
        ..moveTo(19, 10)
        ..cubicTo(19, 15, 12, 21, 12, 21)
        ..cubicTo(12, 21, 5, 15, 5, 10)
        ..cubicTo(4.9999999, 6.1340067, 8.1340067, 2.9999999, 12, 2.9999999)
        ..cubicTo(15.8659933, 2.9999999, 19.0000001, 6.1340067, 19, 10)
        ..close(),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(12, 10), width: 5, height: 5)),
      1.8,
    ),
  ],
  "star": [
    _SocialStroke(
      Path()
        ..moveTo(12, 3)
        ..lineTo(14.8, 8.7)
        ..lineTo(21, 9.6)
        ..lineTo(16.5, 14)
        ..lineTo(17.5, 20.2)
        ..lineTo(12, 17.3)
        ..lineTo(6.5, 20.2)
        ..lineTo(7.5, 14)
        ..lineTo(3, 9.6)
        ..lineTo(9.2, 8.7)
        ..lineTo(12, 3)
        ..close(),
      1.8,
    ),
  ],
  "bell": [
    _SocialStroke(
      Path()
        ..moveTo(5, 17)
        ..lineTo(19, 17)
        ..lineTo(17, 14)
        ..lineTo(17, 9)
        ..cubicTo(17, 6.2385763, 14.7614237, 4, 12, 4)
        ..cubicTo(9.2385763, 4, 7, 6.2385763, 7, 9)
        ..lineTo(7, 14)
        ..lineTo(5, 17)
        ..close()
        ..moveTo(10, 21)
        ..lineTo(14, 21)
        ..moveTo(12, 3)
        ..lineTo(12, 4),
      1.8,
    ),
  ],
  "music": [
    _SocialStroke(
      Path()
        ..moveTo(9, 18)
        ..lineTo(9, 5)
        ..lineTo(20, 3)
        ..lineTo(20, 16)
        ..moveTo(9, 8)
        ..lineTo(20, 6),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(6, 18), width: 6, height: 5)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(17, 16), width: 6, height: 5)),
      1.8,
    ),
  ],
  "video": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, 5, 12, 14),
          Radius.circular(3),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(15, 9)
        ..lineTo(21, 6)
        ..lineTo(21, 18)
        ..lineTo(15, 15),
      1.8,
    ),
  ],
  "qr": [
    _SocialStroke(
      Path()
        ..moveTo(3, 3)
        ..lineTo(9, 3)
        ..lineTo(9, 9)
        ..lineTo(3, 9)
        ..lineTo(3, 3)
        ..close()
        ..moveTo(15, 3)
        ..lineTo(21, 3)
        ..lineTo(21, 9)
        ..lineTo(15, 9)
        ..lineTo(15, 3)
        ..close()
        ..moveTo(3, 15)
        ..lineTo(9, 15)
        ..lineTo(9, 21)
        ..lineTo(3, 21)
        ..lineTo(3, 15)
        ..close()
        ..moveTo(15, 15)
        ..lineTo(17, 15)
        ..lineTo(17, 17)
        ..lineTo(15, 17)
        ..lineTo(15, 15)
        ..close()
        ..moveTo(20, 15)
        ..lineTo(20, 21)
        ..lineTo(15, 21)
        ..moveTo(12, 3)
        ..lineTo(12, 6)
        ..moveTo(3, 12)
        ..lineTo(6, 12)
        ..moveTo(12, 10)
        ..lineTo(12, 15)
        ..moveTo(11, 20)
        ..lineTo(11, 21),
      1.8,
    ),
  ],
  "bell-off": [
    _SocialStroke(
      Path()
        ..moveTo(5, 17)
        ..lineTo(19, 17)
        ..lineTo(17, 14)
        ..lineTo(17, 9)
        ..cubicTo(17, 7.1061397, 15.9299881, 5.3748241, 14.236068, 4.527864)
        ..cubicTo(12.5421478, 3.680904, 10.5150882, 3.8636838, 9, 5)
        ..moveTo(7, 9)
        ..lineTo(7, 14)
        ..lineTo(5, 17)
        ..moveTo(10, 21)
        ..lineTo(14, 21)
        ..moveTo(3, 3)
        ..lineTo(21, 21),
      1.8,
    ),
  ],
  "gift": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(3, 8, 18, 4), Radius.circular(1)),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(5, 12)
        ..lineTo(5, 21)
        ..lineTo(19, 21)
        ..lineTo(19, 12)
        ..moveTo(12, 8)
        ..lineTo(12, 21)
        ..moveTo(12, 8)
        ..lineTo(8, 8)
        ..cubicTo(6.3431458, 8, 5, 6.6568542, 5, 5)
        ..cubicTo(5, 3.3431458, 6.3431458, 2, 8, 2)
        ..cubicTo(9.6568542, 2, 11, 3.3431458, 11, 5)
        ..lineTo(12, 8)
        ..close()
        ..moveTo(12, 8)
        ..lineTo(16, 8)
        ..cubicTo(17.6568542, 8, 19, 6.6568542, 19, 5)
        ..cubicTo(19, 3.3431458, 17.6568542, 2, 16, 2)
        ..cubicTo(14.3431458, 2, 13, 3.3431458, 13, 5)
        ..lineTo(12, 8)
        ..close(),
      1.8,
    ),
  ],
  "transfer": [
    _SocialStroke(
      Path()
        ..moveTo(3, 8)
        ..lineTo(21, 8)
        ..moveTo(16, 3)
        ..lineTo(21, 8)
        ..lineTo(16, 13)
        ..moveTo(21, 16)
        ..lineTo(3, 16)
        ..moveTo(8, 11)
        ..lineTo(3, 16)
        ..lineTo(8, 21),
      1.8,
    ),
  ],
  "envelope": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, 5, 18, 14),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(3, 6)
        ..lineTo(12, 13)
        ..lineTo(21, 6),
      1.8,
    ),
  ],
  "interaction-back": [
    _SocialStroke(
      Path()
        ..moveTo(15, 5)
        ..lineTo(8, 12)
        ..lineTo(15, 19),
      1.8,
    ),
  ],
  "clock": [
    _SocialStroke(
      Path()..addOval(
        Rect.fromCenter(center: Offset(12, 12), width: 18, height: 18),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(12, 7)
        ..lineTo(12, 13)
        ..lineTo(16, 15),
      1.8,
    ),
  ],
  "list": [
    _SocialStroke(
      Path()
        ..moveTo(9, 6)
        ..lineTo(21, 6)
        ..moveTo(9, 12)
        ..lineTo(21, 12)
        ..moveTo(9, 18)
        ..lineTo(21, 18)
        ..moveTo(3, 6)
        ..lineTo(4, 6)
        ..moveTo(3, 12)
        ..lineTo(4, 12)
        ..moveTo(3, 18)
        ..lineTo(4, 18),
      1.8,
    ),
  ],
  "keyboard": [
    _SocialStroke(
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(2, 5, 20, 14),
          Radius.circular(2),
        ),
      ),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(5, 9)
        ..lineTo(6, 9)
        ..moveTo(9, 9)
        ..lineTo(10, 9)
        ..moveTo(13, 9)
        ..lineTo(14, 9)
        ..moveTo(17, 9)
        ..lineTo(18, 9)
        ..moveTo(5, 12)
        ..lineTo(6, 12)
        ..moveTo(9, 12)
        ..lineTo(10, 12)
        ..moveTo(13, 12)
        ..lineTo(14, 12)
        ..moveTo(17, 12)
        ..lineTo(18, 12)
        ..moveTo(7, 16)
        ..lineTo(17, 16),
      1.8,
    ),
  ],
  "hash": [
    _SocialStroke(
      Path()
        ..moveTo(9, 3)
        ..lineTo(6, 21)
        ..moveTo(18, 3)
        ..lineTo(15, 21)
        ..moveTo(3, 9)
        ..lineTo(22, 9)
        ..moveTo(2, 16)
        ..lineTo(21, 16),
      1.8,
    ),
  ],
  "qq-zone": [
    _SocialStroke(
      Path()
        ..moveTo(17, 4)
        ..cubicTo(
          13.7195538,
          2.147367,
          9.6323401,
          2.5340157,
          6.7574948,
          4.9689368,
        )
        ..cubicTo(
          3.8826494,
          7.4038578,
          2.8286231,
          11.3717088,
          4.1161183,
          14.9123206,
        )
        ..cubicTo(
          5.4036135,
          18.4529325,
          8.7601365,
          20.8169474,
          12.527522,
          20.8365117,
        )
        ..cubicTo(16.2949075, 20.856076, 19.6758018, 18.5270491, 21, 15)
        ..moveTo(17, 2)
        ..lineTo(18.3, 5.5)
        ..lineTo(22, 6.8)
        ..lineTo(18.3, 8.1)
        ..lineTo(17, 12)
        ..lineTo(15.7, 8.1)
        ..lineTo(12, 6.8)
        ..lineTo(15.7, 5.5)
        ..lineTo(17, 2)
        ..close(),
      1.8,
    ),
  ],
  "address-book": [
    _SocialStroke(
      Path()
        ..addOval(Rect.fromCenter(center: Offset(9, 7), width: 8, height: 8)),
      1.8,
    ),
    _SocialStroke(
      Path()
        ..moveTo(2, 21)
        ..lineTo(2, 18)
        ..cubicTo(2, 14, 5, 12, 9, 12)
        ..cubicTo(13, 12, 16, 14, 16, 18)
        ..lineTo(16, 21)
        ..moveTo(18, 6)
        ..lineTo(22, 6)
        ..moveTo(18, 11)
        ..lineTo(22, 11)
        ..moveTo(18, 16)
        ..lineTo(22, 16),
      1.8,
    ),
  ],
  "chevron-left": [
    _SocialStroke(
      Path()
        ..moveTo(15, 6)
        ..lineTo(9, 12)
        ..lineTo(15, 18),
      1.8,
    ),
  ],
  "play": [
    _SocialStroke(
      Path()
        ..moveTo(8, 4)
        ..lineTo(20, 12)
        ..lineTo(8, 20)
        ..lineTo(8, 4)
        ..close(),
      1.8,
    ),
  ],
  "pause": [
    _SocialStroke(
      Path()
        ..moveTo(8, 4)
        ..lineTo(8, 20)
        ..moveTo(16, 4)
        ..lineTo(16, 20),
      1.8,
    ),
  ],
  "chevron-right": [
    _SocialStroke(
      Path()
        ..moveTo(9, 6)
        ..lineTo(15, 12)
        ..lineTo(9, 18),
      1.8,
    ),
  ],
};
