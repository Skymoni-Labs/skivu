import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_motion.dart';
import 'package:ski/cloud_pet_catalog.dart';

Map<String, dynamic> workflow() =>
    jsonDecode(
          File('assets/branding/cloud_pet/workflow-v1.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  test('every actual task phase has an intact animated and loading scene', () {
    final catalog = CloudPetCatalog.fromJson(workflow());
    expect(catalog.packs.keys, containsAll(CloudActivity.values));
    for (final activity in CloudActivity.values) {
      final pack = catalog.packs[activity]!;
      expect(pack.activityName, activity.name);
      expect(pack.wholeFrames, true);
      expect(pack.fixedRegions, isEmpty);
      expect(pack.framePaths, isNull);
      expect(pack.frameBlendMs, 0);
      expect(pack.repeats, activity.continuous);
      expect(File(pack.atlas).existsSync(), true);
      expect(catalog.fallbacks[activity]!.activityName, activity.name);
    }
    // A final answer or an uncertain result must not borrow the verified
    // success card, while stopping/paused share their calm resting artwork.
    expect(
      catalog.packs[CloudActivity.resultReady]!.atlas,
      catalog.packs[CloudActivity.checking]!.atlas,
    );
    for (final activity in [
      CloudActivity.checking,
      CloudActivity.resultReady,
    ]) {
      expect(
        catalog.packs[activity]!.singleSourceMotion,
        true,
        reason: 'The magnifier and paper must share one occlusion owner',
      );
    }
    expect(
      catalog.packs[CloudActivity.resultReady]!.atlas,
      isNot(catalog.packs[CloudActivity.complete]!.atlas),
    );
    expect(
      catalog.packs[CloudActivity.paused]!.atlas,
      catalog.packs[CloudActivity.stopping]!.atlas,
    );
    expect(catalog.packs[CloudActivity.idle]!.greetingClip, isNotNull);
  });

  test('one-shot results settle while active work continues to animate', () {
    final catalog = CloudPetCatalog.fromJson(workflow());
    for (final activity in CloudActivity.values) {
      final pack = catalog.packs[activity]!;
      final after = (pack.start.durationMs + pack.loop.durationMs + 100) / 1000;
      expect(
        pack.sample(after).segment,
        activity.continuous ? CloudPetSegment.loop : CloudPetSegment.hold,
      );
      expect(pack.sample(1, moving: false).frame, pack.holdFrame);
    }
    final idle = catalog.packs[CloudActivity.idle]!;
    expect(idle.sample(.5, greeting: true).segment, CloudPetSegment.start);
  });

  test('incomplete and mismatched states fail closed', () {
    final missing = workflow();
    (missing['packs'] as Map).remove('permission');
    expect(() => CloudPetCatalog.fromJson(missing), throwsFormatException);
    final swapped = workflow();
    (swapped['packs'] as Map)['checking'] =
        (swapped['packs'] as Map)['complete'];
    expect(() => CloudPetCatalog.fromJson(swapped), throwsFormatException);
  });
}
