import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/cloud_wallpapers.dart';
import 'package:ski/cloud_wallpaper_gallery.dart';
import 'package:ski/wallpaper.dart';
import 'package:ski/appearance.dart';
import 'appearance_test.dart' show MemoryAppearance;
import 'cloud_wallpapers_test.dart' show wallpaperRow, catalogueData;
import 'wallpaper_test.dart' show MemoryPersistence, imageBytes;

class GalleryService extends CloudWallpaperService {
  GalleryService(this.bytes);
  final Uint8List bytes;
  int loads = 0;
  bool fail = false;
  Completer<Uint8List>? pending;
  @override
  Future<CloudWallpaperCatalog> fetchCatalog() async {
    loads++;
    if (fail) throw StateError('offline');
    return CloudWallpaperCatalog.parse(
      catalogueData([wallpaperRow(bytes: bytes)]),
    );
  }

  @override
  Future<Uint8List> download(CloudWallpaper item) async =>
      pending == null ? bytes : pending!.future;
}

void main() {
  late AppearancePreferences preferences;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    preferences = AppearancePreferences(persistence: MemoryAppearance());
  });
  tearDown(() => preferences.dispose());
  testWidgets(
    'opening and refreshing the shared list never changes local wallpaper',
    (tester) async {
      final controller = WallpaperController(persistence: MemoryPersistence());
      await tester.runAsync(() => controller.importImage(imageBytes));
      final original = controller.data;
      final service = GalleryService(
        image.encodeJpg(image.Image(width: 240, height: 480)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudWallpaperGallery(
                controller: controller,
                service: service,
                preferences: preferences,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.loads, 0);
      await tester.tap(find.text('云端壁纸'));
      await tester.pumpAndSettle();
      expect(service.loads, 1);
      expect(find.text('月下海岸'), findsOneWidget);
      expect(controller.data, same(original));
      service.fail = true;
      await tester.tap(find.byTooltip('刷新云端壁纸'));
      await tester.pumpAndSettle();
      expect(find.text('月下海岸'), findsOneWidget);
      expect(find.textContaining('已保留本机背景'), findsOneWidget);
      expect(controller.data, same(original));
      await tester.pumpWidget(const SizedBox());
      service.close();
      controller.dispose();
    },
  );

  testWidgets(
    'canceling an in-flight preview prevents a late background replacement',
    (tester) async {
      final controller = WallpaperController(persistence: MemoryPersistence());
      await tester.runAsync(() => controller.importImage(imageBytes));
      final original = controller.data;
      final bytes = image.encodeJpg(image.Image(width: 240, height: 480));
      final service = GalleryService(bytes)..pending = Completer<Uint8List>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudWallpaperGallery(
                controller: controller,
                service: service,
                preferences: preferences,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('云端壁纸'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('月下海岸'));
      await tester.tap(find.text('月下海岸'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用这张壁纸'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      service.pending!.complete(bytes);
      await tester.pumpAndSettle();
      expect(controller.data, same(original));
      await tester.pumpWidget(const SizedBox());
      service.close();
      controller.dispose();
    },
  );

  testWidgets('explicit apply saves the selected image locally', (
    tester,
  ) async {
    final disk = MemoryPersistence();
    final controller = WallpaperController(persistence: disk);
    await tester.runAsync(() => controller.importImage(imageBytes));
    final previousId = controller.data!.id;
    final bytes = image.encodeJpg(image.Image(width: 240, height: 480));
    final service = GalleryService(bytes);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CloudWallpaperGallery(
              controller: controller,
              service: service,
              preferences: preferences,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('云端壁纸'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('月下海岸'));
    await tester.tap(find.text('月下海岸'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用这张壁纸'));
    for (
      var i = 0;
      i < 100 && find.byType(AlertDialog).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.data!.id, isNot(previousId));
    expect(disk.saved!.bytes, bytes);
    expect(disk.saved!.mode, 'dark');
    expect(preferences.text('colorTheme'), 'blue');
    await tester.pumpWidget(const SizedBox());
    service.close();
    controller.dispose();
  });
}
