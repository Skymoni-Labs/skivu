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
    expect(pack.sample(.13).frame, 9);
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
      containsAll([8, 9, 10, 11, 12, 13, 14, 15]),
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
    pack.validateAtlas(const Size(1536, 2048));
    expect(
      () => pack.validateAtlas(const Size(384, 512)),
      throwsFormatException,
    );
    expect(pack.frameOrigin(5), const Offset(384, 512));
    final invalid = manifest()..['atlas'] = 'https://example.com/pack.png';
    expect(() => CloudPetPack.fromJson(invalid), throwsFormatException);
    final empty = manifest();
    (empty['clips'] as Map)['B_Loop'] = [];
    expect(() => CloudPetPack.fromJson(empty), throwsFormatException);
    final invalidFrame = manifest();
    (invalidFrame['clips'] as Map)['A_Start'] = [
      [20, 100],
    ];
    expect(() => CloudPetPack.fromJson(invalidFrame), throwsFormatException);
  });
}
