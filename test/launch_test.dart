import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/launch.dart';
import 'package:ski/scaled_viewport.dart';

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const LaunchReveal(
        part: LaunchPart.toolbar,
        radius: 36,
        child: SizedBox(height: 72, width: double.infinity),
      ),
      Expanded(
        child: LaunchReveal(
          part: LaunchPart.content,
          child: TextButton(
            onPressed: () => setState(() => taps++),
            child: Text('tap $taps'),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.all(10),
        child: LaunchReveal(
          part: LaunchPart.composer,
          radius: 24,
          child: SizedBox(height: 140, width: double.infinity),
        ),
      ),
    ],
  );
}

void main() {
  LaunchArtwork? artwork;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    artwork = await LaunchArtwork.load();
    expect(artwork, isNotNull);
  });
  tearDownAll(() => artwork?.mask.dispose());

  Widget app({bool reduce = false, double scale = 1, VoidCallback? done}) =>
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: ScaledViewport(
              scale: scale,
              child: LaunchHost(
                artwork: artwork!,
                accent: Colors.blue,
                dark: false,
                onComplete: done,
                child: const _Probe(),
              ),
            ),
          ),
        ),
      );
  final overlay = find.byKey(const ValueKey('skivu-launch-overlay'));
  testWidgets(
    'stacked routes use independent launch anchors after the cold-start sequence',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => LaunchHost(
            artwork: artwork!,
            accent: Colors.blue,
            dark: false,
            child: child!,
          ),
          home: const Scaffold(body: _Probe()),
        ),
      );
      final original = tester.state<_ProbeState>(find.byType(_Probe));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: _Probe())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.state<_ProbeState>(find.byType(_Probe)), same(original));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cold launch blocks taps, then keeps the real page state', (
    tester,
  ) async {
    int completions = 0;
    await tester.pumpWidget(app(done: () => completions++));
    final before = tester.state<_ProbeState>(find.byType(_Probe));
    expect(overlay, findsOneWidget);
    await tester.tap(find.text('tap 0'), warnIfMissed: false);
    expect(before.taps, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 2900));
    await tester.pump();
    expect(overlay, findsNothing);
    expect(tester.state(find.byType(_Probe)), same(before));
    expect(completions, 1);
    await tester.tap(find.text('tap 0'));
    await tester.pump();
    expect(before.taps, 1);
    await tester.pumpWidget(app(done: () => completions++));
    await tester.pump(const Duration(seconds: 1));
    expect(overlay, findsNothing);
    expect(completions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system reduced motion enters the page without the timed wait', (
    tester,
  ) async {
    int completions = 0;
    await tester.pumpWidget(app(reduce: true, done: () => completions++));
    await tester.pump();
    expect(overlay, findsNothing);
    expect(completions, 1);
    await tester.tap(find.text('tap 0'));
    await tester.pump();
    expect(find.text('tap 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving and returning during launch never replays the splash', (
    tester,
  ) async {
    int completions = 0;
    await tester.pumpWidget(app(done: () => completions++));
    await tester.pump(const Duration(milliseconds: 800));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(overlay, findsNothing);
    expect(completions, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(completions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real control anchors remain valid on a narrow scaled viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(scale: 1.2));
    for (final step in [900, 700, 500, 700]) {
      await tester.pump(Duration(milliseconds: step));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(overlay, findsNothing);
    expect(find.text('tap 0'), findsOneWidget);
  });
}
