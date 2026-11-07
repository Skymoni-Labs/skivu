import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'cloud_companion_motion.dart';
import 'cloud_companion_reference.dart';

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
  });
  final ui.Image image;
  final CloudReferenceRig rig;
  final CloudPose pose;
  final CloudActivity activity;
  final double seconds, entry;
  final bool motion, greeting;
  String get sceneName => switch (activity) {
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
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / 600, size.height / 660);
    final scene = rig.scenes[sceneName]!;
    final texture = scene.texture;
    if (texture == null) return;
    final time = motion ? seconds : 0.0;
    final cycle = motion ? (1 - math.cos(time * math.pi / 2)) / 2 : 0.0;
    final idle = activity == CloudActivity.idle;
    final float = idle ? -7 * cycle : 0.0;
    final rotate = idle && motion
        ? ui.lerpDouble(-1.5, 1, cycle)! * math.pi / 180
        : 0.0;
    canvas.translate(300, 70 + float + (1 - entry) * 3);
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
    final headTurn = activity == CloudActivity.thinking && motion
        ? -.012 * math.sin(time * math.pi / 2)
        : activity == CloudActivity.complete && motion && time < 1.15
        ? math.sin(time / 1.15 * math.pi * 4) * .018
        : 0.0;
    final cosine = math.cos(headTurn), sine = math.sin(headTurn);
    for (var i = 0; i < CloudReferenceMesh.count; i++) {
      final x = mesh.coordinates[i * 2], y = mesh.coordinates[i * 2 + 1];
      final weight = mesh.head[i];
      final dx = x - pivot.dx, dy = y - pivot.dy;
      points[i * 2] += ((dx * cosine - dy * sine) - dx) * weight;
      points[i * 2 + 1] +=
          (((dx * sine + dy * cosine) - dy) + cycle * 1.6) * weight;
      for (var a = 0; a < scene.arms.length; a++) {
        final arm = scene.arms[a];
        final armWeight = mesh.armWeights[a][i];
        if (armWeight == 0) continue;
        var lift = 0.0, angle = 0.0;
        if (motion && activity == CloudActivity.coding) {
          final sign = arm.side == 0 ? 1.0 : -1.0;
          final burst = time % 1.6 < 1.28 ? 1.0 : 0.0;
          lift =
              -math.max(0.0, math.sin(time * math.pi / .16) * sign) *
              2.4 *
              burst;
          angle = math.sin(time * math.pi / .16) * .022 * sign * burst;
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
        points[i * 2] += ((ax * c - ay * s) - ax) * armWeight;
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
    final blink =
        motion &&
        scene.eyes.isNotEmpty &&
        ((time >= 3.65 && time < 3.78) || (time >= 7.6 && time < 7.73));
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

  @override
  bool shouldRepaint(covariant CloudCompanionPainter old) =>
      old.image != image ||
      old.rig != rig ||
      old.pose != pose ||
      old.activity != activity ||
      old.seconds != seconds ||
      old.entry != entry ||
      old.motion != motion ||
      old.greeting != greeting;
}
