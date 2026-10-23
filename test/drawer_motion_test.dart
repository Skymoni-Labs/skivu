import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/drawer_motion.dart';
import 'package:ski/glass.dart';

class BuildProbe extends StatelessWidget {
  const BuildProbe(this.onBuild, {super.key});
  final VoidCallback onBuild;
  @override
  Widget build(BuildContext context) {
    onBuild();
    return const ColoredBox(color: Colors.white, child: SizedBox.expand());
  }
}

void main() {
  testWidgets('opening has a small bounded recoil mirrored on both sides', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: SkiGlassScene(
              motion: motion,
              child: SlideDeck(
                motion: motion,
                left: const SkiGlassPanel(
                  child: SizedBox.expand(key: ValueKey('left-content')),
                ),
                right: const SkiGlassPanel(
                  leftSide: false,
                  child: SizedBox.expand(key: ValueKey('right-content')),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    for (final side in [1, -1]) {
      motion.toggle(side);
      await tester.pump();
      var peak = 0.0;
      var peakEdge = 0.0;
      final extent = side > 0 ? motion.leftExtent : motion.rightExtent;
      final content = find.byKey(
        ValueKey(side > 0 ? 'left-content' : 'right-content'),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 4));
        if (motion.offset.abs() > peak) {
          peak = motion.offset.abs();
          peakEdge = tester.getTopLeft(content).dx;
          if (peak > extent) {
            final fill = find.byKey(const ValueKey('side-sheet-fill'));
            final viewport = tester.getRect(find.byType(SlideDeck));
            // Glass still covers the outer edge while sheet and shadow move.
            if (side > 0) {
              expect(tester.getTopLeft(fill).dx, lessThan(viewport.left));
              expect(tester.getBottomLeft(fill).dx, lessThan(viewport.left));
              expect(
                tester.getTopRight(fill).dx,
                closeTo(tester.getTopRight(content).dx, .001),
              );
            } else {
              expect(tester.getTopRight(fill).dx, greaterThan(viewport.right));
              expect(
                tester.getBottomRight(fill).dx,
                greaterThan(viewport.right),
              );
              expect(
                tester.getTopLeft(fill).dx,
                closeTo(tester.getTopLeft(content).dx, .001),
              );
            }
          }
        }
      }
      expect(peak, greaterThan(extent + 8));
      expect(peak, lessThanOrEqualTo(extent + DrawerMotion.maxSettleOvershoot));
      expect(motion.offset, side * extent);
      // The actual side content follows the recoil, rather than staying pinned.
      expect(
        (peakEdge - tester.getTopLeft(content).dx) * side,
        closeTo(peak - extent, .001),
      );
      motion.close();
      await tester.pumpAndSettle();
      expect(motion.offset, 0);
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    motion.dispose();
  });
  testWidgets('a fast release retains momentum and a recoil can be caught', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    for (final side in [1, -1]) {
      final extent = side > 0 ? motion.leftExtent : motion.rightExtent;
      motion.begin();
      motion.dragBy(side * (extent - 20));
      motion.release(side * 1800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // A flick near the end keeps useful speed instead of starting a slow tail.
      expect(motion.offset.abs(), greaterThan(extent - 12));
      var caught = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 4));
        expect(
          motion.offset.abs(),
          lessThanOrEqualTo(extent + DrawerMotion.maxSettleOvershoot),
        );
        if (motion.offset.abs() > extent + 1) {
          final current = motion.offset;
          motion.begin();
          motion.dragBy(-side * .5);
          expect(motion.offset, closeTo(current - side * .5, .001));
          await tester.pump(const Duration(milliseconds: 100));
          expect(motion.offset, closeTo(current - side * .5, .001));
          caught = true;
          break;
        }
      }
      expect(caught, isTrue);
      motion.close();
      await tester.pumpAndSettle();
      expect(motion.offset, 0);
    }
    motion.dispose();
  });
  testWidgets('settling never kicks away from its selected destination', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    motion.begin();
    motion.dragBy(40);
    // This short slow release chooses closed, despite residual outward speed.
    motion.release(180);
    await tester.pump();
    var last = motion.offset;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(motion.offset, lessThanOrEqualTo(last));
      last = motion.offset;
    }
    expect(motion.offset, 0);

    motion.begin();
    motion.dragBy(-40);
    motion.release(-180);
    await tester.pump();
    last = motion.offset;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(motion.offset, greaterThanOrEqualTo(last));
      last = motion.offset;
    }
    expect(motion.offset, 0);
    motion.dispose();
  });
  testWidgets('drag and spring compose without rebuilding or resizing content', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    int builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: SlideDeck(
              motion: motion,
              left: const ColoredBox(key: ValueKey('left'), color: Colors.blue),
              right: const ColoredBox(
                key: ValueKey('right'),
                color: Colors.purple,
              ),
              child: BuildProbe(() => builds++),
            ),
          ),
        ),
      ),
    );
    final initialBuilds = builds;
    final size = tester.getSize(find.byType(BuildProbe));
    motion.begin();
    motion.dragBy(140);
    await tester.pump();
    expect(find.byKey(const ValueKey('left')), findsOneWidget);
    expect(find.byKey(const ValueKey('right')), findsNothing);
    expect(tester.getSize(find.byType(BuildProbe)), size);
    // Both inner edges recede slightly, with translucent overlap at the seam.
    final page = find.byKey(const ValueKey('page-plane'));
    final pageLeft = tester.getTopLeft(page);
    final pageRight = tester.getTopRight(page);
    final sideLeft = tester.getTopLeft(find.byKey(const ValueKey('left')));
    final sideRight = tester.getTopRight(find.byKey(const ValueKey('left')));
    expect(pageLeft.dy, greaterThan(pageRight.dy + 1));
    expect(sideRight.dy, greaterThan(sideLeft.dy + 1));
    expect(sideRight.dy, closeTo(pageLeft.dy, .001));
    expect(sideRight.dx - pageLeft.dx, closeTo(140 * .14, .001));
    // Motion preserves the original content scale and its sheet alignment.
    expect(tester.getTopLeft(find.byType(BuildProbe)), pageLeft);
    expect(tester.getTopRight(find.byType(BuildProbe)), pageRight);
    expect(builds, initialBuilds);
    motion.release(800);
    for (int i = 0; i < 12; i++)
      await tester.pump(const Duration(milliseconds: 16));
    expect(builds, initialBuilds);
    await tester.pumpAndSettle();
    final openSideTop = tester.getTopRight(find.byKey(const ValueKey('left')));
    expect(
      openSideTop.dy,
      closeTo(tester.getTopLeft(find.byKey(const ValueKey('left'))).dy, .001),
    );
    expect(
      tester.getTopLeft(page).dy,
      closeTo(tester.getTopRight(page).dy, .001),
    );
    final openSideBottom = tester.getBottomRight(
      find.byKey(const ValueKey('left')),
    );
    expect(openSideTop.dy - sideLeft.dy, lessThan(12));
    expect(size.height - openSideBottom.dy, lessThan(12));
    motion.close();
    await tester.pump(const Duration(milliseconds: 80));
    // The panel is kept during closing instead of vanishing at the target change.
    expect(find.byKey(const ValueKey('left')), findsOneWidget);
    final interrupted = motion.offset;
    motion.begin();
    expect(motion.offset, interrupted);
    motion.dragBy(-25);
    expect(motion.offset, closeTo(interrupted - 25, .001));
    await tester.pump();
    expect(builds, initialBuilds);
    motion.cancel();
    await tester.pumpAndSettle();
    expect(motion.offset, 0);
    expect(find.byKey(const ValueKey('left')), findsNothing);
    motion.begin();
    motion.dragBy(-160);
    await tester.pump();
    final mirroredPageLeft = tester.getTopLeft(page);
    final mirroredPageRight = tester.getTopRight(page);
    final mirroredSideLeft = tester.getTopLeft(
      find.byKey(const ValueKey('right')),
    );
    final mirroredSideRight = tester.getTopRight(
      find.byKey(const ValueKey('right')),
    );
    expect(mirroredPageRight.dy, greaterThan(mirroredPageLeft.dy + 1));
    expect(mirroredSideLeft.dy, greaterThan(mirroredSideRight.dy + 1));
    expect(mirroredSideLeft.dy, closeTo(mirroredPageRight.dy, .001));
    expect(
      mirroredPageRight.dx - mirroredSideLeft.dx,
      closeTo(160 * .14, .001),
    );
    expect(tester.getSize(find.byType(BuildProbe)), size);
    expect(builds, initialBuilds);
    motion.cancel();
    await tester.pumpAndSettle();
    motion.toggle(-1);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('right'))).dy,
      closeTo(tester.getTopRight(find.byKey(const ValueKey('right'))).dy, .001),
    );
    motion.close();
    await tester.pumpAndSettle();
    motion.configure(330, 350, reduced: true);
    motion.toggle(1);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(BuildProbe)), tester.getTopLeft(page));
    expect(motion.offset, 330);
    await tester.pumpWidget(const SizedBox());
    motion.dispose();
  });

  testWidgets('a new drag takes ownership of an unfinished spring', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    motion.toggle(1);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 80));
    final rendered = motion.offset;
    expect(rendered, greaterThan(0));
    expect(rendered, lessThan(330));
    motion.begin();
    motion.dragBy(-30);
    expect(motion.offset, closeTo(rendered - 30, .001));
    await tester.pump(const Duration(milliseconds: 300));
    expect(motion.offset, closeTo(rendered - 30, .001));
    motion.release(-1400);
    await tester.pumpAndSettle();
    expect(motion.offset, 0);
    motion.dispose();
  });
}
