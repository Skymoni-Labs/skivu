import 'dart:ui';
import 'dart:typed_data';

class CloudReferenceArm {
  CloudReferenceArm(this.path, this.pivot, this.side);
  final Path path;
  final Offset pivot;
  final int side;
}

class CloudReferenceScene {
  CloudReferenceScene(Map<String, dynamic> data) {
    whole = readPath(data['whole'] as List);
    head = readPath(data['head'] as List);
    final b = (data['bounds'] as List).cast<num>();
    bounds = Rect.fromLTWH(
      b[0].toDouble(),
      b[1].toDouble(),
      b[2].toDouble(),
      b[3].toDouble(),
    );
    arms = (data['arms'] as List).map((raw) {
      final a = raw as Map;
      final p = (a['pivot'] as List).cast<num>();
      return CloudReferenceArm(
        readPath(a['paths'] as List),
        Offset(p[0].toDouble(), p[1].toDouble()),
        a['side'] as int,
      );
    }).toList();
    eyes = (data['eyes'] as List).map((raw) {
      final r = (raw as List).cast<num>();
      return Rect.fromLTWH(
        r[0].toDouble(),
        r[1].toDouble(),
        r[2].toDouble(),
        r[3].toDouble(),
      );
    }).toList();
  }
  late final Path whole, head;
  late final Rect bounds;
  late final List<CloudReferenceArm> arms;
  late final List<Rect> eyes;
  Image? texture, lids, headTexture;
  late final mesh = CloudReferenceMesh(this);
  Offset get offset => Offset(
    (bounds.left / 384).floor() * 384,
    (bounds.top / 512).floor() * 512,
  );

  static Path readPath(List polygons) {
    final path = Path();
    for (final polygon in polygons) {
      final points = polygon as List;
      for (var i = 0; i < points.length; i++) {
        final p = (points[i] as List).cast<num>();
        if (i == 0) {
          path.moveTo(p[0].toDouble(), p[1].toDouble());
        } else {
          path.lineTo(p[0].toDouble(), p[1].toDouble());
        }
      }
      path.close();
    }
    return path;
  }
}

class CloudReferenceMesh {
  CloudReferenceMesh(CloudReferenceScene scene) {
    armWeights = List.generate(scene.arms.length, (_) => Float32List(count));
    for (var row = 0; row <= rows; row++) {
      for (var col = 0; col <= columns; col++) {
        final index = row * (columns + 1) + col;
        final local = Offset(col * 384 / columns, row * 420 / rows);
        final point = local + scene.offset;
        coordinates[index * 2] = local.dx;
        coordinates[index * 2 + 1] = local.dy;
        head[index] = scene.head.contains(point) ? 1 : 0;
        for (var a = 0; a < scene.arms.length; a++) {
          final arm = scene.arms[a];
          final distance = (point - arm.pivot).distance;
          armWeights[a][index] = arm.path.contains(point)
              ? (distance / 38).clamp(0, 1)
              : 0;
        }
      }
    }
    var at = 0;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final a = row * (columns + 1) + col,
            b = a + 1,
            c = a + columns + 1,
            d = c + 1;
        for (final i in [a, c, b, b, c, d]) {
          indices[at++] = i;
        }
      }
    }
    soften(head);
    for (final weights in armWeights) {
      soften(weights);
    }
    if (scene.offset == const Offset(768, 0)) {
      for (var i = 0; i < count; i++) {
        final x = coordinates[i * 2], y = coordinates[i * 2 + 1];
        final hardware = y >= 344 || (y >= 269 && x > 224 - .33 * (y - 269));
        if (hardware) {
          head[i] = 0;
          for (final weights in armWeights) {
            weights[i] = 0;
          }
        }
      }
    }
  }
  static const columns = 48, rows = 53, count = (columns + 1) * (rows + 1);
  final coordinates = Float32List(count * 2), head = Float32List(count);
  final indices = Uint16List(columns * rows * 6);
  late final List<Float32List> armWeights;
  static void soften(Float32List weights) {
    final previous = Float32List.fromList(weights);
    for (var row = 1; row < rows; row++) {
      for (var col = 1; col < columns; col++) {
        var sum = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            sum += previous[(row + dy) * (columns + 1) + col + dx];
          }
        }
        weights[row * (columns + 1) + col] = sum / 9;
      }
    }
  }
}

class CloudReferenceRig {
  CloudReferenceRig(Map<String, dynamic> json)
    : scenes = (json['scenes'] as Map).map(
        (key, value) => MapEntry(
          key as String,
          CloudReferenceScene(Map<String, dynamic>.from(value as Map)),
        ),
      );
  final Map<String, CloudReferenceScene> scenes;

  Future<void> prepare(Image source) async {
    for (final scene in scenes.values) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder)
        ..translate(-scene.offset.dx, -scene.offset.dy);
      canvas.clipPath(scene.whole);
      canvas.drawImageRect(
        source,
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        const Rect.fromLTWH(0, 0, 1536, 1024),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      try {
        scene.texture = await picture.toImage(384, 420);
      } finally {
        picture.dispose();
      }
      // Build joint weights during preparation, never on the first work frame.
      scene.mesh;
      if (scene.offset == const Offset(768, 0)) {
        final recorder = PictureRecorder();
        final headCanvas = Canvas(recorder)
          ..translate(-scene.offset.dx, -scene.offset.dy)
          ..clipPath(scene.head);
        headCanvas.drawImage(source, Offset.zero, Paint());
        final picture = recorder.endRecording();
        try {
          scene.headTexture = await picture.toImage(384, 420);
        } finally {
          picture.dispose();
        }
      }
      final eyelids = PictureRecorder();
      final eyeCanvas = Canvas(eyelids)
        ..translate(-scene.offset.dx, -scene.offset.dy);
      for (final eye in scene.eyes) {
        final cover = eye.inflate(3);
        eyeCanvas.drawOval(
          cover,
          Paint()
            ..shader = Gradient.radial(cover.center, cover.width * .6, const [
              Color(0xfffffefa),
              Color(0xfffbfdfb),
            ]),
        );
        eyeCanvas.drawPath(
          Path()
            ..moveTo(eye.left + 3, eye.center.dy)
            ..quadraticBezierTo(
              eye.center.dx,
              eye.center.dy + eye.height * .25,
              eye.right - 3,
              eye.center.dy,
            ),
          Paint()
            ..color = const Color(0xff329dda)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      }
      final lidPicture = eyelids.endRecording();
      try {
        scene.lids = await lidPicture.toImage(384, 420);
      } finally {
        lidPicture.dispose();
      }
    }
  }

  void dispose() {
    for (final scene in scenes.values) {
      scene.texture?.dispose();
      scene.lids?.dispose();
      scene.headTexture?.dispose();
    }
  }
}
