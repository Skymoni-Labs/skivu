import 'dart:ui';
import 'cloud_companion_motion.dart';
import 'cloud_pet_flow.dart';

class CloudPetFrame {
  const CloudPetFrame(
    this.index,
    this.durationMs, {
    this.holdMs = 0,
    this.ease = false,
  });
  final int index, durationMs;
  final int holdMs;
  final bool ease;
}

/// Registers an entire source drawing to a stable scene, including its head,
/// hands and props. Never crops or independently pins a body part.
class CloudFrameTransform {
  const CloudFrameTransform(this.scale, this.offset);
  static const identity = CloudFrameTransform(1, Offset.zero);
  final double scale;
  final Offset offset;

  Offset map(Offset point) => point * scale + offset;
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
  const CloudPetSample(
    this.segment,
    this.frame, {
    int? nextFrame,
    this.mix = 0,
    this.progress = 0,
  }) : nextFrame = nextFrame ?? frame;
  final CloudPetSegment segment;
  final int frame;
  final int nextFrame;
  final double mix;
  final double progress;
}

/// Per-state, data-driven sprite animation. Uses the VPet ABC organization,
/// with a local Skivu schema; never loads scripts or third-party pet binaries.
class CloudPetPack {
  CloudPetPack.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        !CloudActivity.values.any((value) => value.name == json['activity'])) {
      throw const FormatException('Unsupported cloud pet pack');
    }
    id = json['id'] as String;
    activityName = json['activity'] as String;
    repeats = json['repeat'] as bool? ?? true;
    wholeFrames = json['wholeFrames'] as bool? ?? false;
    atlas = json['atlas'] as String;
    if (!atlas.startsWith('assets/branding/cloud_pet/') ||
        atlas.contains('..')) {
      throw const FormatException('Cloud pet atlas must be a bundled asset');
    }
    final tile = (json['tile'] as List).cast<num>();
    tileSize = Size(tile[0].toDouble(), tile[1].toDouble());
    columns = json['columns'] as int;
    frameCount = json['frameCount'] as int;
    frameTransforms = (json['frameTransforms'] as List?)?.map((raw) {
      final values = raw as List;
      if (values.length != 3 || values.any((v) => v is! num)) {
        throw const FormatException('Invalid cloud scene registration');
      }
      final scale = (values[0] as num).toDouble();
      final dx = (values[1] as num).toDouble();
      final dy = (values[2] as num).toDouble();
      if (!scale.isFinite ||
          scale < .8 ||
          scale > 1.2 ||
          !dx.isFinite ||
          !dy.isFinite ||
          dx.abs() > 32 ||
          dy.abs() > 32) {
        throw const FormatException('Invalid cloud scene registration');
      }
      return CloudFrameTransform(scale, Offset(dx, dy));
    }).toList();
    if (frameTransforms != null && frameTransforms!.length != frameCount) {
      throw const FormatException('Incomplete cloud scene registration');
    }
    flow = json['motionFlow'] == null
        ? null
        : CloudPetFlow.fromJson(
            Map<String, dynamic>.from(json['motionFlow'] as Map),
            frameCount,
          );
    final dimensions = (json['atlasSize'] as List?)?.cast<num>();
    atlasSize = dimensions == null
        ? null
        : Size(dimensions[0].toDouble(), dimensions[1].toDouble());
    frameOrigins = (json['frameOrigins'] as List?)?.map((raw) {
      final values = (raw as List).cast<num>();
      return Offset(values[0].toDouble(), values[1].toDouble());
    }).toList();
    frameBlendMs = json['frameBlendMs'] as int? ?? 0;
    framePaths = (json['framePaths'] as List?)?.map((raw) {
      if (raw == null) return null;
      final path = Path();
      for (final polygon in raw as List) {
        final points = polygon as List;
        for (var i = 0; i < points.length; i++) {
          final point = (points[i] as List).cast<num>();
          if (i == 0) {
            path.moveTo(point[0].toDouble(), point[1].toDouble());
          } else {
            path.lineTo(point[0].toDouble(), point[1].toDouble());
          }
        }
        path.close();
      }
      return path;
    }).toList();
    if ((frameOrigins != null && frameOrigins!.length != frameCount) ||
        frameBlendMs < 0 ||
        frameBlendMs > 100 ||
        (framePaths != null && framePaths!.length != frameCount)) {
      throw const FormatException('Invalid cloud pet frame table');
    }
    holdFrame = json['holdFrame'] as int;
    underlayFrame = json['underlayFrame'] as int? ?? 0;
    underlayRegions = (json['underlayRegions'] as List? ?? [])
        .map((value) => readRect(value as List))
        .toList();
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
      ...underlayRegions,
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
    if (wholeFrames &&
        (viewport != tileRect ||
            frameBlendMs != 0 ||
            framePaths != null ||
            fixedRegions.isNotEmpty ||
            underlayRegions.isNotEmpty ||
            eyes.isNotEmpty ||
            polygon.isNotEmpty)) {
      throw const FormatException(
        'Whole cloud frames cannot have partial crops or overlaid body parts',
      );
    }
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
          if (pair.length < 2 || pair.length > 4) {
            throw FormatException('Invalid cloud pet timing in $name');
          }
          final frame = pair[0] as int, duration = pair[1] as int;
          final hold = pair.length > 2 ? pair[2] as int : 0;
          final ease = pair.length > 3 ? pair[3] as int : 0;
          if (frame < 0 ||
              frame >= frameCount ||
              duration <= 0 ||
              duration > 10000 ||
              hold < 0 ||
              hold >= duration ||
              (ease != 0 && ease != 1)) {
            throw FormatException('Invalid cloud pet frame in $name');
          }
          return CloudPetFrame(frame, duration, holdMs: hold, ease: ease == 1);
        }).toList(),
      );
    }

    start = readClip('A_Start');
    greetingClip = (json['clips'] as Map).containsKey('A_Greeting')
        ? readClip('A_Greeting')
        : null;
    final order = (json['loopOrder'] as List?)?.cast<String>() ?? ['B_Loop'];
    if (order.isEmpty || order.any((name) => !name.startsWith('B_'))) {
      throw const FormatException('Invalid cloud pet loop sequence');
    }
    loop = CloudPetClip([for (final name in order) ...readClip(name).frames]);
    end = readClip('C_End');
    if (holdFrame < 0 ||
        holdFrame >= frameCount ||
        underlayFrame < 0 ||
        underlayFrame >= frameCount) {
      throw const FormatException('Invalid cloud pet hold frame');
    }
  }
  late final String id, atlas, activityName;
  late final bool repeats;
  late final bool wholeFrames;
  late final CloudPetFlow? flow;
  late final Size tileSize;
  late final Size? atlasSize;
  late final List<Offset>? frameOrigins;
  late final List<CloudFrameTransform>? frameTransforms;
  late final List<Path?>? framePaths;
  late final int frameBlendMs;
  late final int columns, frameCount, holdFrame, underlayFrame;
  late final Rect viewport;
  late final List<Rect> animatedRegions;
  late final List<Rect> fixedRegions, underlayRegions;
  late final List<Rect> eyes;
  late final Path foreground;
  late final CloudPetClip start, loop, end;
  late final CloudPetClip? greetingClip;

  static Rect readRect(List values) => Rect.fromLTWH(
    (values[0] as num).toDouble(),
    (values[1] as num).toDouble(),
    (values[2] as num).toDouble(),
    (values[3] as num).toDouble(),
  );
  Offset frameOrigin(int frame) =>
      frameOrigins?[frame] ??
      Offset(
        (frame % columns) * tileSize.width,
        (frame ~/ columns) * tileSize.height,
      );
  CloudFrameTransform frameTransform(int frame) =>
      frameTransforms?[frame] ?? CloudFrameTransform.identity;
  void validateAtlas(Size actual) {
    final expected =
        atlasSize ??
        Size(
          columns * tileSize.width,
          ((frameCount + columns - 1) ~/ columns) * tileSize.height,
        );
    if (actual != expected) {
      throw const FormatException(
        'Cloud pet atlas does not match its manifest',
      );
    }
    for (var frame = 0; frame < frameCount; frame++) {
      for (final region in animatedRegions) {
        final source = region.shift(frameOrigin(frame));
        if (source.left < 0 ||
            source.top < 0 ||
            source.right > actual.width ||
            source.bottom > actual.height) {
          throw const FormatException('Cloud pet frame exceeds the atlas');
        }
      }
    }
  }

  bool supports(CloudActivity activity, CloudPose pose) =>
      activity.name == activityName ||
      (activityName == 'coding' &&
          pose.computer > .5 &&
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
    bool greeting = false,
  }) {
    if (!moving || segment == CloudPetSegment.hold) {
      return CloudPetSample(CloudPetSegment.hold, holdFrame);
    }
    final elapsed = (seconds.clamp(0, double.infinity) * 1000 + 1e-6).floor();
    if (greeting &&
        greetingClip != null &&
        elapsed < greetingClip!.durationMs) {
      return sampleClip(
        greetingClip!,
        elapsed,
        CloudPetSegment.start,
        next: holdFrame,
      );
    }
    if (segment == CloudPetSegment.end) {
      return elapsed >= end.durationMs
          ? CloudPetSample(CloudPetSegment.hold, holdFrame)
          : sampleClip(end, elapsed, CloudPetSegment.end, next: holdFrame);
    }
    if (elapsed < start.durationMs) {
      return sampleClip(
        start,
        elapsed,
        CloudPetSegment.start,
        next: loop.frames.first.index,
      );
    }
    final loopElapsed = elapsed - start.durationMs;
    if (!repeats && loopElapsed >= loop.durationMs) {
      return CloudPetSample(CloudPetSegment.hold, holdFrame);
    }
    return sampleClip(
      loop,
      loopElapsed % loop.durationMs,
      CloudPetSegment.loop,
      next: loop.frames.first.index,
    );
  }

  CloudPetSample sampleClip(
    CloudPetClip clip,
    int elapsed,
    CloudPetSegment segment, {
    required int next,
  }) {
    var remaining = elapsed;
    for (var i = 0; i < clip.frames.length; i++) {
      final current = clip.frames[i];
      if (remaining < current.durationMs) {
        final target = i + 1 < clip.frames.length
            ? clip.frames[i + 1].index
            : next;
        final window = frameBlendMs.clamp(0, current.durationMs);
        final mix = window == 0 || target == current.index
            ? 0.0
            : ((remaining - current.durationMs + window) / window).clamp(
                0.0,
                1.0,
              );
        // A rest and a transition are separate authored intervals. Long
        // movements must not be squeezed into a final 120 ms burst.
        var progress =
            ((remaining - current.holdMs) /
                    (current.durationMs - current.holdMs))
                .clamp(0.0, 1.0);
        if (current.ease) progress = progress * progress * (3 - 2 * progress);
        return CloudPetSample(
          segment,
          current.index,
          nextFrame: target,
          mix: mix,
          progress: target == current.index ? 0 : progress,
        );
      }
      remaining -= current.durationMs;
    }
    return CloudPetSample(segment, next);
  }
}
