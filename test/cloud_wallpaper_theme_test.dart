import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/appearance.dart';
import 'package:ski/cloud_wallpaper_application.dart';
import 'package:ski/cloud_wallpapers.dart';
import 'package:ski/skymoni_palette.dart';
import 'package:ski/ui_chat_appearance.dart';
import 'package:ski/wallpaper.dart';
import 'appearance_test.dart' show MemoryAppearance;
import 'cloud_wallpapers_test.dart' show wallpaperRow;
import 'wallpaper_test.dart' show MemoryPersistence, imageBytes;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'wallpaper theme, dark reading roles and saved mode survive restart',
    () async {
      final images = MemoryPersistence();
      final disk = MemoryAppearance();
      final background = WallpaperController(persistence: images);
      final preferences = AppearancePreferences(
        persistence: disk,
        background: background,
      );
      preferences.set('assistantText', 0xff12abcd);
      preferences.set('userFont', 'serif');
      preferences.set('videoAsset', 'video-123');
      preferences.set('backgroundEnabled', false);
      final item = CloudWallpaper.parse({
        ...wallpaperRow(),
        'color_theme': 'iris',
      });
      expect(
        await applyCloudWallpaper(
          item: item,
          bytes: imageBytes,
          background: background,
          preferences: preferences,
          isCurrent: () => true,
        ),
        isTrue,
      );
      expect(preferences.dark, isTrue);
      expect(preferences.text('mode'), 'light');
      expect(preferences.text('videoAsset'), '');
      expect(preferences.flag('backgroundEnabled'), isTrue);
      expect(preferences.color('accent'), const Color(0xffb1a9ff));
      expect(preferences.textColor('interfaceText'), const Color(0xfff0f5ff));
      expect(preferences.textColor('assistantText'), const Color(0xff12abcd));
      expect(preferences.text('userFont'), 'serif');
      final presented = UiChatAppearance(
        preferences: preferences,
        background: background,
      ).values(glassEnabled: true);
      expect(presented['userColor'], 0x111d37);
      expect(presented['userText'], 0xf0f5ff);
      final restartedImage = WallpaperController(persistence: images);
      await restartedImage.restore();
      final restarted = AppearancePreferences(
        persistence: disk,
        background: restartedImage,
      );
      await restarted.restore();
      expect(restarted.dark, isTrue);
      expect(restarted.color('accent'), preferences.color('accent'));
      restartedImage.style(blur: 5);
      await restartedImage.saveStyle();
      expect(images.saved!.mode, 'dark');
      await restartedImage.importImage(imageBytes);
      expect(restarted.dark, isFalse);
      expect(restarted.text('mode'), 'light');
      restarted.set('accent', 0xff123456);
      expect(restarted.text('colorTheme'), '');
      expect(restarted.color('accent'), const Color(0xff123456));
      preferences.dispose();
      restarted.dispose();
      background.dispose();
      restartedImage.dispose();
    },
  );

  test('light and system wallpapers respect Skymoni mode behavior', () async {
    final background = WallpaperController(persistence: MemoryPersistence());
    final p = AppearancePreferences(
      persistence: MemoryAppearance(),
      background: background,
    );
    p.set('mode', 'dark');
    for (final mode in ['light', 'system']) {
      await applyCloudWallpaper(
        item: CloudWallpaper.parse({
          ...wallpaperRow(),
          'mode': mode,
          'color_theme': 'coral',
        }),
        bytes: imageBytes,
        background: background,
        preferences: p,
        isCurrent: () => true,
      );
      expect(p.dark, mode == 'system');
      expect(p.text('mode'), 'dark');
      expect(
        p.cloudPalette!.ink,
        mode == 'light' ? const Color(0xff3a241f) : const Color(0xfffff5ea),
      );
    }
    p.dispose();
    background.dispose();
  });

  test(
    'cancel or image save failure leaves previous wallpaper and theme',
    () async {
      final images = MemoryPersistence();
      final disk = MemoryAppearance();
      final background = WallpaperController(persistence: images);
      final p = AppearancePreferences(
        persistence: disk,
        background: background,
      );
      await background.importImage(imageBytes);
      await p.save();
      final previousImage = background.data;
      final previousTheme = p.values;
      final item = CloudWallpaper.parse(wallpaperRow());
      var calls = 0;
      expect(
        await applyCloudWallpaper(
          item: item,
          bytes: imageBytes,
          background: background,
          preferences: p,
          isCurrent: () => ++calls == 1,
        ),
        isFalse,
      );
      expect(p.values, previousTheme);
      images.fail = true;
      await expectLater(
        applyCloudWallpaper(
          item: item,
          bytes: imageBytes,
          background: background,
          preferences: p,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(background.data, same(previousImage));
      expect(p.values, previousTheme);
      expect(disk.saved, previousTheme);
      p.dispose();
      background.dispose();
    },
  );

  test(
    'theme save failure does not replace the image or claim success',
    () async {
      final disk = MemoryAppearance();
      final background = WallpaperController(persistence: MemoryPersistence());
      final p = AppearancePreferences(
        persistence: disk,
        background: background,
      );
      await background.importImage(imageBytes);
      final previousImage = background.data;
      final previousTheme = p.values;
      disk.beforeWrite = () async => throw StateError('disk full');
      await expectLater(
        applyCloudWallpaper(
          item: CloudWallpaper.parse(wallpaperRow()),
          bytes: imageBytes,
          background: background,
          preferences: p,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(background.data, same(previousImage));
      expect(p.values, previousTheme);
      expect(p.error, isNotNull);
      p.dispose();
      background.dispose();
    },
  );

  test('all ten catalog themes have light, dark and night palettes', () {
    for (final id in skymoniThemeNames.keys) {
      for (final dark in [false, true]) {
        final p = skymoniPalette(id, dark: dark);
        expect(
          p.ink.computeLuminance() > p.background.computeLuminance(),
          dark,
        );
        final night = skymoniPalette(id, dark: dark, starry: true);
        expect(night.ink, const Color(0xfff0f5ff));
      }
    }
    expect(cleanAppearance({'colorTheme': 'unknown'})['colorTheme'], '');
  });
}
