import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat_backdrop.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/glass_preferences.dart';
import 'package:ski/glass.dart';
import 'package:ski/drawer_motion.dart';
import 'glass_preferences_test.dart' show MemoryGlassPreferences;

void main() {
  testWidgets('composer cover fades before the rim without a hard avatar cut', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = ChatBackdropController();
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: capture,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                key: source.backgroundKey,
                child: const ColoredBox(color: Color(0xff204080)),
              ),
              const Positioned(
                left: 0,
                right: 0,
                top: 420,
                height: 100,
                child: ColoredBox(color: Color(0xffff0000)),
              ),
              ChatBackdropScope(
                controller: source,
                child: const Align(
                  alignment: Alignment.bottomCenter,
                  child: ChatComposerBackdrop(
                    topInset: 6,
                    child: SizedBox(width: 320, height: 140),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => source.capture(revision: 'avatar-rim', enabled: true, radii: {}),
    );
    await tester.pumpAndSettle();
    final reds = (await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final y in [438, 450, 460, 470])
            bytes.getUint8((y * 320 + 30) * 4),
        ];
      } finally {
        image.dispose();
      }
    }))!;
    expect(reds.first, 255);
    expect(reds[1], inExclusiveRange(reds[2], reds.first));
    expect(reds[2], inExclusiveRange(reds.last, reds[1]));
    expect(reds.last, 32);
    await tester.pumpWidget(const SizedBox());
    source.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'unchanged cache token cannot reuse a differently sized capture',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = ChatBackdropController();
      final height = ValueNotifier<double>(600);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
              valueListenable: height,
              builder: (_, value, _) => SizedBox(
                width: 320,
                height: value,
                child: RepaintBoundary(
                  key: source.backgroundKey,
                  child: const CustomPaint(painter: _Wallpaper()),
                ),
              ),
            ),
          ),
        ),
      );
      for (final value in [600.0, 340.0, 600.0]) {
        height.value = value;
        await tester.pump();
        await tester.runAsync(
          () => source.capture(
            revision: 'constant-release-token',
            enabled: true,
            radii: {},
          ),
        );
        expect(source.logicalSize, Size(320, value));
        expect(source.wallpaperImage!.height, (value * 1.5).round());
      }
      await tester.pumpWidget(const SizedBox());
      source.dispose();
      height.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('scene recaptures body resize with unchanged MediaQuery', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final motion = DrawerMotion(vsync: tester);
    final height = ValueNotifier<double>(600);
    ChatBackdropController? source;
    final oldUser = glassPreferences.userBlur;
    final oldAssistant = glassPreferences.assistantBlur;
    glassPreferences.setBubbleBlur(user: true, value: 0);
    glassPreferences.setBubbleBlur(user: false, value: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder<double>(
            valueListenable: height,
            builder: (_, value, _) => SizedBox(
              width: 320,
              height: value,
              child: SkiGlassScene(
                motion: motion,
                child: Builder(
                  builder: (context) {
                    source = ChatBackdropScope.maybeOf(context);
                    expect(MediaQuery.sizeOf(context), const Size(320, 600));
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (final value in [600.0, 340.0, 420.0, 600.0]) {
      height.value = value;
      await tester.pump();
      for (var n = 0; n < 20 && source?.logicalSize != Size(320, value); n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(source?.logicalSize, Size(320, value));
      expect(source?.wallpaperImage?.height, (value * 1.5).round());
    }
    await tester.pumpWidget(const SizedBox());
    motion.dispose();
    height.dispose();
    glassPreferences.setBubbleBlur(user: true, value: oldUser);
    glassPreferences.setBubbleBlur(user: false, value: oldAssistant);
    expect(tester.takeException(), isNull);
  });
  testWidgets('wallpaper frost stays aligned and blurred while text scrolls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final old = appearance.values;
    appearance.set('assistantOpacity', .38);
    appearance.set('customMessageColors', false);
    addTearDown(() {
      for (final entry in old.entries) {
        appearance.set(entry.key, entry.value);
      }
    });
    final source = ChatBackdropController();
    final capture = GlobalKey();
    final scroll = ScrollController();
    final model = GlassPreferences(persistence: MemoryGlassPreferences());
    model.setBubbleBlur(user: false, value: 12);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: capture,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                key: source.backgroundKey,
                child: const CustomPaint(painter: _Wallpaper()),
              ),
              ChatBackdropScope(
                controller: source,
                child: ListView(
                  controller: scroll,
                  addRepaintBoundaries: false,
                  padding: const EdgeInsets.all(20),
                  children: [
                    ChatBubbleSurface(
                      user: false,
                      preferences: model,
                      child: const SizedBox(height: 1800),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => source.capture(revision: 'wallpaper-a', enabled: true, radii: {12}),
    );
    await tester.pump();
    expect(source.imageFor(12), isNotNull);
    expect(find.byType(ChatBackdropPaint), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    Future<List<int>> pixels() async => (await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (var x = 120; x < 192; x++) bytes.getUint8((260 * 320 + x) * 4),
        ];
      } finally {
        image.dispose();
      }
    }))!;
    final before = await pixels();
    expect(
      before.reduce((a, b) => a > b ? a : b) -
          before.reduce((a, b) => a < b ? a : b),
      lessThan(8),
    );
    final drag = await tester.startGesture(const Offset(240, 450));
    for (var i = 0; i < 4; i++) {
      await drag.moveBy(const Offset(0, -55));
      await tester.pump(const Duration(milliseconds: 16));
      expect(await pixels(), before);
    }
    await drag.up();
    await tester.pumpAndSettle();
    for (final offset in [700.0, 1150.0, 0.0]) {
      scroll.jumpTo(offset);
      await tester.pump();
      expect(await pixels(), before);
    }
    await source.capture(revision: 'video', enabled: false, radii: {12});
    await tester.pump();
    expect(source.imageFor(12), isNull);
    expect(find.byType(ChatBackdropPaint), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    source.dispose();
    scroll.dispose();
    model.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets('composer optics and rim sample only the static wallpaper', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = ChatBackdropController();
    final capture = GlobalKey();
    final underneath = ValueNotifier<Color>(Colors.red);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: capture,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                key: source.backgroundKey,
                child: const CustomPaint(painter: _Wallpaper()),
              ),
              ChatBackdropScope(
                controller: source,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ValueListenableBuilder<Color>(
                    valueListenable: underneath,
                    builder: (_, color, _) => ColoredBox(
                      color: color,
                      child: const ChatComposerBackdrop(
                        child: ConfigurableGlassSurface(
                          area: 'inputBlur',
                          child: SizedBox(width: 320, height: 140),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LiquidGlassLens>(find.byType(LiquidGlassLens))
          .useImpellerBackdrop,
      isNull,
    );
    await tester.runAsync(
      () => source.capture(revision: 'composer', enabled: true, radii: {}),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('composer-wallpaper-plane')),
      findsOneWidget,
    );
    // Covering the lens body alone cannot keep live refraction from reading
    // UI outside the rim. The input must also opt into wallpaper-only optics.
    expect(
      tester
          .widget<LiquidGlassLens>(find.byType(LiquidGlassLens))
          .useImpellerBackdrop,
      isFalse,
    );
    Future<List<int>> sample() async => (await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final y in [470, 480, 520, 575])
            for (final x in [12, 25, 75, 160, 295, 307])
              for (var c = 0; c < 3; c++) bytes.getUint8((y * 320 + x) * 4 + c),
        ];
      } finally {
        image.dispose();
      }
    }))!;
    final before = await sample();
    underneath.value = Colors.blue;
    await tester.pumpAndSettle();
    expect(await sample(), before);
    await source.capture(revision: 'video', enabled: false, radii: {});
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LiquidGlassLens>(find.byType(LiquidGlassLens))
          .useImpellerBackdrop,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    source.dispose();
    underneath.dispose();
    expect(tester.takeException(), isNull);
  });
}

class _Wallpaper extends CustomPainter {
  const _Wallpaper();
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 6) {
      for (var y = 0.0; y < size.height; y += 100) {
        final level = (x ~/ 6).isEven ? 32 : 224;
        canvas.drawRect(
          Rect.fromLTWH(x, y, 6, 100),
          Paint()
            ..color = Color.fromARGB(
              255,
              (y ~/ 100).isEven ? level : level ~/ 2,
              level,
              level,
            ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Wallpaper oldDelegate) => false;
}
