import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_motion.dart';
import 'package:ski/cloud_pet_pack.dart';

Map<String, dynamic> manifest() =>
    jsonDecode(
          File('assets/branding/cloud_pet/coding-v1.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  test('a state pack plays entry once, repeats the loop, and ends at rest', () {
    final pack = CloudPetPack.fromJson(manifest());
    expect(pack.sample(0).segment, CloudPetSegment.start);
    expect(pack.sample(.13).frame, 0);
    final startSeconds = pack.start.durationMs / 1000;
    final loopSeconds = pack.loop.durationMs / 1000;
    expect(pack.sample(startSeconds).segment, CloudPetSegment.loop);
    expect(
      pack.sample(startSeconds + .02).frame,
      pack.sample(startSeconds + loopSeconds * 10 + .02).frame,
    );
    expect(pack.sample(8.01).segment, CloudPetSegment.loop);
    expect(
      pack.loop.frames.map((frame) => frame.index).toSet(),
      containsAll([0, 23, 24, 47, 48, 71]),
    );
    expect(
      pack.sample(0, segment: CloudPetSegment.end).segment,
      CloudPetSegment.end,
    );
    expect(
      pack.sample(.31, segment: CloudPetSegment.end).frame,
      pack.holdFrame,
    );
    expect(pack.sample(.1, moving: false).frame, pack.holdFrame);
  });
  test('pack dimensions, durations, indices and local assets are checked', () {
    final pack = CloudPetPack.fromJson(manifest());
    pack.validateAtlas(const Size(2048, 2304));
    expect(
      () => pack.validateAtlas(const Size(384, 512)),
      throwsFormatException,
    );
    expect(pack.frameOrigin(9), const Offset(256, 256));
    final invalid = manifest()..['atlas'] = 'https://example.com/pack.png';
    expect(() => CloudPetPack.fromJson(invalid), throwsFormatException);
    final empty = manifest();
    (empty['clips'] as Map)['B_Loop'] = [];
    expect(() => CloudPetPack.fromJson(empty), throwsFormatException);
    final invalidFrame = manifest();
    (invalidFrame['clips'] as Map)['A_Start'] = [
      [(invalidFrame['frameCount'] as int) + 1, 100],
    ];
    expect(() => CloudPetPack.fromJson(invalidFrame), throwsFormatException);
  });
  test(
    'whole frames retain slow pacing without cropped or blended body parts',
    () {
      final data = manifest();
      final pack = CloudPetPack.fromJson(data);
      expect(pack.start.durationMs, 240);
      expect(pack.loop.durationMs, 5230);
      expect(pack.end.durationMs, 300);
      for (final name in ['B_Loop', 'B_SideTyping', 'B_Touchpad']) {
        final frames = (data['clips'] as Map)[name] as List;
        expect(frames.length, 24);
        expect(
          frames.take(23).every((frame) => (frame as List)[1] <= 45),
          true,
        );
      }
      expect(pack.wholeFrames, true);
      expect(pack.viewport, const Rect.fromLTWH(0, 0, 256, 256));
      expect(pack.frameBlendMs, 0);
      expect(pack.framePaths, isNull);
      expect(pack.fixedRegions, isEmpty);
      expect(pack.underlayRegions, isEmpty);
      expect(pack.eyes, isEmpty);
      expect(pack.sample(.27).mix, 0);
      expect(pack.sample(10, moving: false).mix, 0);
      final cropped = manifest()..['viewport'] = [0, 20, 256, 236];
      expect(() => CloudPetPack.fromJson(cropped), throwsFormatException);
      final blended = manifest()..['frameBlendMs'] = 12;
      expect(() => CloudPetPack.fromJson(blended), throwsFormatException);
      final overlaid = manifest()
        ..['fixedRegions'] = [
          [0, 0, 256, 160],
        ];
      expect(() => CloudPetPack.fromJson(overlaid), throwsFormatException);
    },
  );
}
