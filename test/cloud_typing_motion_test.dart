import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_typing_motion.dart';

void main() {
  test('a tap has a distinct lift, key contact, rebound and rest', () {
    expect(CloudTypingStroke.sample(.16, 0).height, greaterThan(6));
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
        expect(sample.height, inInclusiveRange(-1.16, 6.51));
        expect(sample.roll.isFinite, true);
      }
    }
  });
}
