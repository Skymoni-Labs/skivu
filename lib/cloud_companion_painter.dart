import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'cloud_companion_motion.dart';
import 'cloud_companion_reference.dart';
import 'cloud_typing_motion.dart';
import 'cloud_pet_pack.dart';

/// Reference pixels remain intact. A connected weighted mesh moves wrists and
/// head, so joints never expose holes or require replacement limb artwork.
class CloudCompanionPainter extends CustomPainter {
  const CloudCompanionPainter({
    required this.image,
    required this.rig,
    required this.pose,
    required this.activity,
    required this.seconds,
    required this.entry,
    required this.motion,
    required this.greeting,
    this.layers,
    this.petPack,
    this.petAtlas,
  });
  final ui.Image image;
  final CloudReferenceRig rig;
  final CloudPose pose;
  final CloudActivity activity;
  final double seconds, entry;
  final bool motion, greeting;
  final List<CloudVisualLayer>? layers;
  final CloudPetPack? petPack;
  final ui.Image? petAtlas;
  String get sceneName => sceneFor(activity, pose);
  static String sceneFor(CloudActivity activity, CloudPose pose) =>
      switch (activity) {
        CloudActivity.coding => 'coding',
        CloudActivity.phone => 'phone',
        CloudActivity.thinking =>
          pose.computer > .5
              ? 'coding'
              : pose.phone > .5
              ? 'phone'
              : 'thinking',
        CloudActivity.permission => 'permission',
        CloudActivity.checking => 'checking',
        CloudActivity.complete => 'complete',
        CloudActivity.failed => 'failed',
        CloudActivity.stopping ||
        CloudActivity.paused ||
        CloudActivity.resultReady =>
          pose.computer > .5
              ? 'coding'
              : pose.phone > .5
              ? 'phone'
              : 'idle',
        _ => 'idle',
      };
  static final matrix = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    final frames =
        layers ??
        [
          CloudVisualLayer(
            activity: activity,
            pose: pose,
            seconds: seconds,
            opacity: 1,
            greeting: greeting,
          ),
        ];
    final bounds = Offset.zero & size;
    if (frames.length == 1 && frames.single.opacity >= .999) {
      canvas.save();
      paintLayer(canvas, size, frames.single);
      canvas.restore();
      return;
    }
    // Premultiplied additive cross-dissolve keeps the shared silhouette opaque.
    canvas.saveLayer(bounds, Paint());
    for (final frame in frames) {
      if (frame.opacity <= .001) continue;
      canvas.saveLayer(
        bounds,
        Paint()
          ..color = Colors.white.withValues(alpha: frame.opacity)
          ..blendMode = BlendMode.plus,
      );
      canvas.save();
      paintLayer(canvas, size, frame);
      canvas.restore();
      canvas.restore();
    }
    canvas.restore();
  }

  void paintLayer(Canvas canvas, Size size, CloudVisualLayer frame) {
    final activity = frame.activity, pose = frame.pose;
    final greeting = frame.greeting, seconds = frame.seconds;
    final pack = petPack;
    if (pack != null && petAtlas != null && pack.supports(activity, pose)) {
      paintPet(canvas, size, pack, frame);
      return;
    }
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / 600, size.height / 660);
    final scene = rig.scenes[sceneFor(activity, pose)]!;
    final texture = scene.texture;
    if (texture == null) return;
    final time = motion ? seconds % 8 : 0.0;
    final cycle = motion ? (1 - math.cos(time * math.pi / 2)) / 2 : 0.0;
    final idle = activity == CloudActivity.idle;
    final float = idle ? -7 * cycle : 0.0;
    final rotate = idle && motion
        ? ui.lerpDouble(-1.5, 1, cycle)! * math.pi / 180
        : 0.0;
    canvas.translate(300, 70 + float);
    canvas.rotate(rotate);
    canvas.scale(1.55);
    canvas.translate(
      -(scene.bounds.center.dx - scene.offset.dx),
      -(scene.bounds.top - scene.offset.dy),
    );
    final mesh = scene.mesh;
    final points = Float32List.fromList(mesh.coordinates);
    final pivot = Offset(
      scene.bounds.center.dx - scene.offset.dx,
      scene.bounds.bottom - scene.offset.dy,
    );
    final headTurn = activity == CloudActivity.coding && motion
        ? .008 * math.sin(time * math.pi / 0.8)
        : activity == CloudActivity.thinking && motion
        ? -.012 * math.sin(time * math.pi / 2)
        : activity == CloudActivity.complete && motion && time < 1.15
        ? math.sin(time / 1.15 * math.pi * 4) * .018
        : 0.0;
    final cosine = math.cos(headTurn), sine = math.sin(headTurn);
    final strokes = [
      CloudTypingStroke.sample(time, 0),
      CloudTypingStroke.sample(time, 1),
    ];
    final typingDip = activity == CloudActivity.coding && motion
        ? .75 * math.sin(time * math.pi / 0.8 - .4)
        : 0.0;
    for (var i = 0; i < CloudReferenceMesh.count; i++) {
      final x = mesh.coordinates[i * 2], y = mesh.coordinates[i * 2 + 1];
      final weight = mesh.head[i];
      final dx = x - pivot.dx, dy = y - pivot.dy;
      points[i * 2] += ((dx * cosine - dy * sine) - dx) * weight;
      points[i * 2 + 1] +=
          (((dx * sine + dy * cosine) - dy) + cycle * 1.6 + typingDip) * weight;
      for (var a = 0; a < scene.arms.length; a++) {
        final arm = scene.arms[a];
        final armWeight = mesh.armWeights[a][i];
        if (armWeight == 0) continue;
        var lift = 0.0, angle = 0.0, reach = 0.0;
        if (motion && activity == CloudActivity.coding) {
          final stroke = strokes[arm.side];
          lift = -stroke.height;
          angle = stroke.roll * (arm.side == 0 ? 1 : -1);
          reach = stroke.reach;
        } else if (motion && activity == CloudActivity.phone) {
          lift = math.sin(time * math.pi * 2) * 1.8;
          angle = math.sin(time * math.pi * 2) * .025;
        } else if (motion && idle && greeting && time < 2 && arm.side == 1) {
          final envelope = math.sin(time / 2 * math.pi);
          lift = -envelope * 12;
          angle = (-.14 + math.sin(time * math.pi * 4) * .035) * envelope;
        } else if (motion &&
            activity == CloudActivity.permission &&
            time < .5) {
          angle = math.sin(time / .5 * math.pi) * .035;
        }
        final p = arm.pivot - scene.offset;
        final ax = x - p.dx,
            ay = y - p.dy,
            c = math.cos(angle),
            s = math.sin(angle);
        points[i * 2] += ((ax * c - ay * s) - ax + reach) * armWeight;
        points[i * 2 + 1] += ((ax * s + ay * c) - ay + lift) * armWeight;
      }
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      points,
      textureCoordinates: mesh.coordinates,
      indices: mesh.indices,
    );
    final shader = ui.ImageShader(
      texture,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      matrix,
      filterQuality: ui.FilterQuality.high,
    );
    canvas.drawVertices(vertices, BlendMode.srcOver, Paint()..shader = shader);
    shader.dispose();
    // Website eyelid layer has its own clock and follows the identical mesh.
    final blinkTimes = activity == CloudActivity.coding
        ? const [.60, 4.60]
        : const [3.65, 7.60];
    final blink =
        motion &&
        scene.eyes.isNotEmpty &&
        blinkTimes.any((start) => time >= start && time < start + .13);
    if (blink && scene.lids != null) {
      final lids = ui.ImageShader(
        scene.lids!,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        matrix,
        filterQuality: ui.FilterQuality.high,
      );
      canvas.drawVertices(vertices, BlendMode.srcOver, Paint()..shader = lids);
      lids.dispose();
    }
    vertices.dispose();
  }

  void paintPet(
    Canvas canvas,
    Size size,
    CloudPetPack pack,
    CloudVisualLayer frame,
  ) {
    final sample = pack.sample(
      frame.seconds,
      segment:
          frame.petSegment ??
          (frame.activity == CloudActivity.coding
              ? null
              : CloudPetSegment.hold),
      moving: motion,
    );
    final fit = applyBoxFit(BoxFit.contain, pack.viewport.size, size);
    final destination = Alignment.center.inscribe(
      fit.destination,
      Offset.zero & size,
    );
    canvas.clipRect(Offset.zero & size);
    canvas.translate(destination.left, destination.top);
    canvas.scale(destination.width / pack.viewport.width);
    canvas.translate(-pack.viewport.left, -pack.viewport.top);
    final tile = Offset.zero & pack.tileSize;
    final paint = Paint()..filterQuality = FilterQuality.high;
    // The head and props are registered once, independent of the hand frames.
    final fixed = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(pack.viewport);
    for (final region in pack.animatedRegions) {
      fixed.addRect(region);
    }
    canvas.save();
    canvas.clipPath(fixed);
    canvas.drawImageRect(petAtlas!, tile, tile, paint);
    canvas.restore();
    final origin = pack.frameOrigin(sample.frame);
    for (final region in pack.animatedRegions) {
      canvas.drawImageRect(petAtlas!, region.shift(origin), region, paint);
    }
    for (final region in pack.fixedRegions) {
      canvas.drawImageRect(petAtlas!, region, region, paint);
    }
    // Foreground laptop always covers the hands where their regions overlap.
    canvas.save();
    canvas.clipPath(pack.foreground);
    canvas.drawImageRect(petAtlas!, tile, tile, paint);
    canvas.restore();
    final blinkTime = frame.seconds % 4.2;
    if (motion && blinkTime >= 1.7 && blinkTime < 1.84) {
      for (var i = 0; i < pack.eyes.length; i++) {
        final eye = pack.eyes[i];
        final cover = eye.inflate(3);
        canvas.drawOval(
          cover,
          Paint()
            ..shader = ui.Gradient.radial(
              Offset(i == 0 ? eye.left - 12 : eye.right + 12, eye.bottom + 10),
              40,
              const [Color(0xfffee4d6), Color(0xfffefefe)],
            ),
        );
        canvas.drawPath(
          Path()
            ..moveTo(eye.left + 3, eye.center.dy)
            ..quadraticBezierTo(
              eye.center.dx,
              eye.center.dy + 7,
              eye.right - 3,
              eye.center.dy,
            ),
          Paint()
            ..color = const Color(0xff249fdc)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.8
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CloudCompanionPainter old) =>
      old.image != image ||
      old.rig != rig ||
      old.pose != pose ||
      old.activity != activity ||
      old.seconds != seconds ||
      old.entry != entry ||
      old.motion != motion ||
      old.greeting != greeting ||
      old.layers != layers ||
      old.petPack != petPack ||
      old.petAtlas != petAtlas;
}
