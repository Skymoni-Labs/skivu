import 'dart:typed_data';
import 'appearance.dart';
import 'cloud_wallpapers.dart';
import 'wallpaper.dart';

/// Save the theme before replacing the image. An image failure restores the
/// previous appearance, while WallpaperController retains its previous image.
Future<bool> applyCloudWallpaper({
  required CloudWallpaper item,
  required Uint8List bytes,
  required WallpaperController background,
  required AppearancePreferences preferences,
  required bool Function() isCurrent,
}) async {
  await WallpaperController.validateImage(bytes);
  if (!isCurrent()) return false;
  final previous = preferences.values;
  try {
    await preferences.apply({
      ...previous,
      'colorTheme': item.colorTheme,
      'backgroundEnabled': true,
      'videoAsset': '',
    });
    if (preferences.error != null) throw StateError('Theme save failed');
    if (!isCurrent()) {
      await preferences.apply(previous);
      return false;
    }
    await background.importImage(bytes, mode: item.mode);
    return true;
  } catch (_) {
    await preferences.apply(previous);
    rethrow;
  }
}
