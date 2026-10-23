import 'dart:convert';
import 'dart:ui' as ui;
import 'appearance.dart';
import 'chat_backdrop.dart';
import 'glass_preferences.dart';
import 'wallpaper.dart';

/// Read-only adapter of the original appearance stores. No second preferences
/// or media archive is created for the HTML presenter.
class UiChatAppearance {
  UiChatAppearance({
    AppearancePreferences? preferences,
    GlassPreferences? glass,
    WallpaperController? background,
  }) : preferences = preferences ?? appearance,
       glass = glass ?? glassPreferences,
       background = background ?? wallpaper;
  final AppearancePreferences preferences;
  final GlassPreferences glass;
  final WallpaperController background;
  final _images = <String, ui.Image?>{};
  final _encoded = <String, String?>{};
  final _assetIds = <String, String>{};

  Map<String, dynamic> values({required bool glassEnabled}) {
    final p = preferences;
    final hasBackground =
        p.flag('backgroundEnabled') &&
        (background.data != null || p.text('videoAsset').isNotEmpty);
    return {
      // Untouched preferences may follow a presenter's native bubble surface.
      // Explicit shared surface, media or text choices always take precedence.
      'defaultBubbleSurface':
          !hasBackground &&
          glassEnabled &&
          [
            'bubbleStyle',
            'rounded',
            'bubbleShape',
            'customMessageColors',
            'userOpacity',
            'assistantOpacity',
            'userImage',
            'assistantImage',
            'userTextEnabled',
            'assistantTextEnabled',
          ].every((key) => p.values[key] == appearanceDefaults[key]),
      for (final key in [
        'bubbleStyle',
        'bubbleShape',
        'rounded',
        'assistantBubbleLayout',
        'compact',
        'wideChat',
        'avatars',
        'squareAvatars',
        'textScale',
        'userOpacity',
        'assistantOpacity',
        'reduceMotion',
      ])
        key: p.values[key],
      'glass': glassEnabled,
      'background': hasBackground,
      'userColor': p.flag('customMessageColors')
          ? p.color('userColor').toARGB32() & 0xffffff
          : 0xffffff,
      'assistantColor': p.flag('customMessageColors')
          ? p.color('assistantColor').toARGB32() & 0xffffff
          : 0xffffff,
      'userText': p.textColor('userText').toARGB32() & 0xffffff,
      'assistantText': p.textColor('assistantText').toARGB32() & 0xffffff,
      'userFont': p.text('userFont'),
      'assistantFont': p.text('assistantFont'),
      'userBlur': glass.userBlur,
      'assistantBlur': glass.assistantBlur,
    };
  }

  Future<Map<String, String?>> assets(ChatBackdropController? backdrop) async {
    for (final user in [true, false]) {
      final side = user ? 'user' : 'assistant';
      final blur = user ? glass.userBlur : glass.assistantBlur;
      final image = blur > 0
          ? backdrop?.imageFor(blur)
          : backdrop?.wallpaperImage;
      final key = '${side}Frost';
      if (!_images.containsKey(key) || !identical(_images[key], image)) {
        _images[key] = image;
        _encoded[key] = null;
        if (image != null) {
          // The scene can replace its capture while PNG encoding is pending.
          final copy = image.clone();
          try {
            final bytes = await copy.toByteData(format: ui.ImageByteFormat.png);
            if (bytes != null)
              _encoded[key] =
                  'data:image/png;base64,${base64Encode(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes))}';
          } finally {
            copy.dispose();
          }
        }
      }
      for (final kind in ['Image', 'Font']) {
        final id = kind == 'Image'
            ? preferences.text('${side}Image')
            : preferences.text('${side}Font') == 'custom'
            ? preferences.text('${side}FontAsset')
            : '';
        final key = '$side$kind';
        if (_assetIds[key] == id) continue;
        _assetIds[key] = id;
        _encoded[key] = null;
        if (id.isNotEmpty) {
          try {
            final bytes = await appearanceAssets.read(id);
            _encoded[key] =
                'data:${kind == 'Font' ? 'font/ttf' : _imageMime(bytes)};base64,${base64Encode(bytes)}';
          } catch (_) {
            // Original settings already report missing local media.
          }
        }
      }
    }
    return Map.of(_encoded);
  }

  static String _imageMime(List<int> bytes) =>
      bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8
      ? 'image/jpeg'
      : bytes.length > 3 && bytes[0] == 0x52 && bytes[1] == 0x49
      ? 'image/webp'
      : 'image/png';
}
