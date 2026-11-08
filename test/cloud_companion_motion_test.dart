import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_portrait.dart';
import 'package:ski/cloud_companion_painter.dart';

Future<void> decoded(WidgetTester tester) async {
  for (
    var i = 0;
    i < 300 && find.byIcon(Icons.cloud_outlined).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(find.byIcon(Icons.cloud_outlined), findsNothing);
}

void main() {
  testWidgets(
    'entering and leaving the laptop never draws two character poses at once',
    (tester) async {
      Future<void> show(CloudActivity activity) => tester.pumpWidget(
        MaterialApp(home: CloudCompanionPortrait(activity: activity)),
      );
      CloudCompanionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CloudCompanionPainter>()
          .single;
      await show(CloudActivity.idle);
      await decoded(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await show(CloudActivity.coding);
      for (var i = 0; i < 75; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(painter().layers!.length, lessThanOrEqualTo(1));
      }
      await show(CloudActivity.thinking);
      for (var i = 0; i < 75; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(painter().layers!.length, lessThanOrEqualTo(1));
      }
      expect(painter().activity, CloudActivity.thinking);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'parent updates do not restart a finite action; pause keeps the visible pose',
    (tester) async {
      Future<void> show({bool active = true}) => tester.pumpWidget(
        MaterialApp(
          home: CloudCompanionPortrait(
            activity: CloudActivity.resultReady,
            active: active,
          ),
        ),
      );
      CloudCompanionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CloudCompanionPainter>()
          .single;
      await show();
      await decoded(tester);
      await tester.pump(const Duration(milliseconds: 200));
      final start = painter().seconds;
      for (var i = 0; i < 20; i++) {
        await show();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(painter().seconds - start, closeTo(2, .02));
      final before = painter().layers!.last.seconds;
      await show(active: false);
      await tester.pump(const Duration(seconds: 3));
      expect(painter().layers!.last.seconds, before);
      expect(painter().layers!.last.freezeMotion, true);
      expect(painter().motion, false);
      expect(tester.binding.transientCallbackCount, 0);
      await show();
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter().seconds, closeTo(before + .1, .03));
      await tester.pump(const Duration(seconds: 7));
      expect(
        painter().petCatalog!.packs[CloudActivity.resultReady]!
            .sample(painter().seconds)
            .segment,
        CloudPetSegment.hold,
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'all workflow phases use whole scenes and bounded atlas retention',
    (tester) async {
      Future<void> show(CloudActivity activity) => tester.pumpWidget(
        MaterialApp(home: CloudCompanionPortrait(activity: activity)),
      );
      CloudCompanionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<CloudCompanionPainter>()
          .single;
      await show(CloudActivity.idle);
      await decoded(tester);
      expect(painter().petCatalog, isNotNull);
      for (final activity in CloudActivity.values) {
        await show(activity);
        final pack = painter().petCatalog!.packs[activity]!;
        for (
          var i = 0;
          i < 200 && !painter().petAtlases.containsKey(pack.atlas);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 800));
        expect(painter().activity, activity);
        expect(
          painter().petAtlases.containsKey(pack.atlas),
          true,
          reason: '${activity.name} must load its own complete animation',
        );
        expect(pack.supports(activity, painter().pose), true);
        final fields = painter().petCatalog!.packs.values
            .map((p) => p.flow?.atlas)
            .toSet();
        expect(
          painter().petAtlases.keys
              .where((path) => !fields.contains(path))
              .length,
          lessThanOrEqualTo(4),
        );
        expect(painter().petAtlases.length, lessThanOrEqualTo(8));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('whole-scene playback matches the exact source frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CloudCompanionPortrait(activity: CloudActivity.coding),
      ),
    );
    await decoded(tester);
    final loaded = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<CloudCompanionPainter>()
        .single;
    final pack = loaded.petPack!;
    expect(pack.wholeFrames, true);
    const size = Size(300, 330);
    Future<Uint8List> capture(
      double seconds, {
      required bool sourceOnly,
    }) async {
      return (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        if (sourceOnly) {
          final frame = pack.sample(seconds).frame;
          final fit = applyBoxFit(BoxFit.contain, pack.tileSize, size);
          final destination = Alignment.center.inscribe(
            fit.destination,
            Offset.zero & size,
          );
          canvas.translate(destination.left, destination.top);
          canvas.scale(destination.width / pack.tileSize.width);
          final registration = pack.frameTransform(frame);
          canvas.translate(registration.offset.dx, registration.offset.dy);
          canvas.scale(registration.scale);
          canvas.drawImageRect(
            loaded.petAtlas!,
            (Offset.zero & pack.tileSize).shift(pack.frameOrigin(frame)),
            Offset.zero & pack.tileSize,
            Paint()..filterQuality = FilterQuality.high,
          );
        } else {
          CloudCompanionPainter(
            image: loaded.image,
            rig: loaded.rig,
            pose: loaded.pose,
            activity: CloudActivity.coding,
            seconds: seconds,
            entry: 1,
            motion: true,
            greeting: false,
            petPack: pack,
            petAtlas: loaded.petAtlas,
          ).paint(canvas, size);
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(300, 330);
        try {
          return (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
        } finally {
          image.dispose();
          picture.dispose();
        }
      }))!;
    }

    // Raised hand, deepest head nod, and integrated blink all remain in the
    // same source drawing; an overlaid fixed head or crop fails this check.
    for (final seconds in [1.03, 2.68, 6.22, 17.30]) {
      expect(
        await capture(seconds, sourceOnly: false),
        orderedEquals(await capture(seconds, sourceOnly: true)),
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop pet uses its atlas and urgent requests interrupt an exit',
    (tester) async {
      Future<void> show(CloudActivity activity, {bool active = true}) =>
          tester.pumpWidget(
            MaterialApp(
              home: CloudCompanionPortrait(activity: activity, active: active),
            ),
          );
      CloudCompanionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<CloudCompanionPainter>()
          .single;
      await show(CloudActivity.coding);
      await decoded(tester);
      expect(painter().petAtlas, isNotNull);
      final pack = painter().petPack!;
      await tester.pump(const Duration(milliseconds: 8001));
      expect(painter().seconds, greaterThan(8));
      expect(pack.sample(painter().seconds).segment, CloudPetSegment.loop);
      await show(CloudActivity.idle);
      expect(painter().activity, CloudActivity.coding);
      expect(painter().layers!.last.petSegment, CloudPetSegment.end);
      await tester.pump(const Duration(milliseconds: 100));
      await show(CloudActivity.permission);
      await tester.pump(const Duration(milliseconds: 130));
      expect(painter().activity, CloudActivity.permission);
      await show(CloudActivity.coding);
      await tester.pump(const Duration(milliseconds: 350));
      await show(CloudActivity.idle);
      await tester.pump(const Duration(milliseconds: 650));
      expect(painter().activity, CloudActivity.idle);
      await tester.pump(const Duration(milliseconds: 250));
      expect(painter().layers!.single.activity, CloudActivity.idle);
      await show(CloudActivity.coding, active: false);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a pose change and an interrupted fade preserve the visible frame',
    (tester) async {
      final boundary = GlobalKey();
      Future<void> show(CloudActivity activity) => tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: Center(child: CloudCompanionPortrait(activity: activity)),
          ),
        ),
      );
      CloudCompanionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<CloudCompanionPainter>()
          .single;
      Future<Uint8List> pixels() async => (await tester.runAsync(() async {
        final renderer =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await renderer.toImage();
        try {
          return (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      await show(CloudActivity.idle);
      await decoded(tester);
      await tester.pump(const Duration(milliseconds: 350));
      final idle = await pixels();
      await show(CloudActivity.coding);
      expect(await pixels(), orderedEquals(idle));
      await tester.pump(const Duration(milliseconds: 60));
      expect(painter().layers!.length, 1);
      final frozenSeconds = painter().layers!.first.seconds;
      await tester.pump(const Duration(milliseconds: 30));
      expect(painter().layers!.first.seconds, frozenSeconds);
      final interrupted = await pixels();
      await show(CloudActivity.permission);
      expect(await pixels(), orderedEquals(interrupted));
      await tester.pump(const Duration(milliseconds: 150));
      expect(painter().layers!.single.activity, CloudActivity.permission);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scrolling the live character off screen stops its ticker', (
    tester,
  ) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: const Column(
              children: [
                SizedBox(height: 100),
                CloudCompanionPortrait(activity: CloudActivity.coding),
                SizedBox(height: 1500),
              ],
            ),
          ),
        ),
      ),
    );
    await decoded(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    scroll.jumpTo(900);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('magnifier scene changes never overlap a second set of props', (
    tester,
  ) async {
    Future<void> show(CloudActivity activity) => tester.pumpWidget(
      MaterialApp(home: CloudCompanionPortrait(activity: activity)),
    );
    CloudCompanionPainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<CloudCompanionPainter>()
        .single;
    await show(CloudActivity.idle);
    await decoded(tester);
    for (final activity in [
      CloudActivity.checking,
      CloudActivity.resultReady,
    ]) {
      await show(CloudActivity.idle);
      await tester.pump(const Duration(milliseconds: 400));
      await show(activity);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(painter().layers!.length, lessThanOrEqualTo(1));
      }
      expect(painter().layers!.single.activity, activity);
      await show(CloudActivity.permission);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(painter().layers!.length, lessThanOrEqualTo(1));
      }
      expect(painter().layers!.single.activity, CloudActivity.permission);
    }
    await tester.pumpWidget(const SizedBox());
  });

  test('final replies and unknown outcomes never invent verified success', () {
    expect(cloudActivityForTask('done'), CloudActivity.resultReady);
    expect(cloudActivityForTask('unknown'), CloudActivity.checking);
    expect(cloudActivityForTask('stopping'), CloudActivity.stopping);
    expect(
      cloudActivityForTask('executing', tool: 'shell.execute'),
      CloudActivity.coding,
    );
    expect(
      cloudActivityForTask('executing', tool: 'ui.observe'),
      CloudActivity.phone,
    );
    expect(
      cloudActivityForTask('executing', tool: 'plugin:unclassified'),
      CloudActivity.checking,
    );
  });

  testWidgets('typing changes rendered hand pixels beyond a single loop', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: const Center(
            child: CloudCompanionPortrait(
              size: 300,
              activity: CloudActivity.coding,
            ),
          ),
        ),
      ),
    );
    await decoded(tester);
    final pack = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<CloudCompanionPainter>()
        .single
        .petPack!;
    await tester.pump(
      Duration(
        milliseconds: pack.start.durationMs + pack.loop.durationMs * 2 + 20,
      ),
    );
    Future<Uint8List> pixels() async {
      final r =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await r.toImage();
        try {
          return (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
    }

    final a = await pixels();
    await tester.pump(
      Duration(milliseconds: pack.loop.frames.first.durationMs + 5),
    );
    final b = await pixels();
    var changed = 0;
    // Compare the actual character's lower half, excluding any status text.
    for (var y = 365; y < 460; y++) {
      for (var x = 285; x < 535; x++) {
        final p = (y * 800 + x) * 4;
        if (a[p] != b[p] || a[p + 1] != b[p + 1] || a[p + 2] != b[p + 2])
          changed++;
      }
    }
    expect(changed, greaterThan(80));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'work scene persists in thinking; permission stops typing; hidden and reduced motion stop tickers',
    (tester) async {
      Future<void> show(
        CloudActivity state, {
        bool reduced = false,
        bool active = true,
      }) => tester.pumpWidget(
        MaterialApp(
          home: CloudCompanionPortrait(
            activity: state,
            reduceMotion: reduced,
            active: active,
          ),
        ),
      );
      CloudCompanionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CloudCompanionPainter>()
          .single;
      await show(CloudActivity.coding);
      await decoded(tester);
      await tester.pump(const Duration(seconds: 1));
      await show(CloudActivity.thinking);
      await tester.pump(const Duration(milliseconds: 900));
      expect(painter().pose.computer, 1);
      await show(CloudActivity.permission);
      await tester.pump(const Duration(milliseconds: 250));
      expect(painter().activity, CloudActivity.permission);
      expect(painter().pose.permission, 1);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await show(CloudActivity.coding, active: false);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await show(CloudActivity.coding, reduced: true);
      await tester.pumpAndSettle();
      expect(painter().motion, false);
      expect(tester.binding.transientCallbackCount, 0);
      await show(CloudActivity.idle);
      await tester.pump(const Duration(milliseconds: 900));
      expect(painter().pose.computer, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
