import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_motion.dart';
import 'package:ski/cloud_pet_catalog.dart';
import 'package:ski/cloud_pet_flow.dart';
import 'package:ski/cloud_pet_pack.dart';

void main() {
  final raw =
      jsonDecode(
            File(
              'assets/branding/cloud_pet/workflow-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final catalog = CloudPetCatalog.fromJson(raw);
  test('a held inspection really stops before a full length transition', () {
    final pack = catalog.packs[CloudActivity.checking]!;
    final clip = pack.loop;
    final i = clip.frames.indexWhere((f) => f.index == 4);
    final beginning = clip.frames
        .take(i)
        .fold<int>(0, (n, f) => n + f.durationMs);
    final pose = clip.frames[i];
    expect(pose.holdMs, greaterThanOrEqualTo(1500));
    for (final delta in [0, 400, 1000, 1500]) {
      final sample = pack.sampleClip(
        clip,
        beginning + delta,
        CloudPetSegment.loop,
        next: 0,
      );
      expect(sample.frame, 4);
      expect(sample.progress, 0);
    }
    final halfway =
        beginning + pose.holdMs + (pose.durationMs - pose.holdMs) ~/ 2;
    expect(
      pack.sampleClip(clip, halfway, CloudPetSegment.loop, next: 0).progress,
      closeTo(.5, .001),
    );
    final bridge = CloudPetClip([const CloudPetFrame(0, 2100, holdMs: 1500)]);
    expect(
      pack.sampleClip(bridge, 1500, CloudPetSegment.loop, next: 1).progress,
      0,
    );
    expect(
      pack.sampleClip(bridge, 1800, CloudPetSegment.loop, next: 1).progress,
      .5,
    );
    expect(
      pack.sampleClip(bridge, 1980, CloudPetSegment.loop, next: 1).progress,
      .8,
    );
    expect(clip.durationMs, greaterThanOrEqualTo(10000));
  });

  test(
    'timing cannot hide negative rests, zero transitions or unknown easing',
    () {
      for (final timing in [
        [0, 500, -1],
        [0, 500, 500],
        [0, 500, 0, 2],
      ]) {
        final invalid =
            jsonDecode(jsonEncode(raw['packs']['coding']))
                as Map<String, dynamic>;
        invalid['clips']['A_Start'] = [timing];
        expect(() => CloudPetPack.fromJson(invalid), throwsFormatException);
      }
    },
  );
  test(
    'every distinct entry, loop, greeting and exit edge has a bounded numeric field',
    () {
      for (final pack in catalog.packs.values) {
        final flow = pack.flow!;
        expect(File(flow.atlas).existsSync(), true);
        final clips = [
          (pack.start, pack.loop.frames.first.index),
          (pack.loop, pack.loop.frames.first.index),
          (pack.end, pack.holdFrame),
          if (pack.greetingClip != null) (pack.greetingClip!, pack.holdFrame),
        ];
        for (final (clip, last) in clips) {
          for (var i = 0; i < clip.frames.length; i++) {
            final a = clip.frames[i].index,
                b = i + 1 < clip.frames.length
                    ? clip.frames[i + 1].index
                    : last;
            if (a == b) continue;
            final origin = flow.origin(a, b);
            expect(origin, isNotNull, reason: '${pack.activityName}: $a -> $b');
            expect(
              origin!.dx + flow.cell * 2,
              lessThanOrEqualTo(flow.size.width),
            );
            expect(origin.dy + flow.cell, lessThanOrEqualTo(flow.size.height));
          }
        }
      }
    },
  );
  test(
    'continuous progress advances between drawings without speeding the approved timeline',
    () {
      final pack = catalog.packs[CloudActivity.thinking]!;
      final start = pack.start.durationMs / 1000;
      final before = pack.sample(start + .010),
          after = pack.sample(start + .025);
      expect(before.frame, after.frame);
      expect(before.nextFrame, after.nextFrame);
      expect(after.progress, greaterThan(before.progress));
      expect(
        before.mix,
        0,
        reason:
            'Whole frames do not use the old dissolve-only/hand-overlay path',
      );
      expect(pack.sample(start + .025, moving: false).progress, 0);
      final coding = catalog.packs[CloudActivity.coding]!;
      expect(coding.loop.durationMs, 3640);
      expect(coding.loop.frames.every((frame) => frame.holdMs == 0), true);
      final idle = catalog.packs[CloudActivity.idle]!;
      final longRest = idle.loop.frames.indexWhere((f) => f.holdMs > 0);
      final holdStart =
          (idle.start.durationMs +
              idle.loop.frames
                  .take(longRest)
                  .fold<int>(0, (sum, frame) => sum + frame.durationMs)) /
          1000;
      expect(
        idle.sample(holdStart + .01).progress,
        0,
        reason: 'Deliberate long rests retain their pause before movement',
      );
    },
  );
  test(
    'motion fields reject external assets, repeated edges and invalid frame references',
    () {
      final valid = raw['packs']['phone']['motionFlow'] as Map;
      Map<String, dynamic> copy() =>
          jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
      final external = copy()..['atlas'] = 'https://example.com/data.png';
      expect(() => CloudPetFlow.fromJson(external, 24), throwsFormatException);
      final invalid = copy();
      (invalid['pairs'] as List)[0] = [0, 24];
      expect(() => CloudPetFlow.fromJson(invalid, 24), throwsFormatException);
      final duplicate = copy();
      (duplicate['pairs'] as List)[1] = (duplicate['pairs'] as List)[0];
      expect(() => CloudPetFlow.fromJson(duplicate, 24), throwsFormatException);
    },
  );
}
