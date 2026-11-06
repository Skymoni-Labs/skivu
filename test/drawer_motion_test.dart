import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
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
  testWidgets(
    'all panes retain layout and mounting across repeated side changes',
    (tester) async {
      final motion = DrawerMotion(vsync: tester);
      final semantics = tester.ensureSemantics();
      final builds = [0, 0, 0], layouts = [0, 0, 0], taps = [0, 0, 0];
      Widget pane(int index) => Builder(
        builder: (_) {
          builds[index]++;
          return LayoutBuilder(
            builder: (_, _) {
              layouts[index]++;
              return Semantics(
                label: 'retained layer $index',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps[index]++,
                  child: SizedBox.expand(key: ValueKey('retained-pane-$index')),
                ),
              );
            },
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SlideDeck(
            motion: motion,
            left: pane(1),
            right: pane(2),
            child: pane(0),
          ),
        ),
      );
      final initialBuilds = List.of(builds), initialLayouts = List.of(layouts);
      expect(find.bySemanticsLabel('retained layer 1'), findsNothing);
      expect(find.bySemanticsLabel('retained layer 2'), findsNothing);
      await tester.tapAt(const Offset(100, 100));
      expect(taps, [1, 0, 0]);
      for (final side in [1, -1, 1, -1]) {
        motion.begin();
        for (var i = 0; i < 12; i++) {
          motion.dragBy(side * 8);
          await tester.pump(const Duration(milliseconds: 8));
        }
        motion.release(side * 800);
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel('retained layer ${side > 0 ? 1 : 2}'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('retained layer ${side > 0 ? 2 : 1}'),
          findsNothing,
        );
        await tester.tapAt(
          tester.getCenter(
            find.byKey(ValueKey('retained-pane-${side > 0 ? 1 : 2}')),
          ),
        );
        motion.close();
        await tester.pumpAndSettle();
        expect(builds, initialBuilds);
        expect(layouts, initialLayouts);
      }
      expect(taps, [1, 2, 2]);
      await tester.pumpWidget(const SizedBox());
      motion.dispose();
      semantics.dispose();
    },
  );

  testWidgets('contact shadows remain visible and mirror at both side seams', (
    tester,
  ) async {
    for (final left in [true, false]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 28,
                height: 90,
                child: ColoredBox(
                  color: Colors.white,
                  child: DrawerContactShadow(leftSide: left, progress: 1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final luminance = (await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          double pixel(int x) {
            final i = (45 * 28 + x) * 4;
            return Color.fromARGB(
              255,
              bytes.getUint8(i),
              bytes.getUint8(i + 1),
              bytes.getUint8(i + 2),
            ).computeLuminance();
          }

          return [pixel(left ? 2 : 25), pixel(left ? 27 : 0)];
        } finally {
          image.dispose();
        }
      }))!;
      expect(luminance[0], lessThan(.75));
      expect(luminance[1], greaterThan(.95));
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('drawer renderer handoff waits for drag, cancel and settle', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    expect(motion.isMoving, isFalse);
    motion.begin();
    expect(motion.isMoving, isTrue);
    motion.dragBy(60);
    motion.cancel();
    expect(motion.isMoving, isTrue);
    await tester.pumpAndSettle();
    expect(motion.isMoving, isFalse);
    motion.toggle(-1);
    expect(motion.isMoving, isTrue);
    await tester.pumpAndSettle();
    expect(motion.isMoving, isFalse);
    motion.close();
    await tester.pumpAndSettle();
    expect(motion.isMoving, isFalse);
    motion.dispose();
  });

  testWidgets('short slow drags open and close either panel symmetrically', (
    tester,
  ) async {
    final motion = DrawerMotion(vsync: tester);
    for (final side in [1, -1]) {
      motion.begin();
      motion.dragBy(side * 56);
      motion.release(0);
      await tester.pumpAndSettle();
      expect(motion.offset, side > 0 ? motion.leftExtent : -motion.rightExtent);
      motion.begin();
      motion.dragBy(-side * 56);
      motion.release(0);
      await tester.pumpAndSettle();
      expect(motion.offset, 0);
    }
    motion.dispose();
  });

  testWidgets(
    'small flicks work but tiny jitter and cancellation do not switch',
    (tester) async {
      final motion = DrawerMotion(vsync: tester);
      for (final side in [1, -1]) {
        motion.begin();
        motion.dragBy(side * 4);
        motion.release(side * 800);
        await tester.pumpAndSettle();
        expect(motion.offset, 0);
        motion.begin();
        motion.dragBy(side * 24);
        motion.release(side * 500);
        await tester.pumpAndSettle();
        final open = motion.offset;
        expect(open, side > 0 ? motion.leftExtent : -motion.rightExtent);
        motion.begin();
        motion.dragBy(-side * 80);
        motion.cancel();
        await tester.pumpAndSettle();
        expect(motion.offset, open);
        motion.close();
        await tester.pumpAndSettle();
      }
      motion.dispose();
    },
  );

  testWidgets(
    'plugin surfaces retain horizontal gestures while host drag opening is disabled',
    (tester) async {
      final motion = DrawerMotion(vsync: tester);
      var childDrags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlideDeck(
              motion: motion,
              dragEnabled: false,
              left: const ColoredBox(color: Colors.blue),
              right: const ColoredBox(color: Colors.purple),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (_) => childDrags++,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.dragFrom(const Offset(200, 250), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(childDrags, greaterThan(0));
      expect(motion.offset, 0);
      expect(motion.dragging, isFalse);
      motion.toggle(1);
      await tester.pumpAndSettle();
      expect(motion.offset, motion.leftExtent);
      motion.close();
      await tester.pumpAndSettle();
      expect(motion.offset, 0);
      await tester.pumpWidget(const SizedBox());
      motion.dispose();
    },
  );

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
            final fill = find.descendant(
              of: find.ancestor(
                of: content,
                matching: find.byType(SkiGlassPanel),
              ),
              matching: find.byKey(const ValueKey('side-sheet-fill')),
            );
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
    expect(find.byKey(const ValueKey('right')).hitTestable(), findsNothing);
    expect(tester.getSize(find.byType(BuildProbe)), size);
    // Retained planar layers keep baselines level and preserve 14% overlap.
    final page = find.byKey(const ValueKey('page-plane'));
    final pageLeft = tester.getTopLeft(page);
    final pageRight = tester.getTopRight(page);
    final sideLeft = tester.getTopLeft(find.byKey(const ValueKey('left')));
    final sideRight = tester.getTopRight(find.byKey(const ValueKey('left')));
    expect(pageLeft.dy, closeTo(pageRight.dy, .001));
    expect(sideRight.dy, closeTo(sideLeft.dy, .001));
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
      openSideTop.dx - tester.getTopLeft(page).dx,
      closeTo(motion.leftExtent * .14, .001),
    );
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
    expect(find.byKey(const ValueKey('left')).hitTestable(), findsNothing);
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
    expect(mirroredPageRight.dy, closeTo(mirroredPageLeft.dy, .001));
    expect(mirroredSideLeft.dy, closeTo(mirroredSideRight.dy, .001));
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
      tester.getTopRight(page).dx -
          tester.getTopLeft(find.byKey(const ValueKey('right'))).dx,
      closeTo(motion.rightExtent * .14, .001),
    );
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
