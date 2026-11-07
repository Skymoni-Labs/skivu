import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_portrait.dart';

void main() {
  testWidgets(
    'original character asset decodes, greeting settles and reduced motion remains still',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CloudCompanionPortrait())),
      );
      final portrait = find.byKey(const ValueKey('cloud-companion-portrait'));
      for (
        var i = 0;
        i < 100 && find.byIcon(Icons.cloud_outlined).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        find.byIcon(Icons.cloud_outlined),
        findsNothing,
        reason: 'Use the actual decoded character, not a logo fallback',
      );
      expect(
        find.descendant(of: portrait, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
      await tester.tap(portrait);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CloudCompanionPortrait(reduceMotion: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(portrait);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
