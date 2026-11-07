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
    expect(pack.sample(.13).frame, 16);
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
      containsAll([16, 39, 40, 63, 64, 87]),
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
    pack.validateAtlas(const Size(1536, 1568));
    expect(
      () => pack.validateAtlas(const Size(384, 512)),
      throwsFormatException,
    );
    expect(pack.frameOrigin(5), const Offset(699, 197));
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
  test('inbetweens retain the slow cycle with short moving-frame steps', () {
    final data = manifest();
    final pack = CloudPetPack.fromJson(data);
    expect(pack.start.durationMs, 240);
    expect(pack.loop.durationMs, 5230);
    expect(pack.end.durationMs, 300);
    for (final name in ['B_Loop', 'B_SideTyping', 'B_Touchpad']) {
      final frames = (data['clips'] as Map)[name] as List;
      expect(frames.length, 24);
      expect(frames.take(23).every((frame) => (frame as List)[1] <= 45), true);
    }
    final blended = pack.sample(.27);
    expect(blended.nextFrame, blended.frame + 1);
    expect(blended.mix, greaterThan(0));
    expect(blended.mix, lessThan(1));
    expect(pack.sample(10, moving: false).mix, 0);
    expect(pack.framePaths![16]!.contains(const Offset(70, 316)), false);
    expect(pack.framePaths![16]!.contains(const Offset(130, 350)), true);
  });
}
