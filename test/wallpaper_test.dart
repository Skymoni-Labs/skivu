import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/drawer_motion.dart';
import 'package:ski/glass.dart';
import 'package:ski/wallpaper.dart';
import 'package:ski/wallpaper_settings.dart';

final imageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAQCAIAAACk6KkqAAAAFklEQVR4nGP0aV3FgA0wYRUdlaCxBABnigGboVweCAAAAABJRU5ErkJggg==',
);

class MemoryPersistence implements WallpaperPersistence {
  WallpaperData? saved;
  bool fail = false;
  @override
  Future<WallpaperData?> read() async => saved;
  @override
  Future<void> write(WallpaperData? data) async {
    if (fail) throw StateError('Storage unavailable');
    saved = data;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'profile image import saves its style once and retains the last image on failure',
    () async {
      final disk = MemoryPersistence();
      final model = WallpaperController(persistence: disk);
      final importing = model.importImage(imageBytes, blur: 11, dim: .41);
      expect(model.busy, isTrue);
      expect(await model.choose(), isFalse);
      await importing;
      expect(model.busy, isFalse);
      expect(disk.saved!.blur, 11);
      expect(disk.saved!.dim, .41);
      final previous = model.data;
      disk.fail = true;
      await expectLater(
        model.importImage(imageBytes, blur: 4, dim: .2),
        throwsStateError,
      );
      expect(model.data, same(previous));
      expect(disk.saved, same(previous));
      expect(model.error, isNotNull);
      expect(model.busy, isFalse);
      model.dispose();
    },
  );

  test(
    'selection, adjustments, restart and reset retain the expected state',
    () async {
      final disk = MemoryPersistence();
      final model = WallpaperController(
        persistence: disk,
        pickImage: () async => imageBytes,
      );
      expect(await model.choose(), isTrue);
      model.style(blur: 9, dim: .35);
      await model.saveStyle();
      final restarted = WallpaperController(persistence: disk);
      await restarted.restore();
      expect(restarted.data!.bytes, imageBytes);
      expect(restarted.data!.blur, 9);
      expect(restarted.data!.dim, .35);
      await restarted.reset();
      final cleared = WallpaperController(persistence: disk);
      await cleared.restore();
      expect(cleared.data, isNull);
      model.dispose();
      restarted.dispose();
      cleared.dispose();
    },
  );

  test(
    'cancellation, invalid images and save failures preserve the last wallpaper',
    () async {
      final disk = MemoryPersistence();
      Uint8List? selection = imageBytes;
      final model = WallpaperController(
        persistence: disk,
        pickImage: () async => selection,
      );
      expect(await model.choose(), isTrue);
      final previous = model.data;
      selection = null;
      expect(await model.choose(), isFalse);
      expect(model.error, isNull);
      expect(model.data, same(previous));
      selection = Uint8List.fromList([1, 2, 3]);
      expect(await model.choose(), isFalse);
      expect(model.error, isNotNull);
      expect(model.data, same(previous));
      selection = imageBytes;
      disk.fail = true;
      expect(await model.choose(), isFalse);
      expect(model.data, same(previous));
      await model.reset();
      expect(model.error, isNotNull);
      expect(model.data, same(previous));
      expect(model.busy, isFalse);
      model.dispose();
    },
  );

  test(
    'duplicate selection is ignored and invalid style values stay bounded',
    () async {
      final pending = Completer<Uint8List?>();
      final disk = MemoryPersistence();
      final model = WallpaperController(
        persistence: disk,
        pickImage: () => pending.future,
      );
      final first = model.choose();
      expect(model.busy, isTrue);
      expect(await model.choose(), isFalse);
      pending.complete(imageBytes);
      expect(await first, isTrue);
      model.style(blur: 99, dim: -2);
      expect(model.data!.blur, 18);
      expect(model.data!.dim, 0);
      model.style(blur: double.nan, dim: double.infinity);
      expect(model.data!.blur, 18);
      expect(model.data!.dim, 0);
      model.dispose();
    },
  );

  test('a damaged saved image falls back to the default background', () async {
    final disk = MemoryPersistence()
      ..saved = WallpaperData(id: '123', bytes: Uint8List.fromList([0, 1]));
    final model = WallpaperController(persistence: disk);
    await model.restore();
    expect(model.data, isNull);
    expect(model.error, isNotNull);
    await model.reset();
    expect(disk.saved, isNull);
    model.dispose();
  });

  testWidgets(
    'wallpaper updates the background without rebuilding foreground content',
    (tester) async {
      final motion = DrawerMotion(vsync: tester);
      final model = WallpaperController(
        persistence: MemoryPersistence(),
        pickImage: () async => imageBytes,
      );
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SkiGlassScene(
            motion: motion,
            wallpaperController: model,
            child: Builder(
              builder: (_) {
                builds++;
                return const SizedBox.expand(key: ValueKey('foreground'));
              },
            ),
          ),
        ),
      );
      final element = tester.element(find.byKey(const ValueKey('foreground')));
      expect(find.byType(AuroraBackdrop), findsOneWidget);
      final originalBuilds = builds;
      await tester.runAsync(() => model.choose());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('custom-wallpaper')), findsOneWidget);
      expect(find.byType(AuroraBackdrop), findsNothing);
      model.style(blur: 8, dim: .3);
      await tester.pumpAndSettle();
      motion.begin();
      motion.dragBy(100);
      await tester.pump();
      expect(
        tester.element(find.byKey(const ValueKey('foreground'))),
        same(element),
      );
      expect(builds, originalBuilds);
      motion.cancel();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      motion.dispose();
      model.dispose();
    },
  );

  testWidgets('wallpaper controls fit a narrow screen with enlarged text', (
    tester,
  ) async {
    final model = WallpaperController(
      persistence: MemoryPersistence(),
      pickImage: () async => imageBytes,
    );
    await tester.runAsync(() => model.choose());
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(42),
                child: WallpaperSettings(controller: model),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('更换图片'), findsOneWidget);
    expect(find.byKey(const ValueKey('wallpaper-blur')), findsOneWidget);
    expect(find.byKey(const ValueKey('wallpaper-dim')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(model.reset);
    await tester.pumpAndSettle();
    expect(find.text('选择图片'), findsOneWidget);
    expect(find.text('恢复默认'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
}
