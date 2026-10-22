import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/voice_call_orb.dart';

void main() {
  testWidgets('orb handles invalid levels, stops reduced motion and disposes', (
    tester,
  ) async {
    final level = ValueNotifier<double>(double.nan);
    var taps = 0;
    Widget scene(bool reduced) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 280,
          height: 280,
          child: VoiceCallOrb(
            level: level,
            onTap: () => taps++,
            dark: false,
            reducedMotion: reduced,
          ),
        ),
      ),
    );

    await tester.pumpWidget(scene(false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.tap(find.byType(VoiceCallOrb));
    expect(taps, 1);
    level.value = double.infinity;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(scene(true));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    level.value = 1;
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(scene(false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    level.dispose();
    expect(tester.takeException(), isNull);
  });
}
