import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_typing_motion.dart';

void main() {
  test('a tap has a distinct lift, key contact, rebound and rest', () {
    expect(CloudTypingStroke.sample(.16, 0).height, greaterThan(23));
    expect(CloudTypingStroke.sample(.2325, 0).press, closeTo(1, .001));
    expect(CloudTypingStroke.sample(.2325, 0).height, lessThan(-1));
    expect(CloudTypingStroke.sample(.27, 0).height, greaterThan(1));
    expect(CloudTypingStroke.sample(1.5, 0).height, 0);
    expect(CloudTypingStroke.sample(1.5, 1).height, 0);
  });
  test('the other wrist alternates and each phrase loops without a jump', () {
    expect(
      CloudTypingStroke.sample(.16, 0).height,
      greaterThan(CloudTypingStroke.sample(.16, 1).height),
    );
    expect(
      CloudTypingStroke.sample(.36, 1).height,
      greaterThan(CloudTypingStroke.sample(.36, 0).height),
    );
    for (final side in [0, 1]) {
      expect(
        CloudTypingStroke.sample(0, side).height,
        CloudTypingStroke.sample(1.6, side).height,
      );
      for (var i = 0; i < 1600; i++) {
        final sample = CloudTypingStroke.sample(i / 1000, side);
        expect(sample.height, inInclusiveRange(-1.41, 24.01));
        expect(sample.roll.isFinite, true);
      }
    }
  });
  test(
    'wrists lift off their keys while connected bones keep their lengths',
    () {
      for (final side in [0, 1]) {
        var clearance = 0.0;
        for (var frame = 0; frame < 480; frame++) {
          final arm = CloudTypingArm.sample(frame / 300, side);
          expect(
            (arm.elbow - arm.shoulder).distance,
            closeTo(CloudTypingArm.upperLength, .00001),
          );
          expect(
            (arm.wrist - arm.elbow).distance,
            closeTo(CloudTypingArm.foreLength, .00001),
          );
          final lifted = CloudTypingArm.key(side).dy - arm.fingertip.dy;
          if (lifted > clearance) clearance = lifted;
        }
        expect(clearance, greaterThan(21));
        final resting = CloudTypingArm.sample(1.5, side);
        expect(resting.fingertip, CloudTypingArm.key(side));
        final still = CloudTypingArm.sample(.16, side, moving: false);
        expect(still.fingertip, CloudTypingArm.key(side));
      }
    },
  );
}
