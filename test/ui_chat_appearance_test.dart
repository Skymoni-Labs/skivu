import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/glass_preferences.dart';
import 'package:ski/ui_chat_appearance.dart';
import 'package:ski/wallpaper.dart';
import 'appearance_test.dart' show MemoryAppearance;
import 'wallpaper_test.dart' show MemoryPersistence;
import 'glass_preferences_test.dart' show MemoryGlassPreferences;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'presenter reads original settings immediately, with no second archive',
    () async {
      final disk = MemoryAppearance();
      final p = AppearancePreferences(persistence: disk);
      final glass = GlassPreferences(persistence: MemoryGlassPreferences());
      final wallpaper = WallpaperController(persistence: MemoryPersistence());
      final view = UiChatAppearance(
        preferences: p,
        glass: glass,
        background: wallpaper,
      );
      p.set('bubbleShape', 'rectangle');
      p.set('assistantBubbleLayout', 'full');
      p.set('customMessageColors', true);
      p.set('assistantColor', 0xffccddaa);
      p.set('assistantOpacity', .73);
      p.set('assistantText', 0xff123456);
      p.set('assistantFont', 'serif');
      glass.setBubbleBlur(user: false, value: 19);
      final before = p.values;
      final settings = view.values(glassEnabled: true);
      expect(settings['bubbleShape'], 'rectangle');
      expect(settings['assistantBubbleLayout'], 'full');
      expect(settings['assistantColor'], 0xccddaa);
      expect(settings['assistantOpacity'], .73);
      expect(settings['assistantText'], 0x123456);
      expect(settings['assistantFont'], 'serif');
      expect(settings['assistantBlur'], 19);
      expect(settings['background'], isFalse);
      expect(p.values, before);
      await p.save();
      final restored = AppearancePreferences(persistence: disk);
      await restored.restore();
      expect(
        UiChatAppearance(
          preferences: restored,
          glass: glass,
          background: wallpaper,
        ).values(glassEnabled: true),
        settings,
      );
      p.set('bubbleShape', 'pill');
      expect(view.values(glassEnabled: true)['bubbleShape'], 'pill');
      p.dispose();
      restored.dispose();
      glass.dispose();
      wallpaper.dispose();
    },
  );
  test('theme colors and background toggle come from original preferences', () {
    final p = AppearancePreferences(persistence: MemoryAppearance());
    final wallpaper = WallpaperController(persistence: MemoryPersistence());
    final view = UiChatAppearance(preferences: p, background: wallpaper);
    p.set('assistantColor', 0xffaabbcc);
    p.set('assistantText', 0xffee5511);
    p.set('assistantTextEnabled', false);
    p.set('videoAsset', 'video-123');
    final settings = view.values(glassEnabled: false);
    expect(settings['assistantColor'], 0xffffff);
    expect(settings['assistantText'], 0x17212b);
    expect(settings['glass'], isFalse);
    expect(settings['background'], isTrue);
    p.set('backgroundEnabled', false);
    expect(view.values(glassEnabled: true)['background'], isFalse);
    p.dispose();
    wallpaper.dispose();
  });
  test('native plugin surface yields to explicit shared customization', () {
    final p = AppearancePreferences(persistence: MemoryAppearance());
    final wallpaper = WallpaperController(persistence: MemoryPersistence());
    final view = UiChatAppearance(preferences: p, background: wallpaper);
    expect(view.values(glassEnabled: true)['defaultBubbleSurface'], isTrue);
    final before = p.values;
    p.set('assistantOpacity', .75);
    expect(view.values(glassEnabled: true)['defaultBubbleSurface'], isFalse);
    p.set('assistantOpacity', before['assistantOpacity']);
    p.set('videoAsset', 'video-123');
    expect(view.values(glassEnabled: true)['defaultBubbleSurface'], isFalse);
    p.set('backgroundEnabled', false);
    expect(view.values(glassEnabled: true)['defaultBubbleSurface'], isTrue);
    expect(view.values(glassEnabled: false)['defaultBubbleSurface'], isFalse);
    p.dispose();
    wallpaper.dispose();
  });
}
