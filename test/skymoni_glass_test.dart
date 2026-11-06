import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:ski/skymoni_glass.dart';
import 'package:ski/appearance.dart';
import 'package:ski/drawer_motion.dart';
import 'appearance_test.dart' show MemoryAppearance;

void main() {
  testWidgets('glass shadow stays outside and never shades its own backdrop', (
    tester,
  ) async {
    final capture = GlobalKey();
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 220,
                height: 160,
                child: ColoredBox(
                  color: Colors.white,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 40,
                        top: 40,
                        width: 140,
                        height: 80,
                        child: SkymoniGlassFrame(
                          radius: 24,
                          dark: dark,
                          kind: SkymoniGlassKind.navigation,
                          optics: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                            child: const SizedBox.expand(),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final pixels = (await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int red(int x, int y) => bytes.getUint8((y * 220 + x) * 4);
          return [red(110, 80), red(110, 105), red(110, 128)];
        } finally {
          image.dispose();
        }
      }))!;
      expect(
        pixels[0],
        255,
        reason: 'transparent lens must not sample an interior shadow',
      );
      expect(
        pixels[1],
        inInclusiveRange(254, 255),
        reason: 'allow one channel rounding step at the filtered edge',
      );
      expect(
        pixels[2],
        lessThan(255),
        reason: 'outside contact shadow remains visible',
      );
      expect(pixels[2], greaterThan(220));
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'one optical frame and foreground stay mounted through both drawers',
    (tester) async {
      final motion = DrawerMotion(vsync: tester);
      var opticalBuilds = 0, foregroundBuilds = 0;
      final optics = Builder(
        builder: (context) {
          opticalBuilds++;
          return const Text('single optical layer');
        },
      );
      final foreground = Builder(
        builder: (_) {
          foregroundBuilds++;
          return const Text('retained foreground');
        },
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SkymoniGlassMotionScope(
            motion: motion,
            child: SkymoniGlassFrame(
              radius: 24,
              dark: false,
              kind: SkymoniGlassKind.navigation,
              optics: optics,
              child: foreground,
            ),
          ),
        ),
      );
      expect(find.text('single optical layer'), findsOneWidget);
      for (final side in [1, -1]) {
        motion.toggle(side);
        await tester.pump();
        expect(find.text('single optical layer'), findsOneWidget);
        expect(find.text('retained foreground'), findsOneWidget);
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
        expect(motion.isMoving, isFalse);
        expect(find.text('single optical layer'), findsOneWidget);
        motion.close();
        await tester.pumpAndSettle();
        expect(find.text('single optical layer'), findsOneWidget);
        expect(find.text('retained foreground'), findsOneWidget);
        expect(opticalBuilds, 1);
        expect(foregroundBuilds, 1);
        expect(find.byType(PlatformViewLink), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      motion.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'drawer ticks do not rebuild glass-dependent foreground content',
    (tester) async {
      final motion = ValueNotifier(0);
      final replacement = ValueNotifier(0);
      var builds = 0;
      final content = Builder(
        builder: (context) {
          context.dependOnInheritedWidgetOfExactType<SkymoniGlassMotionScope>();
          builds++;
          return const SizedBox();
        },
      );
      Widget scene(ChangeNotifier source) =>
          SkymoniGlassMotionScope(motion: source, child: content);
      await tester.pumpWidget(scene(motion));
      expect(builds, 1);
      for (var frame = 1; frame <= 20; frame++) {
        motion.value = frame;
        await tester.pump();
      }
      expect(builds, 1);
      await tester.pumpWidget(scene(replacement));
      expect(builds, 2);
      await tester.pumpWidget(const SizedBox());
      motion.dispose();
      replacement.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Skymoni overlay retains the backdrop without a solid readability coating',
    (tester) async {
      final key = GlobalKey();
      for (final dark in [false, true]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: ColoredBox(
                    color: dark ? Colors.white : Colors.black,
                    child: SkymoniGlassCoating(
                      dark: dark,
                      radius: 20,
                      kind: SkymoniGlassKind.readable,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final pixel = (await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final i = (50 * 100 + 50) * 4;
            return Color.fromARGB(
              255,
              bytes.getUint8(i),
              bytes.getUint8(i + 1),
              bytes.getUint8(i + 2),
            );
          } finally {
            image.dispose();
          }
        }))!;
        expect(
          pixel.computeLuminance(),
          dark ? greaterThan(.90) : lessThan(.02),
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'separate Skymoni toggle persists without replacing original material settings',
    () async {
      final disk = MemoryAppearance();
      final preferences = AppearancePreferences(persistence: disk);
      preferences.set('glass', false);
      preferences.set('inputBlur', 17.0);
      preferences.set('inputOpacity', .37);
      preferences.set('accent', 0xff447799);
      final original = Map.of(preferences.values);
      preferences.set('skymoniGlass', true);
      await preferences.save();
      final restored = AppearancePreferences(persistence: disk);
      await restored.restore();
      expect(restored.flag('skymoniGlass'), isTrue);
      expect(restored.flag('glass'), isFalse);
      restored.set('skymoniGlass', false);
      expect(restored.values, original);
      await restored.save();
      preferences.dispose();
      restored.dispose();
    },
  );
}
