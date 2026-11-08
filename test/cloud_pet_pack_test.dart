import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_motion.dart';
import 'package:ski/cloud_pet_pack.dart';
import 'package:crypto/crypto.dart';

Map<String, dynamic> manifest() =>
    jsonDecode(
          File('assets/branding/cloud_pet/coding-v1.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  test(
    'the selected hidden-hand phrase repeats continuously without a reading pause',
    () {
      final data = manifest(), pack = CloudPetPack.fromJson(manifest());
      final hidden = (data['occludedLeftFrames'] as List).cast<int>().toSet();
      expect(hidden.where((f) => f >= 72).toSet(), {
        for (var i = 72; i < 88; i++) i,
      });
      final hiddenMs = pack.loop.frames
          .where((f) => hidden.contains(f.index))
          .fold<int>(0, (n, f) => n + f.durationMs);
      expect(pack.loop.durationMs, 3640);
      expect(pack.loop.frames.every((f) => f.holdMs == 0), true);
      for (var i = 0; i < pack.loop.frames.length; i++) {
        expect(
          pack.loop.frames[i].index,
          isNot(pack.loop.frames[(i + 1) % pack.loop.frames.length].index),
          reason: 'Repeated drawings must not create a stationary loop seam',
        );
      }
      expect(hiddenMs, pack.loop.durationMs);
      expect(pack.loop.frames.every((f) => f.index >= 72), true);
      for (var ms = 0; ms < 15000; ms += 4) {
        final sample = pack.sample(pack.start.durationMs / 1000 + ms / 1000);
        expect(sample.frame, inInclusiveRange(72, 87));
        expect(sample.nextFrame, inInclusiveRange(72, 87));
        expect(sample.progress.isFinite, true);
      }
      expect(hidden.intersection(pack.excludedFrames), isEmpty);
      expect(pack.start.frames.first.index, 87);
      expect(pack.end.frames.every((f) => hidden.contains(f.index)), true);
    },
  );

  testWidgets('the added atlas retains every original RGBA pixel', (
    tester,
  ) async {
    final data = manifest(), pack = CloudPetPack.fromJson(manifest());
    await tester.runAsync(() async {
      final oldCodec = await instantiateImageCodec(
        await File(data['originalAtlas'] as String).readAsBytes(),
      );
      final newCodec = await instantiateImageCodec(
        await File(pack.atlas).readAsBytes(),
      );
      final oldImage = (await oldCodec.getNextFrame()).image;
      final newImage = (await newCodec.getNextFrame()).image;
      try {
        final original = (await oldImage.toByteData(
          format: ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final combined = (await newImage.toByteData(
          format: ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        expect(oldImage.width, newImage.width);
        expect(
          sha256.convert(combined.sublist(0, original.length)).toString(),
          sha256.convert(original).toString(),
        );
      } finally {
        oldImage.dispose();
        newImage.dispose();
        oldCodec.dispose();
        newCodec.dispose();
      }
    });
  });
  test(
    'bad source poses never appear on either side of interpolation or an exit',
    () {
      final pack = CloudPetPack.fromJson(manifest());
      final rejected = {for (var i = 27; i <= 35; i++) i};
      expect(pack.excludedFrames, rejected);
      for (final clip in [pack.start, pack.loop, pack.end]) {
        for (var ms = 0; ms < clip.durationMs; ms += 4) {
          final sample = pack.sampleClip(
            clip,
            ms,
            CloudPetSegment.loop,
            next: pack.holdFrame,
          );
          expect(rejected.contains(sample.frame), false);
          expect(rejected.contains(sample.nextFrame), false);
        }
      }
      for (final pair in pack.flow!.edges.keys) {
        expect(pair.split(':').map(int.parse).any(rejected.contains), false);
      }
    },
  );
  test(
    'asset selection refuses accidentally reintroducing a known third-hand frame',
    () {
      final invalid = manifest();
      (invalid['clips'] as Map)['A_Start'] = [
        [29, 100],
      ];
      expect(() => CloudPetPack.fromJson(invalid), throwsFormatException);
      final invalidHold = manifest()..['holdFrame'] = 30;
      expect(() => CloudPetPack.fromJson(invalidHold), throwsFormatException);
    },
  );
  test(
    'coding keeps the exact approved artwork and continuously moves between drawings',
    () {
      final data = manifest();
      final pack = CloudPetPack.fromJson(data);
      expect(
        sha256
            .convert(File(data['originalAtlas'] as String).readAsBytesSync())
            .toString(),
        'a5531a4f0f13d2ccfe292112a547b5f5cbaa473932bd09c94a696361271d8e1e',
      );
      expect(pack.singleSourceMotion, true);
      expect(pack.loop.frames.where((f) => f.holdMs > 0), isEmpty);
      for (final name in ['B_TypeWithLeftHidden']) {
        final frames = (data['clips'] as Map)[name] as List;
        expect(
          frames.every((row) => (row as List)[2] == 0),
          true,
          reason: 'Movement stays connected inside an authored operation',
        );
      }
    },
  );
  testWidgets(
    'all complete coding drawings share one desk baseline and width',
    (tester) async {
      final pack = CloudPetPack.fromJson(manifest());
      await tester.runAsync(() async {
        final codec = await instantiateImageCodec(
          await File(pack.atlas).readAsBytes(),
        );
        final image = (await codec.getNextFrame()).image;
        try {
          final bytes = (await image.toByteData(
            format: ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          Offset? reference;
          double? referenceWidth;
          for (var i = 0; i < pack.frameCount; i++) {
            final origin = pack.frameOrigin(i),
                registration = pack.frameTransform(i);
            var left = 256, right = 0, bottom = 0;
            for (var y = 0; y < 256; y++) {
              for (var x = 0; x < 256; x++) {
                final alpha =
                    bytes[((origin.dy.toInt() + y) * image.width +
                                origin.dx.toInt() +
                                x) *
                            4 +
                        3];
                if (alpha > 8) {
                  final p = registration.map(
                    Offset(x.toDouble(), y.toDouble()),
                  );
                  expect(
                    p.dx >= 2 && p.dx <= 254 && p.dy >= 2 && p.dy <= 254,
                    true,
                    reason: 'Complete source art must remain inside frame $i',
                  );
                }
                if (y >= 180 && alpha > 150) {
                  if (x < left) left = x;
                  if (x > right) right = x;
                  if (y > bottom) bottom = y;
                }
              }
            }
            final anchor = registration.map(
              Offset((left + right) / 2, bottom.toDouble()),
            );
            final width = (right - left + 1) * registration.scale;
            reference ??= anchor;
            referenceWidth ??= width;
            expect(
              (anchor - reference).distance,
              lessThan(.001),
              reason: 'Desk in frame $i must not shake',
            );
            expect(width, closeTo(referenceWidth, .001));
          }
        } finally {
          image.dispose();
          codec.dispose();
        }
      });
    },
  );

  test('a state pack plays entry once, repeats the loop, and ends at rest', () {
    final pack = CloudPetPack.fromJson(manifest());
    expect(pack.sample(0).segment, CloudPetSegment.start);
    expect(pack.sample(.13).frame, pack.holdFrame);
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
      equals({for (var i = 72; i < 88; i++) i}),
    );
    expect(
      pack.sample(0, segment: CloudPetSegment.end).segment,
      CloudPetSegment.end,
    );
    expect(pack.sample(1, segment: CloudPetSegment.end).frame, pack.holdFrame);
    expect(pack.sample(.1, moving: false).frame, pack.holdFrame);
  });
  test('pack dimensions, durations, indices and local assets are checked', () {
    final pack = CloudPetPack.fromJson(manifest());
    pack.validateAtlas(pack.atlasSize!);
    expect(
      () => pack.validateAtlas(const Size(384, 512)),
      throwsFormatException,
    );
    expect(pack.frameOrigin(9), const Offset(256, 256));
    final invalid = manifest()..['atlas'] = 'https://example.com/pack.png';
    expect(() => CloudPetPack.fromJson(invalid), throwsFormatException);
    final empty = manifest();
    (empty['clips'] as Map)[(empty['loopOrder'] as List).first] = [];
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
      expect(pack.start.durationMs, 700);
      expect(pack.loop.durationMs, 3640);
      expect(pack.end.durationMs, greaterThanOrEqualTo(600));
      for (final name in ['B_TypeWithLeftHidden']) {
        final frames = (data['clips'] as Map)[name] as List;
        expect(frames.length, greaterThanOrEqualTo(24));
        expect(
          frames.take(23).every((frame) => (frame as List)[1] >= 60),
          true,
        );
      }
      expect(pack.loop.frames.where((f) => f.holdMs > 0), isEmpty);
      expect(pack.singleSourceMotion, true);
      expect(pack.loop.frames.map((f) => f.index).toSet().length, 16);
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
