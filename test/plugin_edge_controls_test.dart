import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/plugin_edge_controls.dart';

Future<void> open(
  WidgetTester tester, {
  Widget? child,
  Future<bool> Function()? onExit,
  Future<void> Function(String, List<int>?)? report,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PluginEdgeControls(
          reduceMotion: true,
          onExit: onExit ?? () async => true,
          reportEdge: report ?? (_, __) async {},
          child: child ?? const ColoredBox(color: Colors.white),
        ),
      ),
    ),
  );
  await tester.pump();
}

bool visible(WidgetTester tester) =>
    tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('plugin-control-rail')),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity ==
    1;

void main() {
  testWidgets(
    'quiet surface is invisible; vertical and diagonal edge scrolling still reaches content',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await open(
        tester,
        child: ListView(
          controller: scroll,
          children: List.generate(
            100,
            (i) => SizedBox(height: 50, child: Text('消息 $i')),
          ),
        ),
      );
      expect(visible(tester), isFalse);
      await tester.dragFrom(const Offset(390, 500), const Offset(-30, -180));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(visible(tester), isFalse);
      await tester.dragFrom(const Offset(200, 400), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(visible(tester), isFalse);
    },
  );
  testWidgets(
    'only a deliberate inward middle-edge pull reveals the vertical controls',
    (tester) async {
      await open(tester);
      await tester.dragFrom(const Offset(390, 100), const Offset(-100, 0));
      await tester.pump();
      expect(visible(tester), isFalse);
      await tester.dragFrom(const Offset(390, 400), const Offset(-20, 0));
      await tester.pump();
      expect(visible(tester), isFalse);
      await tester.dragFrom(const Offset(390, 400), const Offset(-90, 0));
      await tester.pumpAndSettle();
      expect(visible(tester), isTrue);
      expect(find.text('返回\n原版').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('收起界面控制'));
      await tester.pumpAndSettle();
      expect(visible(tester), isFalse);
    },
  );
  testWidgets(
    'idle controls hide automatically and an outside tap still reaches the page',
    (tester) async {
      var taps = 0;
      await open(
        tester,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      );
      await tester.dragFrom(const Offset(390, 400), const Offset(-90, 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(visible(tester), isFalse);
      await tester.dragFrom(const Offset(390, 400), const Offset(-90, 0));
      await tester.pump();
      await tester.tapAt(const Offset(200, 400));
      await tester.pump();
      expect(visible(tester), isFalse);
      expect(taps, 1);
    },
  );
  testWidgets(
    'return action is explicit and repeated taps cannot trigger duplicate exits',
    (tester) async {
      var exits = 0;
      await open(
        tester,
        onExit: () async {
          exits++;
          return true;
        },
      );
      await tester.dragFrom(const Offset(390, 400), const Offset(-90, 0));
      await tester.pump();
      await tester.tap(find.text('返回\n原版'));
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(visible(tester), isFalse);
    },
  );
  testWidgets(
    'gesture reservation follows keyboard bounds and is released on disposal',
    (tester) async {
      final reports = <List<int>?>[];
      await open(
        tester,
        report: (_, rect) async {
          reports.add(rect);
        },
      );
      expect(reports.last, [376, 328, 400, 472]);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(reports.last, [376, 178, 400, 322]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(reports.last, isNull);
    },
  );
}
