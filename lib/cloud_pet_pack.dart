import 'dart:ui';
import 'cloud_companion_motion.dart';

class CloudPetFrame {
  const CloudPetFrame(this.index, this.durationMs);
  final int index, durationMs;
}

class CloudPetClip {
  CloudPetClip(this.frames);
  final List<CloudPetFrame> frames;
  late final int durationMs = frames.fold(
    0,
    (sum, frame) => sum + frame.durationMs,
  );
  int sample(int elapsedMs, {bool loop = false}) {
    var remaining = loop ? elapsedMs % durationMs : elapsedMs;
    for (final frame in frames) {
      if (remaining < frame.durationMs) return frame.index;
      remaining -= frame.durationMs;
    }
    return frames.last.index;
  }
}

class CloudPetSample {
  const CloudPetSample(this.segment, this.frame);
  final CloudPetSegment segment;
  final int frame;
}

/// Per-state, data-driven sprite animation. Uses the VPet ABC organization,
/// with a local Skivu schema; never loads scripts or third-party pet binaries.
class CloudPetPack {
  CloudPetPack.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['activity'] != 'coding') {
      throw const FormatException('Unsupported cloud pet pack');
    }
    id = json['id'] as String;
    atlas = json['atlas'] as String;
    if (!atlas.startsWith('assets/branding/cloud_pet/') ||
        atlas.contains('..')) {
      throw const FormatException('Cloud pet atlas must be a bundled asset');
    }
    final tile = (json['tile'] as List).cast<num>();
    tileSize = Size(tile[0].toDouble(), tile[1].toDouble());
    columns = json['columns'] as int;
    frameCount = json['frameCount'] as int;
    holdFrame = json['holdFrame'] as int;
    if (tileSize.width <= 0 ||
        tileSize.height <= 0 ||
        columns <= 0 ||
        frameCount <= 0) {
      throw const FormatException('Invalid cloud pet atlas dimensions');
    }
    viewport = readRect(json['viewport'] as List);
    animatedRegions = (json['animatedRegions'] as List)
        .map((value) => readRect(value as List))
        .toList();
    fixedRegions = (json['fixedRegions'] as List? ?? [])
        .map((value) => readRect(value as List))
        .toList();
    eyes = (json['eyes'] as List? ?? [])
        .map((value) => readRect(value as List))
        .toList();
    final tileRect = Offset.zero & tileSize;
    for (final rect in [
      viewport,
      ...animatedRegions,
      ...fixedRegions,
      ...eyes,
    ]) {
      if (rect.isEmpty ||
          !tileRect.contains(rect.topLeft) ||
          rect.right > tileRect.right ||
          rect.bottom > tileRect.bottom) {
        throw const FormatException('Cloud pet crop exceeds its tile');
      }
    }
    foreground = Path();
    final polygon = json['foreground'] as List;
    for (var i = 0; i < polygon.length; i++) {
      final point = (polygon[i] as List).cast<num>();
      if (i == 0) {
        foreground.moveTo(point[0].toDouble(), point[1].toDouble());
      } else {
        foreground.lineTo(point[0].toDouble(), point[1].toDouble());
      }
    }
    foreground.close();
    CloudPetClip readClip(String name) {
      final values = (json['clips'] as Map)[name] as List;
      if (values.isEmpty) throw FormatException('Empty cloud pet clip $name');
      return CloudPetClip(
        values.map((value) {
          final pair = value as List;
          final frame = pair[0] as int, duration = pair[1] as int;
          if (frame < 0 ||
              frame >= frameCount ||
              duration <= 0 ||
              duration > 10000) {
            throw FormatException('Invalid cloud pet frame in $name');
          }
          return CloudPetFrame(frame, duration);
        }).toList(),
      );
    }

    start = readClip('A_Start');
    final order = (json['loopOrder'] as List?)?.cast<String>() ?? ['B_Loop'];
    if (order.isEmpty || order.any((name) => !name.startsWith('B_'))) {
      throw const FormatException('Invalid cloud pet loop sequence');
    }
    loop = CloudPetClip([for (final name in order) ...readClip(name).frames]);
    end = readClip('C_End');
    if (holdFrame < 0 || holdFrame >= frameCount) {
      throw const FormatException('Invalid cloud pet hold frame');
    }
  }
  late final String id, atlas;
  late final Size tileSize;
  late final int columns, frameCount, holdFrame;
  late final Rect viewport;
  late final List<Rect> animatedRegions;
  late final List<Rect> fixedRegions;
  late final List<Rect> eyes;
  late final Path foreground;
  late final CloudPetClip start, loop, end;

  static Rect readRect(List values) => Rect.fromLTWH(
    (values[0] as num).toDouble(),
    (values[1] as num).toDouble(),
    (values[2] as num).toDouble(),
    (values[3] as num).toDouble(),
  );
  Offset frameOrigin(int frame) => Offset(
    (frame % columns) * tileSize.width,
    (frame ~/ columns) * tileSize.height,
  );
  void validateAtlas(Size actual) {
    if (actual.width != columns * tileSize.width ||
        actual.height !=
            ((frameCount + columns - 1) ~/ columns) * tileSize.height) {
      throw const FormatException(
        'Cloud pet atlas does not match its manifest',
      );
    }
  }

  bool supports(CloudActivity activity, CloudPose pose) =>
      activity == CloudActivity.coding ||
      (pose.computer > .5 &&
          {
            CloudActivity.thinking,
            CloudActivity.resultReady,
            CloudActivity.stopping,
            CloudActivity.paused,
          }.contains(activity));

  CloudPetSample sample(
    double seconds, {
    CloudPetSegment? segment,
    bool moving = true,
  }) {
    if (!moving || segment == CloudPetSegment.hold) {
      return CloudPetSample(CloudPetSegment.hold, holdFrame);
    }
    final elapsed = (seconds.clamp(0, double.infinity) * 1000).floor();
    if (segment == CloudPetSegment.end) {
      return elapsed >= end.durationMs
          ? CloudPetSample(CloudPetSegment.hold, holdFrame)
          : CloudPetSample(CloudPetSegment.end, end.sample(elapsed));
    }
    if (elapsed < start.durationMs) {
      return CloudPetSample(CloudPetSegment.start, start.sample(elapsed));
    }
    return CloudPetSample(
      CloudPetSegment.loop,
      loop.sample(elapsed - start.durationMs, loop: true),
    );
  }
}
