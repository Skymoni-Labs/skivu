import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/app_alphabet_ruler.dart';
import 'package:ski/engine_app_selection_page.dart';

void main() {
  testWidgets(
    'ruler ignores taps and pre-hold drags, scrubs only while held, clears on release',
    (tester) async {
      final jumps = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 34,
                height: 400,
                child: AppAlphabetRuler(
                  letters: const ['A', 'B', 'M', 'Z'],
                  onJump: jumps.add,
                ),
              ),
            ),
          ),
        ),
      );
      final ruler = find.byKey(const ValueKey('engine-app-alphabet-ruler'));
      await tester.tap(ruler);
      await tester.pumpAndSettle();
      await tester.drag(ruler, const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(jumps, isEmpty);
      final bounds = tester.getRect(ruler);
      final hold = await tester.startGesture(
        Offset(bounds.center.dx, bounds.bottom - 8),
      );
      await tester.pump(const Duration(milliseconds: 650));
      expect(jumps, ['Z']);
      expect(
        find.byKey(const ValueKey('engine-app-letter-preview')),
        findsOneWidget,
      );
      await hold.moveTo(Offset(bounds.center.dx, bounds.top + 8));
      await tester.pump();
      expect(jumps, ['Z', 'A']);
      await hold.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('engine-app-letter-preview')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pointer cancellation never leaves a letter preview behind', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 34,
            height: 300,
            child: AppAlphabetRuler(letters: const ['A', 'Z'], onJump: (_) {}),
          ),
        ),
      ),
    );
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('engine-app-alphabet-ruler'))),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(
      find.byKey(const ValueKey('engine-app-letter-preview')),
      findsOneWidget,
    );
    await hold.cancel();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('engine-app-letter-preview')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'held index reaches unbuilt final group exactly without saving permissions',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var saves = 0;
      final apps = [
        for (var i = 0; i < 80; i++)
          {
            'name': 'Alpha $i',
            'package': 'test.alpha$i',
            'sortName': 'alpha${i.toString().padLeft(2, '0')}',
          },
        {'name': 'Beta', 'package': 'test.beta', 'sortName': 'beta'},
        {'name': 'Moon', 'package': 'test.moon', 'sortName': 'moon'},
        {'name': 'Zebra', 'package': 'test.zebra', 'sortName': 'zebra'},
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: EngineAppSelectionPage(
            apps: apps,
            selected: {'test.beta'},
            save: (value) async {
              saves++;
              return value;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Zebra'), findsNothing);
      final bounds = tester.getRect(
        find.byKey(const ValueKey('engine-app-alphabet-ruler')),
      );
      final hold = await tester.startGesture(
        Offset(bounds.center.dx, bounds.bottom - 8),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      expect(find.text('Zebra'), findsOneWidget);
      final groupTop = tester
          .getTopLeft(find.byKey(const ValueKey('engine-app-letter-Z')))
          .dy;
      final viewportTop = tester
          .getTopLeft(find.byKey(const ValueKey('engine-app-results')))
          .dy;
      expect((groupTop - viewportTop).abs(), lessThan(2));
      await hold.moveTo(Offset(bounds.center.dx, bounds.top + 8));
      await tester.pumpAndSettle();
      expect(find.text('Alpha 0'), findsOneWidget);
      await hold.up();
      await tester.pumpAndSettle();
      expect(saves, 0);
      await tester.enterText(
        find.byKey(const ValueKey('engine-app-search')),
        'Zebra',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('engine-app-alphabet-ruler')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('engine-app-test.zebra')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
