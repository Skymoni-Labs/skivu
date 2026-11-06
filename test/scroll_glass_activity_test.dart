import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/drawer_motion.dart';
import 'package:ski/glass.dart';
import 'package:ski/scroll_glass_activity.dart';
import 'package:ski/skymoni_glass.dart';

void main() {
  testWidgets(
    'overlapping sources and short pauses notify only activity edges',
    (tester) async {
      final activity = ScrollGlassActivity();
      final touch = Object(), ballistic = Object();
      var notifications = 0;
      activity.addListener(() => notifications++);
      activity.begin(touch);
      for (var i = 0; i < 30; i++) activity.begin(touch);
      activity.begin(ballistic);
      activity.end(touch);
      await tester.pump(const Duration(milliseconds: 200));
      expect(activity.busy, isTrue);
      expect(notifications, 1);
      activity.end(ballistic);
      await tester.pump(const Duration(milliseconds: 80));
      expect(activity.busy, isTrue);
      activity.begin(touch);
      await tester.pump(const Duration(milliseconds: 80));
      expect(activity.busy, isTrue);
      activity.end(touch);
      await tester.pump(const Duration(milliseconds: 301));
      expect(activity.busy, isFalse);
      expect(notifications, 2);
      activity.dispose();
    },
  );

  testWidgets(
    'touch and mouse taps, holds and small jitter never change glass',
    (tester) async {
      final activity = ScrollGlassActivity();
      final scroll = ScrollController();
      var builds = 0;
      var activityChanges = 0;
      activity.addListener(() => activityChanges++);
      await tester.pumpWidget(
        MaterialApp(
          home: ScrollGlassScope(
            activity: activity,
            child: ScrollGlassSurface(
              child: Builder(
                builder: (context) {
                  ScrollGlassScope.maybeOf(context);
                  builds++;
                  return ListView.builder(
                    controller: scroll,
                    itemExtent: 100,
                    itemCount: 20,
                    itemBuilder: (_, index) => Text('item $index'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        final touch = await tester.startGesture(
          const Offset(200, 200),
          kind: kind,
        );
        expect(activity.busy, isFalse);
        await tester.pump(const Duration(milliseconds: 500));
        expect(activity.busy, isFalse);
        await touch.moveBy(const Offset(2, 5));
        await tester.pump();
        expect(scroll.offset, 0);
        expect(activity.busy, isFalse);
        await touch.up();
        await tester.pump(const Duration(milliseconds: 350));
        expect(activity.busy, isFalse);
      }
      expect(builds, 1);
      expect(activityChanges, 0);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      activity.dispose();
    },
  );

  testWidgets(
    'unmount during a drag releases activity without waiting for scroll end',
    (tester) async {
      final activity = ScrollGlassActivity();
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: ScrollGlassScope(
            activity: activity,
            child: ScrollGlassSurface(
              child: ListView.builder(
                controller: scroll,
                itemExtent: 100,
                itemCount: 30,
                itemBuilder: (_, index) => Text('item $index'),
              ),
            ),
          ),
        ),
      );
      final touch = await tester.startGesture(const Offset(200, 200));
      await touch.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      await touch.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.offset, greaterThan(0));
      expect(activity.busy, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 301));
      expect(activity.busy, isFalse);
      await touch.cancel();
      scroll.dispose();
      activity.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scene keeps the same optical layer through tap, scroll and ballistic end',
    (tester) async {
      final drawer = DrawerMotion(vsync: tester);
      final scroll = ScrollController();
      var opticalBuilds = 0, foregroundBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SkiGlassScene(
            motion: drawer,
            child: Stack(
              children: [
                ScrollGlassSurface(
                  child: ListView.builder(
                    controller: scroll,
                    itemExtent: 100,
                    itemCount: 150,
                    itemBuilder: (_, i) => Text('message $i'),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: 80,
                  height: 40,
                  child: SkymoniGlassFrame(
                    radius: 20,
                    dark: false,
                    kind: SkymoniGlassKind.navigation,
                    optics: Builder(
                      builder: (_) {
                        opticalBuilds++;
                        return const Text('single optics');
                      },
                    ),
                    child: Builder(
                      builder: (_) {
                        foregroundBuilds++;
                        return const Text('foreground');
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('single optics'), findsOneWidget);
      final idleTouch = await tester.startGesture(const Offset(200, 200));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('single optics'), findsOneWidget);
      expect(find.text('foreground'), findsOneWidget);
      await idleTouch.moveBy(const Offset(0, 5));
      await tester.pump();
      expect(find.text('single optics'), findsOneWidget);
      await idleTouch.up();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('single optics'), findsOneWidget);
      await tester.fling(find.byType(ListView), const Offset(0, -300), 1600);
      await tester.pump(const Duration(milliseconds: 32));
      expect(scroll.position.isScrollingNotifier.value, isTrue);
      expect(find.text('single optics'), findsOneWidget);
      expect(find.text('foreground'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(300));
      await tester.pump(const Duration(milliseconds: 301));
      expect(find.text('single optics'), findsOneWidget);
      expect(opticalBuilds, 1);
      expect(foregroundBuilds, 1);
      expect(find.byType(PlatformViewLink), findsNothing);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      drawer.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('edge drag without displacement does not enter shadow material', (
    tester,
  ) async {
    final activity = ScrollGlassActivity();
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ScrollGlassScope(
          activity: activity,
          child: ScrollGlassSurface(
            child: ListView.builder(
              controller: scroll,
              itemExtent: 100,
              itemCount: 20,
              itemBuilder: (_, i) => Text('item $i'),
            ),
          ),
        ),
      ),
    );
    final drag = await tester.startGesture(const Offset(200, 300));
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(scroll.offset, 0);
    expect(activity.busy, isFalse);
    await drag.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(activity.busy, isTrue);
    await drag.cancel();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    expect(activity.busy, isFalse);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    activity.dispose();
  });
}
