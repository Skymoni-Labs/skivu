import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/update_sky.dart';

Future<void> openSky(
  WidgetTester tester, {
  bool enabled = true,
  bool motion = true,
  bool tickers = true,
  GlobalKey<NavigatorState>? navigator,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: !motion),
        child: TickerMode(
          enabled: tickers,
          child: UpdateMeteors(enabled: enabled),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}

void main() {
  testWidgets(
    'a short meteor flight has no frame ticker during its long rests',
    (tester) async {
      await openSky(tester);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 7900));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 23));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'backgrounding cancels a flight and resumes with a fresh quiet period',
    (tester) async {
      await openSky(tester);
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(minutes: 1));
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 7900));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    },
  );

  for (final policy in ['disabled', 'reduced motion', 'hidden ticker mode']) {
    testWidgets('$policy leaves the sky still even after a minute', (
      tester,
    ) async {
      await openSky(
        tester,
        enabled: policy != 'disabled',
        motion: policy != 'reduced motion',
        tickers: policy != 'hidden ticker mode',
      );
      await tester.pump(const Duration(minutes: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('covering the update route stops its meteor timer', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await openSky(tester, navigator: navigator);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other page')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 1));
    expect(tester.binding.transientCallbackCount, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 8));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('turning the preference off cancels an active flight', (
    tester,
  ) async {
    final enabled = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) => UpdateMeteors(enabled: value),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    enabled.value = false;
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    enabled.dispose();
  });
}
